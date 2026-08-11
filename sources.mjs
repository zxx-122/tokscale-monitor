import { readdirSync, statSync, existsSync, openSync, readSync, closeSync, readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const MAX_CHUNK = 8 * 1024 * 1024;
const home = os.homedir();

export const TOOL_LABEL = { opencode: 'opencode', claude: 'claude-code', codex: 'codex', kimi: 'kimi-code', deepcode: 'deepcode', zcode: 'zcode' };

function walk(dir, out = [], depth = 0) {
  if (depth > 9 || !existsSync(dir)) return out;
  let entries;
  try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out, depth + 1);
    else out.push(p);
  }
  return out;
}

function readTail(file, state) {
  let st;
  try { st = statSync(file); } catch { return { queue: [], state }; }
  let prevSize = (state && state.size) || 0;
  if (st.size < prevSize) { prevSize = 0; state = { textTail: '' }; }
  const len = st.size - prevSize;
  let text = (state && state.textTail) || '';
  if (len > 0) {
    let fd;
    try { fd = openSync(file, 'r'); } catch { return { queue: [], state }; }
    const toRead = Math.min(len, MAX_CHUNK);
    const start = Math.max(0, st.size - toRead);
    const buf = Buffer.alloc(toRead);
    try {
      if (len <= MAX_CHUNK) readSync(fd, buf, 0, toRead, prevSize);
      else readSync(fd, buf, 0, toRead, start);
    } catch { closeSync(fd); return { queue: [], state }; }
    closeSync(fd);
    text += buf.toString('utf8');
  }
  const lastNl = text.lastIndexOf('\n');
  const complete = lastNl >= 0 ? text.slice(0, lastNl + 1) : '';
  const rest = lastNl >= 0 ? text.slice(lastNl + 1) : text;
  const queue = complete ? complete.split('\n').filter((l) => l.trim().length > 0) : [];
  return { queue, state: { size: st.size, textTail: rest } };
}

function jsonModel(file) {
  try { return String(JSON.parse(readFileSync(file, 'utf8')).model) || null; } catch { return null; }
}

function makeScanner(opts) {
  const state = {
    files: new Map(),
    dayRows: [],
    lastWalk: 0,
    found: false,
    ctx: {},
    active: true,
  };
  return {
    state,
    found() { return state.found; },
    rows() { return state.dayRows; },
    scan(dayStart, now) {
      let freshTotals = { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, messages: 0 };
      state.dayRows = state.dayRows.filter((r) => r.ts >= dayStart);
      if (state.dayRows.length > 30000) state.dayRows = state.dayRows.slice(-20000);
      if (now - state.lastWalk > 5000) {
        const seen = new Set();
        const all = [];
        for (const dir of opts.dirs) {
          if (!existsSync(dir)) continue;
          for (const p of walk(dir)) {
            if (!opts.fileFilter(p)) continue;
            if (seen.has(p)) continue;
            seen.add(p);
            all.push(p);
          }
        }
        for (const key of state.files.keys()) if (!seen.has(key)) state.files.delete(key);
        for (const p of all) if (!state.files.has(p)) state.files.set(p, null);
        state.lastWalk = now;
      }
      for (const [file, s0] of state.files) {
        if (s0) {
          let st;
          try { st = statSync(file); } catch { continue; }
          if (st.size === s0.size) continue;
        }
        const { queue, state: s1 } = readTail(file, s0 || {});
        if (s1.size > 0) state.found = true;
        state.files.set(file, s1);
        for (const line of queue) {
          const rec = opts.parse(line, state.ctx, file);
          if (!rec) continue;
          if (rec.ts >= dayStart) {
            state.dayRows.push(rec);
            freshTotals.input += rec.input;
            freshTotals.output += rec.output;
            freshTotals.reasoning += rec.reasoning;
            freshTotals.cacheRead += rec.cacheRead;
            freshTotals.cacheWrite += rec.cacheWrite;
            freshTotals.total += rec.total;
            freshTotals.cost += rec.cost;
            freshTotals.messages += rec.messages;
          }
        }
      }
      return freshTotals;
    },
  };
}

const sources = {};

sources.claude = makeScanner({
  dirs: [path.join(home, '.claude', 'projects')],
  fileFilter: (p) => p.endsWith('.jsonl'),
  parse(line) {
    let o;
    try { o = JSON.parse(line); } catch { return null; }
    const msg = o && o.message;
    const usage = msg && msg.usage;
    if (!usage || typeof usage !== 'object') return null;
    const input = usage.input_tokens || 0;
    const output = usage.output_tokens || 0;
    const cacheRead = usage.cache_read_input_tokens || 0;
    const cacheWrite = usage.cache_creation_input_tokens || 0;
    const ts = Date.parse(o.timestamp);
    if (!ts || !isFinite(ts)) return null;
    return {
      ts, tool: 'claude',
      model: (msg.model && String(msg.model)) || 'unknown',
      input, output, reasoning: 0, cacheRead, cacheWrite,
      total: input + output + cacheRead + cacheWrite,
      cost: 0, messages: 1, id: String(msg.id || o.uuid || (ts + ':' + line.length)),
    };
  },
});

