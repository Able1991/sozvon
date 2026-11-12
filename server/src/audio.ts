// Call audio in D1 (0.4.0+): tracks in chunks of at most CHUNK bytes (a D1 row holds at most 2 MB).
// No R2: it needs a payment card even on the free plan. Audio is served only to the Sozvon app (bearer password),
// never to the MCP tools.
//
// Upload: PUT every chunk (they land in audio_staging, tagged with the sha256 of the whole track), then POST commit,
// which checks that every chunk is there and swaps the new version in atomically (one D1 batch). An interrupted
// upload resumes: GET /api/calls/{id}/audio lists the staged chunks of each track.
//
// DELETE /api/calls/{id}/audio is a fact on the server, not just a cleanup: the call is marked (audio_removed), its
// chunk uploads and commits answer 410 from then on, and the listings say so, so no other Mac uploads its own copy back.
import { ensureSchema } from "./db";

export const CHUNK = 1_900_000; // bytes per chunk
export const MAX_CHUNK_INDEX = 9_999; // about 19 GB per track, far above anything a call records
// Bytes of audio in total. Audio shares one D1 database with the calls' text, and D1 caps a database at 500 MB on
// the free plan (10 GB on Workers Paid; the 5 GB of the free plan are per account, across databases). Past that cap
// D1 refuses every write, text included, so audio stops well before it: the rest is for the text, the search index
// and the second copy of a track that a commit holds for a moment.
export const AUDIO_LIMIT = 350_000_000;

/** The audio cap in bytes: AUDIO_LIMIT, or SOZVON_AUDIO_LIMIT_MB megabytes when that variable is a whole number
 *  above zero (for a Workers Paid account, whose databases hold 10 GB). */
export function audioLimit(env: { SOZVON_AUDIO_LIMIT_MB?: string }): number {
  const mb = (env.SOZVON_AUDIO_LIMIT_MB ?? "").trim();
  return /^[1-9]\d{0,6}$/.test(mb) ? Number(mb) * 1_000_000 : AUDIO_LIMIT;
}
export const TRACKS = ["mic", "system"] as const;
export type Track = (typeof TRACKS)[number];
export const SHA_RE = /^[0-9a-f]{64}$/;
const STALE_MS = 7 * 24 * 3600 * 1000; // staged chunks of an upload nobody finished go after a week

export const MAX_START = 86_400; // seconds: a track's start offset is at most a day
// The tables (audio_chunks, audio_tracks, audio_staging, audio_removed) are in db.ts with the others.

export const isTrack = (t: string): t is Track => (TRACKS as readonly string[]).includes(t);

/** Bytes of audio stored and staged: from the size columns, never reading a blob. */
export async function audioBytes(db: D1Database): Promise<number> {
  await ensureSchema(db);
  const r = await db.prepare(
    `SELECT (SELECT coalesce(sum(size), 0) FROM audio_tracks) + (SELECT coalesce(sum(size), 0) FROM audio_staging) AS n`,
  ).first<{ n: number }>();
  return r?.n ?? 0;
}

export class StorageFull extends Error {}

/** Stage one chunk of a track version (sha256 of the whole track). A chunk of another version drops the staged ones.
 *  Throws StorageFull when the audio would pass limit bytes. */
export async function putChunk(db: D1Database, callId: string, track: Track, idx: number, sha256: string,
                               data: ArrayBuffer, now = Date.now(), limit = AUDIO_LIMIT): Promise<void> {
  await ensureSchema(db);
  await db.batch([
    db.prepare(`DELETE FROM audio_staging WHERE at < ?1`).bind(now - STALE_MS),
    db.prepare(`DELETE FROM audio_staging WHERE call_id = ?1 AND track = ?2 AND sha256 <> ?3`).bind(callId, track, sha256),
  ]);
  const prev = await db.prepare(`SELECT size FROM audio_staging WHERE call_id = ?1 AND track = ?2 AND idx = ?3`)
    .bind(callId, track, idx).first<{ size: number }>();
  if ((await audioBytes(db)) - (prev?.size ?? 0) + data.byteLength > limit) throw new StorageFull("audio storage is full");
  await db.prepare(
    `INSERT INTO audio_staging (call_id, track, idx, sha256, size, at, data) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
     ON CONFLICT (call_id, track, idx) DO UPDATE SET sha256 = excluded.sha256, size = excluded.size, at = excluded.at,
       data = excluded.data`,
  ).bind(callId, track, idx, sha256, data.byteLength, now, data).run();
}

export interface Commit {
  size: number;
  chunks: number;
  sha256: string;
  start?: number | null; // seconds after the earlier track of the call started (0 for the earlier one); null: unknown
}

