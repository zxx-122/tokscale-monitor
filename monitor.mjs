import { DatabaseSync } from 'node:sqlite';
import http from 'node:http';
import { existsSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const PORT = Number(process.env.TOKSCALE_MONITOR_PORT) || 8899;
const ROLLING_MS = 60_000;
const home = os.homedir();

const candidates = [];
if (process.env.XDG_DATA_HOME) candidates.push(path.join(process.env.XDG_DATA_HOME, 'opencode', 'opencode.db'));
candidates.push(path.join(home, '.local', 'share', 'opencode', 'opencode.db'));
candidates.push(path.join(home, '.local', 'share', 'opencode', 'opencode-stable.db'));
if (process.env.LOCALAPPDATA) candidates.push(path.join(process.env.LOCALAPPDATA, 'opencode', 'opencode.db'));

let dbPath = candidates.find(existsSync) || candidates[0];
let db = null;

function getDb() {
  if (!db) {
    try { db = new DatabaseSync(dbPath, { readOnly: true }); } catch { db = null; }
  }
  return db;
}

function parseTokens(row) {
  let data = null;
  try { data = JSON.parse(row.data); } catch { return null; }
  const t = data && data.tokens;
  if (!t) return null;
  const created = data && data.time && data.time.created;
  const completed = data && data.time && data.time.completed;
  const durationMs = (completed && created && completed > created) ? (completed - created) : null;
  return {
    input: t.input ?? 0,
    output: t.output ?? 0,
    reasoning: t.reasoning ?? 0,
    cacheRead: t.cache && t.cache.read ? t.cache.read : 0,
    cacheWrite: t.cache && t.cache.write ? t.cache.write : 0,
    total: t.total ?? 0,
    cost: typeof data.cost === 'number' ? data.cost : 0,
    model: data.modelID || 'unknown',
    durationMs,
  };
}

let lastPoll = 0;
let lastDelta = {};
let sinceStart = { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, messages: 0 };

function buildStats(now) {
  const conn = getDb();
  if (!conn) return { ok: false, error: 'db-unavailable', dbPath };

  const dayStart = new Date();
  dayStart.setHours(0, 0, 0, 0);

  const rows = conn.prepare('SELECT session_id, time_created, data FROM message WHERE time_created >= ? ORDER BY time_created ASC').all(dayStart.getTime());
  const rollCut = now - ROLLING_MS;

  const today = { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, messages: 0 };
  const rolling = { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, messages: 0 };
  const byModel = new Map();
  let lastMsg = null;

  for (const r of rows) {
    const tk = parseTokens(r);
    if (!tk) continue;
    today.input += tk.input;
    today.output += tk.output;
    today.reasoning += tk.reasoning;
    today.cacheRead += tk.cacheRead;
    today.cacheWrite += tk.cacheWrite;
    today.total += tk.total;
    today.cost += tk.cost;
    today.messages += 1;

    if (r.time_created >= rollCut) {
      rolling.input += tk.input;
      rolling.output += tk.output;
      rolling.reasoning += tk.reasoning;
      rolling.cacheRead += tk.cacheRead;
      rolling.cacheWrite += tk.cacheWrite;
      rolling.total += tk.total;
      rolling.messages += 1;
    }

    if (tk.input > 0 || tk.output > 0 || tk.total > 0) {
      const m = tk.model;
      if (!byModel.has(m)) byModel.set(m, { model: m, input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, messages: 0, totalDurationMs: 0, timedTokens: 0, samples: 0 });
      const b = byModel.get(m);
      b.input += tk.input; b.output += tk.output; b.reasoning += tk.reasoning;
      b.cacheRead += tk.cacheRead; b.cacheWrite += tk.cacheWrite; b.total += tk.total;
      b.cost += tk.cost; b.messages += 1;
      if (tk.durationMs && tk.durationMs > 0 && tk.total > 0) {
        b.totalDurationMs += tk.durationMs;
        b.timedTokens += tk.total;
        b.samples += 1;
      }
    }

    if (!lastMsg || r.time_created > lastMsg.time_created) lastMsg = r;
  }

  const modelsToday = [...byModel.values()].sort((a, b) => b.total - a.total);
  const todayTotal0 = Math.max(1, today.total);
  let bestModel = null;
  for (const m of modelsToday) {
    const msPer1K = (m.timedTokens > 0 && m.totalDurationMs > 0) ? (m.totalDurationMs * 1000 / m.timedTokens) : null;
    m.msPer1K = msPer1K;
    m.tokensPerSec = msPer1K ? Math.round(1000 / msPer1K * 1000) : null;
    m.share = m.total / todayTotal0;
    m.outputShare = m.total > 0 ? m.output / m.total : 0;
    m.costPer1M = m.total > 0 ? (m.cost * 1000000 / m.total) : null;
  }
  const eligible = modelsToday.filter((m) => m.msPer1K !== null && m.samples >= 3 && m.total >= 5000);
  if (eligible.length) {
    eligible.sort((a, b) => a.msPer1K - b.msPer1K);
    bestModel = eligible[0];
  } else if (modelsToday.length) {
    bestModel = modelsToday[0];
  }

  let active = null;
  if (lastMsg) {
    try {
      const s = conn.prepare('SELECT id, title, model, time_created, time_updated, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, cost FROM session WHERE id = ?').get(lastMsg.session_id);
      if (s) {
        let modelName = 'unknown';
        try { const mm = JSON.parse(s.model); modelName = mm.id || mm.model || 'unknown'; } catch { modelName = s.model || 'unknown'; }
        const secs = Math.max(0, (now - s.time_created) / 1000);
        active = {
          sessionId: s.id,
          title: s.title || '(无标题)',
          model: modelName,
          startedMs: s.time_created,
          elapsedMin: Math.round(secs / 60),
          input: s.tokens_input ?? 0,
          output: s.tokens_output ?? 0,
          reasoning: s.tokens_reasoning ?? 0,
          cacheRead: s.tokens_cache_read ?? 0,
          cacheWrite: s.tokens_cache_write ?? 0,
          total: (s.tokens_input ?? 0) + (s.tokens_output ?? 0) + (s.tokens_reasoning ?? 0) + (s.tokens_cache_read ?? 0) + (s.tokens_cache_write ?? 0),
          cost: s.cost ?? 0,
        };
      }
    } catch {}
  }

  const delta = {
    input: Math.max(0, today.input - (lastDelta.input ?? 0)),
    output: Math.max(0, today.output - (lastDelta.output ?? 0)),
    reasoning: Math.max(0, today.reasoning - (lastDelta.reasoning ?? 0)),
    cacheRead: Math.max(0, today.cacheRead - (lastDelta.cacheRead ?? 0)),
    cacheWrite: Math.max(0, today.cacheWrite - (lastDelta.cacheWrite ?? 0)),
    total: Math.max(0, today.total - (lastDelta.total ?? 0)),
    cost: Math.max(0, today.cost - (lastDelta.cost ?? 0)),
    messages: Math.max(0, today.messages - (lastDelta.messages ?? 0)),
  };
  sinceStart.input += delta.input;
  sinceStart.output += delta.output;
  sinceStart.reasoning += delta.reasoning;
  sinceStart.cacheRead += delta.cacheRead;
  sinceStart.cacheWrite += delta.cacheWrite;
  sinceStart.total += delta.total;
  sinceStart.cost += delta.cost;
  sinceStart.messages += delta.messages;
  lastDelta = { input: today.input, output: today.output, reasoning: today.reasoning, cacheRead: today.cacheRead, cacheWrite: today.cacheWrite, total: today.total, cost: today.cost, messages: today.messages };
  lastPoll = now;

  return { ok: true, dbPath, ts: now, today, rolling, delta, sinceStart, active, bestModel, modelsToday };
}

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  const stats = buildStats(Date.now());
  res.end(JSON.stringify(stats));
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`tokscale-monitor listening on http://127.0.0.1:${PORT}  db=${dbPath}`);
});

process.on('SIGTERM', () => { try { server.close(); } catch {} process.exit(0); });