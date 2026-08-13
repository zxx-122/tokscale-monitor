import { DatabaseSync } from 'node:sqlite';
import http from 'node:http';
import { existsSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { scanAll, toolsStatus, TOOL_LABEL, scanHistoryByDay } from './sources.mjs';
import { fetchLeaderboard, leaderboardSnapshot, getActiveSource, setActiveSource } from './leaderboard.mjs';

const PORT = Number(process.env.TOKSCALE_MONITOR_PORT) || 8899;
const ROLLING_MS = 60_000;
const home = os.homedir();

const candidates = [];
if (process.env.XDG_DATA_HOME) candidates.push(path.join(process.env.XDG_DATA_HOME, 'opencode', 'opencode.db'));
candidates.push(path.join(home, '.local', 'share', 'opencode', 'opencode.db'));
candidates.push(path.join(home, '.local', 'share', 'opencode', 'opencode-stable.db'));
if (process.env.LOCALAPPDATA) candidates.push(path.join(process.env.LOCALAPPDATA, 'opencode', 'opencode.db'));

const envDb = process.env.TOKSCALE_MONITOR_DB;
let dbPath = envDb || candidates.find(existsSync) || candidates[0];
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
  const created = data && data.time && data.time.created;
  const completed = data && data.time && data.time.completed;
  const durationMs = (completed && created && completed > created) ? (completed - created) : null;
  return {
    hasTokens: !!t,
    input: t ? (t.input ?? 0) : 0,
    output: t ? (t.output ?? 0) : 0,
    reasoning: t ? (t.reasoning ?? 0) : 0,
    cacheRead: t && t.cache && t.cache.read ? t.cache.read : 0,
    cacheWrite: t && t.cache && t.cache.write ? t.cache.write : 0,
    total: t ? (t.total ?? 0) : 0,
    cost: typeof data.cost === 'number' ? data.cost : 0,
    model: data.modelID || null,
    provider: data.providerID || null,
    durationMs,
  };
}

let lastPoll = 0;
let lastDelta = {};
let sinceStart = { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, messages: 0 };
let _lbfetch = null;
function getLeaderboard() {
  if (!_lbfetch) _lbfetch = fetchLeaderboard().catch(() => null);
  return _lbfetch;
}