/** Swap the staged chunks in as the track's new version, atomically. -> the reason it can't, or null when done. */
export async function commitTrack(db: D1Database, callId: string, track: Track, c: Commit,
                                  now = new Date().toISOString()): Promise<string | null> {
  await ensureSchema(db);
  const r = await db.prepare(
    `SELECT count(*) AS n, coalesce(sum(size), 0) AS size, coalesce(max(idx), -1) AS top FROM audio_staging
     WHERE call_id = ?1 AND track = ?2 AND sha256 = ?3`,
  ).bind(callId, track, c.sha256).first<{ n: number; size: number; top: number }>();
  if (!r || r.n !== c.chunks || r.top !== c.chunks - 1 || r.size !== c.size) {
    return `missing chunks: ${r?.n ?? 0} of ${c.chunks} staged, ${r?.size ?? 0} of ${c.size} bytes`;
  }
  await db.batch([
    db.prepare(`DELETE FROM audio_chunks WHERE call_id = ?1 AND track = ?2`).bind(callId, track),
    db.prepare(`INSERT INTO audio_chunks (call_id, track, idx, data)
                SELECT call_id, track, idx, data FROM audio_staging WHERE call_id = ?1 AND track = ?2 AND sha256 = ?3`)
      .bind(callId, track, c.sha256),
    db.prepare(`DELETE FROM audio_staging WHERE call_id = ?1 AND track = ?2`).bind(callId, track),
    db.prepare(
      `INSERT INTO audio_tracks (call_id, track, size, chunks, sha256, updated_at, start) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
       ON CONFLICT (call_id, track) DO UPDATE SET size = excluded.size, chunks = excluded.chunks, sha256 = excluded.sha256,
         updated_at = excluded.updated_at, start = excluded.start`,
    ).bind(callId, track, c.size, c.chunks, c.sha256, now, c.start ?? null),
  ]);
  return null;
}

export interface TrackInfo {
  track: Track;
  size: number;
  chunks: number;
  sha256: string;
  updated_at: string;
  start: number | null;
}

export interface Pending {
  track: Track;
  sha256: string;
  chunks: { idx: number; size: number }[];
}

/** GET /api/calls/{id}/audio: the stored tracks, the chunks of unfinished uploads (to resume them), and when a Mac
 *  removed the call's audio (null: never). */
export async function listAudio(db: D1Database, callId: string):
    Promise<{ tracks: TrackInfo[]; pending: Pending[]; audio_removed_at: string | null }> {
  await ensureSchema(db);
  const [tracks, staged, removed] = await db.batch<Record<string, unknown>>([
    db.prepare(`SELECT track, size, chunks, sha256, updated_at, start FROM audio_tracks WHERE call_id = ?1 ORDER BY track`)
      .bind(callId),
    db.prepare(`SELECT track, sha256, idx, size FROM audio_staging WHERE call_id = ?1 ORDER BY track, idx`).bind(callId),
    db.prepare(`SELECT at FROM audio_removed WHERE call_id = ?1`).bind(callId),
  ]);
  const pending = new Map<string, Pending>();
  for (const s of staged.results as { track: Track; sha256: string; idx: number; size: number }[]) {
    const key = `${s.track}:${s.sha256}`;
    if (!pending.has(key)) pending.set(key, { track: s.track, sha256: s.sha256, chunks: [] });
    pending.get(key)!.chunks.push({ idx: s.idx, size: s.size });
  }
  const at = (removed.results[0] as { at?: string } | undefined)?.at ?? null;
  return { tracks: tracks.results as unknown as TrackInfo[], pending: [...pending.values()], audio_removed_at: at };
}

export async function getChunk(db: D1Database, callId: string, track: Track, idx: number): Promise<ArrayBuffer | null> {
  await ensureSchema(db);
  const r = await db.prepare(`SELECT data FROM audio_chunks WHERE call_id = ?1 AND track = ?2 AND idx = ?3`)
    .bind(callId, track, idx).first<{ data: ArrayBuffer | number[] }>();
  if (!r) return null;
  return r.data instanceof ArrayBuffer ? r.data : new Uint8Array(r.data).buffer;
}

/** Statements that remove all audio of a call (stored and staged): its bytes no longer count. */
export function deleteAudioStatements(db: D1Database, callId: string): D1PreparedStatement[] {
  return [
    db.prepare(`DELETE FROM audio_chunks WHERE call_id = ?1`).bind(callId),
    db.prepare(`DELETE FROM audio_tracks WHERE call_id = ?1`).bind(callId),
    db.prepare(`DELETE FROM audio_staging WHERE call_id = ?1`).bind(callId),
  ];
}

/** DELETE /api/calls/{id}/audio: remove the call's audio and mark it removed (the first time is kept). */
export async function removeAudio(db: D1Database, callId: string, now = new Date().toISOString()): Promise<void> {
  await ensureSchema(db);
  await db.batch([
    ...deleteAudioStatements(db, callId),
    db.prepare(`INSERT OR IGNORE INTO audio_removed (call_id, at) VALUES (?1, ?2)`).bind(callId, now),
  ]);
}

export async function isAudioRemoved(db: D1Database, callId: string): Promise<boolean> {
  await ensureSchema(db);
  return (await db.prepare(`SELECT 1 FROM audio_removed WHERE call_id = ?1`).bind(callId).first()) !== null;
}
