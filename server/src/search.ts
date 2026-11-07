// Ranked search over call chunks: a port of engine/sozvon_engine/search.py.
// Snowball-stemmed BM25 (SQLite FTS5) for the query and each alternative phrasing, Reciprocal Rank
// Fusion of those lists, then re-ranking by coverage (the share of query words present in a chunk).
import { ensureSchema, PROJECT } from "./db";
import { ftsQuery, words } from "./textproc";

export const RRF_K = 60;
export const POOL = 80;
export const COVERAGE_WEIGHT = 0.5;
export const VARIANT_WEIGHT = 1.0;

export interface Hit {
  rid: number;
  call_id: string;
  kind: string; // "transcript", "summary" or "note"
  ts: string;
  speaker: string; // summary: section heading; note: its source
  text: string;
  topic: string;
  profile: string; // project title, else slug
}

export interface Scored extends Hit {
  score: number;
}

export const MAX_ALSO = 5; // alternative phrasings, like the engine's search_calls
export const MAX_QUERY = 500; // characters per phrasing

/** Distinct non-empty queries: the query first, then at most MAX_ALSO alternative phrasings, each cut to MAX_QUERY. */
export function queryList(text: string, also: unknown[] = []): string[] {
  const out: string[] = [];
  for (const q of [text, ...(Array.isArray(also) ? also.slice(0, MAX_ALSO) : [])]) {
    if (typeof q !== "string") continue;
    const s = q.trim().slice(0, MAX_QUERY);
    if (s && !out.includes(s)) out.push(s);
  }
  return out;
}

const norm = (text: string) => text.toLowerCase().split(/\s+/).filter(Boolean).join(" ").slice(0, 400);

/** Fuse per-query BM25 lists (best first) into hits, best first. lists[0] belongs to queries[0]. */
export function rank(queries: string[], lists: Hit[][], limit: number,
                     coverage = COVERAGE_WEIGHT, variantWeight = VARIANT_WEIGHT): Scored[] {
  const scores = new Map<number, number>();
  const meta = new Map<number, Hit>();
  lists.forEach((list, n) => {
    const w = n === 0 ? 1.0 : variantWeight;
    list.forEach((h, pos) => {
      scores.set(h.rid, (scores.get(h.rid) ?? 0) + w / (RRF_K + pos));
      meta.set(h.rid, h);
    });
  });
  if (scores.size === 0) return [];
  const top = Math.max(...scores.values());
  const qwords = queries.map((q) => new Set(words(q).filter((w) => [...w].length > 2))).filter((s) => s.size > 0);
  const score = (rid: number) => {
    let base = scores.get(rid)! / top;
    if (coverage && qwords.length) {
      const have = new Set(words(`${meta.get(rid)!.speaker} ${meta.get(rid)!.text}`));
      const cov = Math.max(...qwords.map((s) => [...s].filter((w) => have.has(w)).length / s.size));
      base = coverage * cov + (1 - coverage) * base;
    }
    return base;
  };
  const scored = [...scores.keys()].map((rid) => ({ ...meta.get(rid)!, score: score(rid) }));
  scored.sort((a, b) => b.score - a.score); // stable, like Python's sorted(reverse=True)
  const out: Scored[] = [];
  const seen = new Set<string>();
  for (const h of scored) {
    const key = `${h.call_id}\u0000${norm(h.text)}`; // the same words twice in one call: keep the better one
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(h);
    if (out.length >= limit) break;
  }
  return out;
}

const BM25 = `SELECT chunks.rowid AS rid, calls.id AS call_id, chunks.kind AS kind, chunks.ts AS ts,
                     chunks.speaker AS speaker, chunks.text AS text, calls.topic AS topic, ${PROJECT} AS profile
              FROM chunks JOIN calls ON calls.num = chunks.call_num
              WHERE chunks MATCH ?1 ORDER BY chunks.rank LIMIT ?2`;

/** Rank chunks for text and its alternative phrasings: one D1 batch, BM25 per phrasing. */
export async function search(db: D1Database, text: string, also: unknown[] = [], limit = 20): Promise<Scored[]> {
  const queries = queryList(text, also);
  const fts = queries.map(ftsQuery);
  if (!fts.some(Boolean)) return [];
  await ensureSchema(db);
  const results = await db.batch<Hit>(fts.filter(Boolean).map((q) => db.prepare(BM25).bind(q, POOL)));
  let i = 0;
  const lists = fts.map((q) => (q ? results[i++].results : []));
  return rank(queries, lists, limit);
}
