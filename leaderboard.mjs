import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TTL_MS = 6 * 3600 * 1000;

const SOURCES = {
  aa: {
    api: 'https://www.datalearner.com/api/leaderboards/external/aa-quality-index',
    name: 'AA 智能指数排行榜 (Artificial Analysis Intelligence Index)',
    cacheFile: process.env.TOKSCALE_LB_FILE_AA || path.join(__dirname, 'leaderboard.aa.json'),
    monthOf(j) { return (j.meta && j.meta.versionTime) || ''; },
    normalize(j) {
      const rows = Array.isArray(j.data) ? j.data : [];
      return rows
        .filter((r) => r && typeof r.modelName === 'string')
        .map((r) => ({
          rank: Number(r.rank) || 0,
          model: String(r.modelName),
          org: String(r.organization || ''),
          score: r.score != null ? Number(r.score) : null,
          modelCode: r.modelCode != null ? String(r.modelCode) : '',
          thinkingMode: r.thinkingMode != null ? String(r.thinkingMode) : '',
        }));
    },
  },
  code: {
    api: 'https://www.datalearner.com/api/leaderboards/category/code',
    name: '编程能力排行榜 (SWE-bench 等)',
    cacheFile: process.env.TOKSCALE_LB_FILE_CODE || path.join(__dirname, 'leaderboard.code.json'),
    monthOf() { return ''; },
    normalize(j) {
      const rows = Array.isArray(j.leaderboardData) ? j.leaderboardData : [];
      return rows
        .filter((r) => r && typeof r.MODEL_ABBR_NAME === 'string')
        .map((r) => ({
          rank: Number(r.rank) || 0,
          model: String(r.MODEL_ABBR_NAME),
          org: String(r.orgName || ''),
          // 主分取 SWE-bench Verified（0 视为无效分），四舍五入到 1 位小数
          score: r['SWE-bench Verified'] != null && Number(r['SWE-bench Verified']) > 0 ? Math.round(Number(r['SWE-bench Verified']) * 10) / 10 : null,
          modelCode: r.MODEL_CODE != null ? String(r.MODEL_CODE) : '',
          thinkingMode: r.modelMode != null ? String(r.modelMode) : '',
        }));
    },
  },
};

// 当前活跃榜单源（默认 aa），/stats 的 leaderboard 快照取自该源
let activeSource = process.env.TOKSCALE_LB_SOURCE || 'aa';
if (!SOURCES[activeSource]) activeSource = 'aa';

const cache = { aa: null, code: null };
const fetchedAt = { aa: 0, code: 0 };
const inFlight = { aa: null, code: null };

export function getActiveSource() { return activeSource; }

export function setActiveSource(s) {
  if (SOURCES[s]) activeSource = s;
  return activeSource;
}

export async function fetchLeaderboard(force = false, source = activeSource) {
  if (!SOURCES[source]) source = 'aa';
  const now = Date.now();
  const st = SOURCES[source];
  if (!force && cache[source] && now - fetchedAt[source] < TTL_MS) return cache[source];
  if (inFlight[source]) return inFlight[source];
  inFlight[source] = (async () => {
    try {
      const res = await fetch(st.api, {
        method: 'GET',
        headers: {
          'user-agent': 'Mozilla/5.0',
          'accept': 'application/json',
          'referer': 'https://www.datalearner.com/leaderboards',
        },
        signal: AbortSignal.timeout(15000),
      });
      const parsed = JSON.parse(await res.text());
      const items = st.normalize(parsed);
      if (!items.length) throw new Error('leaderboard empty');
      cache[source] = {
        source: st.api,
        sourceName: st.name,
        updatedAt: now,
        month: st.monthOf(parsed),
        count: items.length,
        items,
      };
      fetchedAt[source] = now;
      try { writeFileSync(st.cacheFile, JSON.stringify(cache[source])); } catch {}
      return cache[source];
    } catch (err) {
      const errMsg = String((err && err.message) || err);
      if (cache[source]) {
        cache[source].stale = true;
        cache[source].lastError = errMsg;
        return cache[source];
      }
      if (existsSync(st.cacheFile)) {
        try {
          cache[source] = JSON.parse(readFileSync(st.cacheFile, 'utf8'));
          cache[source].stale = true;
          cache[source].lastError = errMsg;
          return cache[source];
        } catch {}
      }
      return { sourceName: st.name, updatedAt: now, count: 0, items: [], stale: true, lastError: errMsg, source: st.api };
    } finally {
      inFlight[source] = null;
    }
  })();
  return inFlight[source];
}

export function leaderboardSnapshot() {
  return cache[activeSource];
}