function buildStats(now) {
  const conn = getDb();
  if (!conn) return { ok: false, error: 'db-unavailable', dbPath, ts: now };

  const dayStart = new Date();
  dayStart.setHours(0, 0, 0, 0);

  const rows = conn.prepare('SELECT session_id, time_created, data FROM message WHERE time_created >= ? ORDER BY time_created ASC').all(dayStart.getTime());
  const rollCut = now - ROLLING_MS;

  const today = { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, messages: 0 };
  const rolling = { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, messages: 0 };
  const byModel = new Map();
  let lastMsg = null;

  const emptyModelBucket = (model, tool, provider) => ({ model, tool, provider, input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, messages: 0, totalDurationMs: 0, timedTokens: 0, samples: 0 });
  const bumpOpencode = (b, tk, r) => {
    b.input += tk.input; b.output += tk.output; b.reasoning += tk.reasoning;
    b.cacheRead += tk.cacheRead; b.cacheWrite += tk.cacheWrite; b.total += tk.total;
    b.cost += tk.cost; b.messages += tk.hasTokens ? 1 : 0;
    if (tk.durationMs && tk.durationMs > 0 && tk.total > 0) {
      b.totalDurationMs += tk.durationMs;
      b.timedTokens += tk.total;
      b.samples += 1;
    }
    if (!lastMsg || r.time_created > lastMsg.time_created) lastMsg = r;
  };

  for (const r of rows) {
    const tk = parseTokens(r);
    if (!tk) continue;
    if (tk.hasTokens) {
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
    }
    if (tk.model) {
      const key = 'opencode|' + tk.model;
      if (!byModel.has(key)) byModel.set(key, emptyModelBucket(tk.model, 'opencode', tk.provider));
      bumpOpencode(byModel.get(key), tk, r);
    }
  }

  let src = { rows: [], freshTotals: null };
  try { src = scanAll(dayStart.getTime(), now); } catch {}
  for (const rec of src.rows) {
    if (rec.tool === 'opencode') continue;
    today.input += rec.input;
    today.output += rec.output;
    today.reasoning += rec.reasoning;
    today.cacheRead += rec.cacheRead;
    today.cacheWrite += rec.cacheWrite;
    today.total += rec.total;
    today.cost += rec.cost;
    today.messages += rec.messages;
    if (rec.ts >= rollCut) {
      rolling.input += rec.input;
      rolling.output += rec.output;
      rolling.reasoning += rec.reasoning;
      rolling.cacheRead += rec.cacheRead;
      rolling.cacheWrite += rec.cacheWrite;
      rolling.total += rec.total;
      rolling.messages += rec.messages;
    }
    const mkey = rec.tool + '|' + rec.model;
    if (!byModel.has(mkey)) byModel.set(mkey, emptyModelBucket(rec.model, rec.tool, TOOL_LABEL[rec.tool] || rec.tool));
    const b = byModel.get(mkey);
    b.input += rec.input; b.output += rec.output; b.reasoning += rec.reasoning;
    b.cacheRead += rec.cacheRead; b.cacheWrite += rec.cacheWrite; b.total += rec.total;
    b.cost += rec.cost; b.messages += rec.messages;
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

  // delta = 自上次刷新以来 today 的增量。
  // 注意：不能再加 src.freshTotals——freshTotals 是本次 scan 新读入的行，
  // 它们已 push 进 dayRows 并被计入 today，再加会重复计数（首次调用时 delta≈2×今日）。
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
  for (const k of Object.keys(sinceStart)) sinceStart[k] += delta[k];
  lastDelta = { input: today.input, output: today.output, reasoning: today.reasoning, cacheRead: today.cacheRead, cacheWrite: today.cacheWrite, total: today.total, cost: today.cost, messages: today.messages };
  lastPoll = now;

  return { ok: true, dbPath, ts: now, today, rolling, delta, sinceStart, active, bestModel, modelsToday, modelCount: modelsToday.length, toolsStatus: toolsStatus(), leaderboard: leaderboardSnapshot() };
}

function buildHistory(now, days) {
  const conn = getDb();
  if (!conn) return { ok: false, error: 'db-unavailable', ts: now };
  const n = Math.max(1, Math.min(90, Number.isFinite(days) ? Math.floor(days) : 30));
  const start = new Date();
  start.setHours(0, 0, 0, 0);
  start.setDate(start.getDate() - (n - 1));

  const dayKey = (t) => {
    const d = new Date(t);
    return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
  };
  const empty = (date) => ({
    date, input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, messages: 0,
    byTool: {
      opencode: { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, messages: 0 },
      claude: { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, messages: 0 },
      codex: { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, messages: 0 },
      kimi: { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, messages: 0 },
    },
  });

  const byDay = new Map();
  for (let i = 0; i < n; i++) {
    const d = new Date(start.getTime() + i * 86400000);
    byDay.set(dayKey(d.getTime()), empty(dayKey(d.getTime())));
  }

  let rows;
  try {
    rows = conn.prepare('SELECT time_created, data FROM message WHERE time_created >= ? ORDER BY time_created ASC').all(start.getTime());
  } catch (err) {
    return { ok: false, error: 'message-table-unavailable: ' + String((err && err.message) || err), ts: now };
  }
  for (const r of rows) {
    const tk = parseTokens(r);
    if (!tk || !tk.hasTokens) continue;
    const b = byDay.get(dayKey(r.time_created));
    if (!b) continue;
    b.input += tk.input; b.output += tk.output; b.reasoning += tk.reasoning;
    b.cacheRead += tk.cacheRead; b.cacheWrite += tk.cacheWrite; b.total += tk.total;
    b.cost += tk.cost; b.messages += 1;
    b.byTool.opencode.input += tk.input; b.byTool.opencode.output += tk.output;
    b.byTool.opencode.reasoning += tk.reasoning; b.byTool.opencode.cacheRead += tk.cacheRead;
    b.byTool.opencode.cacheWrite += tk.cacheWrite; b.byTool.opencode.total += tk.total;
    b.byTool.opencode.cost += tk.cost; b.byTool.opencode.messages += 1;
  }

  // 合并 claude / codex / kimi 全量历史扫描（deepcode 等无用量数据，不产生 token 行）
  const hist = scanHistoryByDay(n);
  for (const tool of ['claude', 'codex', 'kimi']) {
    const hm = hist.byTool[tool].map;
    for (const [k, day] of hm) {
      const b = byDay.get(k);
      if (!b) continue;
      if (day.total > 0) {
        b.input += day.input; b.output += day.output; b.reasoning += day.reasoning;
        b.cacheRead += day.cacheRead; b.cacheWrite += day.cacheWrite; b.total += day.total;
        b.cost += day.cost; b.messages += day.messages;
        b.byTool[tool].input += day.input; b.byTool[tool].output += day.output;
        b.byTool[tool].reasoning += day.reasoning; b.byTool[tool].cacheRead += day.cacheRead;
        b.byTool[tool].cacheWrite += day.cacheWrite; b.byTool[tool].total += day.total;
        b.byTool[tool].cost += day.cost; b.byTool[tool].messages += day.messages;
      }
    }
  }

  const items = [...byDay.values()].sort((a, b) => a.date.localeCompare(b.date));
  const totals = { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, messages: 0 };
  for (const d of items) for (const k of Object.keys(totals)) totals[k] += d[k];
  const byToolTotals = {};
  for (const tool of ['opencode', 'claude', 'codex', 'kimi']) {
    const t = { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, messages: 0 };
    for (const d of items) for (const k of Object.keys(t)) t[k] += d.byTool[tool][k];
    byToolTotals[tool] = t;
  }
  return { ok: true, ts: now, days: n, start: start.getTime(), source: 'opencode message table + claude/codex/kimi 全量扫描', items, totals, byToolTotals, tools: hist.tools, dbPath };
}

function buildToolStats(now) {
  const conn = getDb();
  if (!conn) return { ok: false, error: 'db-unavailable', ts: now };
  const weekStart = now - 7 * 86400000;
  let rows;
  try {
    rows = conn.prepare(
      "SELECT data, time_created FROM part WHERE json_extract(data,'$.type')='tool' AND time_created >= ? ORDER BY time_created ASC"
    ).all(weekStart);
  } catch (err) {
    return { ok: false, error: 'part-table-unavailable: ' + String((err && err.message) || err), ts: now };
  }

  const seen = new Set();
  const skillByName = new Map();
  const mcpByTool = new Map();
  const toolByTool = new Map();
  const byDay = new Map();
  let totalCalls = 0;

  const dayKey = (t) => {
    const d = new Date(t);
    return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
  };

  for (const r of rows) {
    let d;
    try { d = JSON.parse(r.data); } catch { continue; }
    if (!d || d.type !== 'tool' || !d.tool) continue;
    const tool = String(d.tool);
    const callID = d.callID;
    const key = tool + '|' + callID;
    if (seen.has(key)) continue;
    seen.add(key);
    totalCalls++;
    const day = dayKey(r.time_created);
    byDay.set(day, (byDay.get(day) || 0) + 1);
    toolByTool.set(tool, (toolByTool.get(tool) || 0) + 1);
    if (tool === 'skill') {
      const name = (d.state && d.state.input && d.state.input.name) || 'unknown';
      skillByName.set(name, (skillByName.get(name) || 0) + 1);
    } else if (/mcp/i.test(tool)) {
      mcpByTool.set(tool, (mcpByTool.get(tool) || 0) + 1);
    }
  }

  const sum = (m) => [...m.values()].reduce((a, b) => a + b, 0);
  return {
    ok: true, ts: now, periodDays: 7, weekStart, dbPath,
    totalCalls,
    skill: { total: sum(skillByName), byName: [...skillByName.entries()].map(([name, calls]) => ({ name, calls })).sort((a, b) => b.calls - a.calls) },
    mcp: { detected: mcpByTool.size > 0, total: sum(mcpByTool), byTool: [...mcpByTool.entries()].map(([tool, calls]) => ({ tool, calls })).sort((a, b) => b.calls - a.calls) },
    byTool: [...toolByTool.entries()].map(([tool, calls]) => ({ tool, calls })).sort((a, b) => b.calls - a.calls),
    byDay: [...byDay.entries()].map(([date, calls]) => ({ date, calls })).sort((a, b) => a.date.localeCompare(b.date)),
  };
}

const server = http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  const pathname = req.url.split('?')[0];
  if (pathname === '/leaderboard') {
    try {
      const q = new URLSearchParams((req.url.split('?')[1] || ''));
      const force = q.get('refresh') === '1';
      const src = q.get('source');
      // 指定 source 时切换当前活跃榜单（aa=智能指数 / code=编程能力）
      if (src) setActiveSource(src);
      res.end(JSON.stringify(await fetchLeaderboard(force, src || getActiveSource())));
    } catch (err) {
      res.statusCode = 502;
      res.end(JSON.stringify({ ok: false, error: String((err && err.message) || err) }));
    }
    return;
  }
  if (pathname === '/tools') {
    res.end(JSON.stringify(buildToolStats(Date.now())));
    return;
  }
  if (pathname === '/history') {
    // 注意不能用 `|| 30`：days=0 是合法值（会被 buildHistory 夹到 1），而 0 是 falsy 会被吞成 30
    const daysParam = new URLSearchParams((req.url.split('?')[1] || '')).get('days');
    const days = daysParam === null ? 30 : Number(daysParam);
    res.end(JSON.stringify(buildHistory(Date.now(), days)));
    return;
  }
  const stats = pathname === '/stats' ? buildStats(Date.now()) : { ok: false, error: 'not-found', ts: Date.now() };
  res.end(JSON.stringify(stats));
});

getLeaderboard();
server.listen(PORT, '127.0.0.1', () => {
  console.log(`tokscale-monitor listening on http://127.0.0.1:${PORT}  db=${dbPath}`);
});

process.on('SIGTERM', () => { try { server.close(); } catch {} process.exit(0); });