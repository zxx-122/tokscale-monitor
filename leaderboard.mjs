import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const LEADERBOARD_CACHE = process.env.TOKSCALE_LEADERBOARD_FILE || path.join(__dirname, 'leaderboard.json');
const API_URL = 'https://www.datalearner.com/api/leaderboards/external/aa-quality-index';
const TTL_MS = 6 * 3600 * 1000;
let cached = null;
let fetchedAt = 0;
let inFlight = null;

const FALLBACK = {
  sourceName: 'AA 智能指数排行榜 (Artificial Analysis Intelligence Index)',
  updatedAt: Date.now(),
  count: 0,
  items: [],
};

export async function fetchLeaderboard(force = false) {
  const now = Date.now();
  if (!force && cached && now - fetchedAt < TTL_MS) return cached;
  if (inFlight) return inFlight;
  inFlight = (async () => {
    try {
      const res = await fetch(API_URL, {
        method: 'GET',
        headers: {
          'user-agent': 'Mozilla/5.0',
          'accept': 'application/json',
          'referer': 'https://www.datalearner.com/leaderboards/external/aa-quality-index',
        },
        signal: AbortSignal.timeout(15000),
      });
      const parsed = JSON.parse(await res.text());
      const rows = Array.isArray(parsed.data) ? parsed.data : [];
      const items = rows
        .filter((r) => r && typeof r.modelName === 'string')
        .map((r) => ({
          rank: Number(r.rank) || 0,
          model: String(r.modelName),
          org: String(r.organization || ''),
          score: r.score != null ? Number(r.score) : null,
          modelCode: r.modelCode != null ? String(r.modelCode) : '',
          thinkingMode: r.thinkingMode != null ? String(r.thinkingMode) : '',
        }));
      if (!items.length) throw new Error('leaderboard empty');
      const meta = parsed.meta || {};
      cached = {
        source: API_URL,
        sourceName: 'AA 智能指数排行榜 (Artificial Analysis Intelligence Index)',
        updatedAt: now,
        month: meta.versionTime || '',
        count: items.length,
        items,
      };
      fetchedAt = now;
      try { writeFileSync(LEADERBOARD_CACHE, JSON.stringify(cached)); } catch {}
      return cached;
    } catch (err) {
      const fallback = { ...FALLBACK, stale: true, lastError: String((err && err.message) || err), source: API_URL };
      if (cached) {
        cached.stale = true;
        cached.lastError = String((err && err.message) || err);
        return cached;
      }
      if (existsSync(LEADERBOARD_CACHE)) {
        try {
          cached = JSON.parse(readFileSync(LEADERBOARD_CACHE, 'utf8'));
          cached.stale = true;
          cached.lastError = String((err && err.message) || err);
          return cached;
        } catch {}
      }
      return fallback;
    } finally {
      inFlight = null;
    }
  })();
  return inFlight;
}

export function leaderboardSnapshot() {
  return cached;
}