sources.codex = makeScanner({
  dirs: [path.join(home, '.codex', 'sessions')],
  fileFilter: (p) => p.endsWith('.jsonl'),
  parse(line, ctx) {
    let o;
    try { o = JSON.parse(line); } catch { return null; }
    if (o.type === 'turn_context') {
      ctx.model = (o.payload && o.payload.model) || ctx.model;
      return null;
    }
    if (o.type !== 'event_msg') return null;
    const pl = o.payload;
    if (!pl || pl.type !== 'token_count' || !pl.info || !pl.info.total_token_usage) return null;
    const u = pl.info.total_token_usage;
    if (!ctx.prev) ctx.prev = {};
    const prev = ctx.prev;
    const g = (k) => (u && u[k]) || 0;
    const dIn = Math.max(0, g('input_tokens') - (prev.input || 0));
    const dCache = Math.max(0, g('cached_input_tokens') - (prev.cacheRead || 0));
    const dOut = Math.max(0, g('output_tokens') - (prev.output || 0));
    const dReas = Math.max(0, g('reasoning_output_tokens') - (prev.reasoning || 0));
    prev.input = g('input_tokens');
    prev.cacheRead = g('cached_input_tokens');
    prev.output = g('output_tokens');
    prev.reasoning = g('reasoning_output_tokens');
    if (dIn + dOut + dCache + dReas <= 0) return null;
    const ts = Date.parse(o.timestamp);
    if (!ts || !isFinite(ts)) return null;
    return {
      ts, tool: 'codex',
      model: ctx.model || 'unknown',
      input: dIn, output: dOut, reasoning: dReas, cacheRead: dCache, cacheWrite: 0,
      total: dIn + dOut + dCache + dReas,
      cost: 0, messages: 1, id: ts + ':' + line.length,
    };
  },
});

sources.kimi = makeScanner({
  dirs: [path.join(home, '.kimi-code', 'logs'), path.join(home, '.kimi-code', 'sessions')],
  fileFilter: (p) => p.endsWith('.log'),
  parse(line, ctx) {
    const m = line.match(/^([\dTZ:.-]+Z)\s+\S+\s+(llm request|llm response)\s+([^\n]*)/);
    if (!m) return null;
    const ts = Date.parse(m[1]);
    if (!ts || !isFinite(ts)) return null;
    if (m[2] === 'llm request') {
      const mm = m[3].match(/model=([^\s]+)/);
      if (mm) ctx.model = mm[1];
      return null;
    }
    const out = m[3].match(/outputTokens=(\d+)/);
    if (!out) return null;
    const output = Number(out[1]) || 0;
    return {
      ts, tool: 'kimi',
      model: ctx.model || 'kimi-code',
      input: 0, output, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: output,
      cost: 0, messages: 1, id: ts + ':' + line.length,
    };
  },
});

sources.deepcode = makeScanner({
  dirs: [path.join(home, '.deepcode', 'projects')],
  fileFilter: (p) => p.endsWith('.jsonl'),
  parse(line) {
    // deepcode jsonl（~/.deepcode/projects）只有消息内容，无 tokens/usage/cost 字段
    // 不产生统计行：全 0 记录会虚增 messages 并污染模型列表（踩坑记录5：不得编造数据）
    // 保留扫描器仅用于 toolsStatus 数据源检测
    return null;
  },
});

sources.zcode = makeScanner({
  dirs: [path.join(home, '.zcode'), path.join(process.env.APPDATA || '', 'ZCode'), path.join(process.env.LOCALAPPDATA || '', 'Programs', 'ZCode')],
  fileFilter: () => true,
  parse() { return null; },
});

for (const key of Object.keys(sources)) {
  if (key !== 'deepcode') continue;
  const model = jsonModel(path.join(home, '.deepcode', 'settings.json'));
  sources[key].state.ctx.model = model;
}

export function scanAll(dayStart, now) {
  const tools = {};
  let freshTotals = { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: 0, cost: 0, messages: 0 };
  const rows = [];
  for (const key of Object.keys(sources)) {
    const ft = sources[key].scan(dayStart, now);
    tools[key] = { found: sources[key].found(), rows: sources[key].rows().length };
    for (const k of Object.keys(freshTotals)) freshTotals[k] += ft[k];
    rows.push(...sources[key].rows());
  }
  return { tools, freshTotals, rows };
}

export function toolsStatus() {
  const list = [];
  const known = {
    claude: '~/.claude/projects',
    codex: '~/.codex/sessions',
    kimi: '~/.kimi-code',
    deepcode: '~/.deepcode',
    zcode: '~/.zcode | %APPDATA%\\ZCode',
  };
  for (const key of Object.keys(sources)) {
    list.push({ id: key, name: TOOL_LABEL[key], found: sources[key].found(), path: known[key] });
  }
  return list;
}