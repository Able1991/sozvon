// D1 storage: calls, their transcripts, their notes and an FTS5 index of their chunks.
// The schema is created on first use (CREATE ... IF NOT EXISTS), so a fresh deploy needs no migration step
// and an older deploy gets the notes tables on its next start.
import { deleteAudioStatements } from "./audio";
import { chunks, noteChunk } from "./chunks";
import { stemText } from "./textproc";

export const SCHEMA = 1;
const STRIDE = 1_000_000; // chunk rowid = call num * STRIDE + n: a call's chunks are one rowid range
const NOTE_BASE = STRIDE - 1_000; // the last 1000 rowids of a call's range hold its notes
export const MAX_CHUNKS = NOTE_BASE; // transcript and summary lines of one call
export const MAX_NOTES = 200; // per call
export const MAX_NOTE_TEXT = 4000; // characters (code points)
export const NOTE_ID_RE = /^[A-Za-z0-9-]{1,64}$/;
const JSON_BATCH = 500_000; // characters of chunk JSON per INSERT (a bound value must stay under 2 MB)

const DDL = [
  `CREATE TABLE IF NOT EXISTS calls (
     num INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, hash TEXT NOT NULL, folder TEXT NOT NULL,
     call TEXT NOT NULL, summary TEXT, has_transcript INTEGER NOT NULL,
     topic TEXT NOT NULL, profile TEXT NOT NULL, people TEXT NOT NULL, seconds REAL NOT NULL,
     hay TEXT NOT NULL, updated_at TEXT NOT NULL, project_title TEXT NOT NULL DEFAULT '')`,
  `CREATE TABLE IF NOT EXISTS transcripts (num INTEGER PRIMARY KEY, text TEXT NOT NULL)`,
  `CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(
     stem, call_num UNINDEXED, kind UNINDEXED, ts UNINDEXED, speaker UNINDEXED, text UNINDEXED,
     tokenize = 'unicode61 remove_diacritics 2')`,
  `CREATE TABLE IF NOT EXISTS auth_failures (ip TEXT PRIMARY KEY, n INTEGER NOT NULL, since INTEGER NOT NULL)`,
  // Requests per IP to the unauthenticated endpoints that write to KV (/oauth/register, /authorize).
  `CREATE TABLE IF NOT EXISTS rate_limits (key TEXT PRIMARY KEY, n INTEGER NOT NULL, since INTEGER NOT NULL)`,
  // Notes are append-only; a deleted note leaves a tombstone, so a stale client can't bring it back.
  `CREATE TABLE IF NOT EXISTS notes (
     id TEXT NOT NULL, call_id TEXT NOT NULL, at TEXT NOT NULL, text TEXT NOT NULL, source TEXT NOT NULL,
     PRIMARY KEY (call_id, id))`,
  `CREATE TABLE IF NOT EXISTS note_tombstones (
     id TEXT NOT NULL, call_id TEXT NOT NULL, at TEXT NOT NULL, PRIMARY KEY (call_id, id))`,
  // A deleted call leaves a tombstone too, so another Mac that still has it can't upload it back.
  `CREATE TABLE IF NOT EXISTS call_tombstones (id TEXT PRIMARY KEY, at TEXT NOT NULL)`,
  // Voice prints (0.4.0+): biometric data, served only to the Sozvon app (bearer password), never to MCP tools.
  // A deleted voice keeps its row as a tombstone (deleted = 1, no name, no embedding).
  `CREATE TABLE IF NOT EXISTS voices (
     id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', profile TEXT NOT NULL DEFAULT '', me INTEGER NOT NULL DEFAULT 0,
     embedding TEXT NOT NULL DEFAULT '[]', seconds REAL NOT NULL DEFAULT 0, updated_at TEXT NOT NULL,
     deleted INTEGER NOT NULL DEFAULT 0)`,
  // Call audio (0.4.0+, audio.ts): chunks of at most 1.9 MB, the committed version of each track, and the chunks of
  // uploads in progress.
  `CREATE TABLE IF NOT EXISTS audio_chunks (
     call_id TEXT NOT NULL, track TEXT NOT NULL CHECK (track IN ('mic', 'system')), idx INTEGER NOT NULL,
     data BLOB NOT NULL, PRIMARY KEY (call_id, track, idx))`,
  `CREATE TABLE IF NOT EXISTS audio_tracks (
     call_id TEXT NOT NULL, track TEXT NOT NULL CHECK (track IN ('mic', 'system')), size INTEGER NOT NULL,
     chunks INTEGER NOT NULL, sha256 TEXT NOT NULL, updated_at TEXT NOT NULL, start REAL, PRIMARY KEY (call_id, track))`,
  `CREATE TABLE IF NOT EXISTS audio_staging (
     call_id TEXT NOT NULL, track TEXT NOT NULL CHECK (track IN ('mic', 'system')), idx INTEGER NOT NULL,
     sha256 TEXT NOT NULL, size INTEGER NOT NULL, at INTEGER NOT NULL, data BLOB NOT NULL,
     PRIMARY KEY (call_id, track, idx))`,
  // Calls whose audio a Mac removed (DELETE /api/calls/{id}/audio): no Mac uploads or downloads their audio again.
  `CREATE TABLE IF NOT EXISTS audio_removed (call_id TEXT PRIMARY KEY, at TEXT NOT NULL)`,
];

const ready = new WeakSet<D1Database>();

// Columns added after the first release: a deploy that created its tables earlier gets them here.
// text_hash: what the call's transcript and summary chunks were built from; a PUT with the same text skips
// rewriting them (FTS5 writes cost several D1 rows per line).
// audio_tracks.start: the track's start offset in seconds, relative to the earlier track of the call (null: unknown).
const ADDED_COLUMNS = [["calls", "project_title", "TEXT NOT NULL DEFAULT ''"], ["calls", "text_hash", "TEXT NOT NULL DEFAULT ''"],
                       ["audio_tracks", "start", "REAL"]];

// Bump when chunks() or stemText() change: every call's chunks are rebuilt on its next PUT.
const INDEX_VERSION = 1;

async function textHash(transcript: string, summary: string | null): Promise<string> {
  const data = new TextEncoder().encode(JSON.stringify([INDEX_VERSION, transcript, summary]));
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", data));
  return Array.from(h, (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function ensureSchema(db: D1Database): Promise<void> {
  if (ready.has(db)) return;
  await db.batch(DDL.map((sql) => db.prepare(sql)));
  for (const [table, column, type] of ADDED_COLUMNS) {
    const has = await db.prepare(`SELECT 1 FROM pragma_table_info('${table}') WHERE name = ?1`).bind(column).first();
    if (!has) await db.prepare(`ALTER TABLE ${table} ADD COLUMN ${column} ${type}`).run();
  }
  ready.add(db);
}

/** The project as tools show it: the title the client sent, else the project slug. */
export const PROJECT = `coalesce(nullif(calls.project_title, ''), calls.profile)`;

export interface Note {
  id: string;
  at: string;
  text: string;
  source: string;
}

export interface CallPayload {
  schema: 1;
  id: string;
  hash: string;
  folder: string;
  call: Record<string, unknown>;
  transcript: string;
  summary: string | null;
  notes?: Note[]; // merged into the stored notes, never replacing them
  notes_deleted?: string[]; // tombstones
  project_title?: string; // the project's display title on the Mac (call.profile is its slug)
}

/** A valid note with only its four fields, or the reason it is not. */
export function validNote(v: unknown): Note | string {
  if (!v || typeof v !== "object" || Array.isArray(v)) return "a note must be an object";
  const n = v as Record<string, unknown>;
  if (typeof n.id !== "string" || !NOTE_ID_RE.test(n.id)) return "note id must be 1-64 letters, digits or dashes";
  if (typeof n.at !== "string" || !n.at.trim() || n.at.length > 40) return "note at must be an ISO 8601 time";
  if (typeof n.text !== "string" || !n.text.trim()) return "note text must be a non-empty string";
  if ([...n.text].length > MAX_NOTE_TEXT) return `note text is longer than ${MAX_NOTE_TEXT} characters`;
  const source = typeof n.source === "string" && n.source && n.source.length <= 40 ? n.source : "assistant";
  return { id: n.id, at: n.at, text: n.text, source };
}

const str = (v: unknown) => (typeof v === "string" ? v : v == null ? "" : String(v));

export function callMeta(call: Record<string, unknown>) {
  // "participants" (derived from the transcript by newer apps), else "names" (what the user typed; older apps).
  const list = Array.isArray(call.participants) ? call.participants : call.names;
  const names = Array.isArray(list) ? list.map(str) : [];
  const audio = (call.audio && typeof call.audio === "object" ? call.audio : {}) as Record<string, unknown>;
  const seconds = Math.max(Number(audio.mic_seconds) || 0, Number(audio.system_seconds) || 0);
  return { topic: str(call.topic), profile: str(call.profile), people: names.join(", "), seconds };
}

const NOTE_FIELDS = new Set(["notes", "notes_deleted"]);
const withoutNotes = (call: Record<string, unknown>) =>
  Object.fromEntries(Object.entries(call).filter(([k]) => !NOTE_FIELDS.has(k)));

/** A payload with more transcript and summary lines than a call's rowid range holds (MAX_CHUNKS). */
export class TooManyLines extends Error {}

/** Upsert a call, merge its notes and reindex its chunks, atomically (one D1 batch counts as one query).
 *  Notes the server has and the payload lacks are kept: only tombstones (and the MAX_NOTES limit) remove a note.
 *  The transcript and summary chunks (and the transcripts row) are rewritten only when that text changed, the
 *  note chunks only when the notes changed: a PUT for a new title, folder or metadata writes just the calls row. */
export async function putCall(db: D1Database, p: CallPayload, restore = false): Promise<void> {
  await ensureSchema(db);
  // A client that does not know about notes may still carry them inside call.json.
  const fromCall = Array.isArray(p.call.notes) ? p.call.notes.map(validNote).filter((n): n is Note => typeof n !== "string") : [];
  const merge = await planNotes(db, p.id, p.notes ?? fromCall, p.notes_deleted ?? []);
  p = { ...p, call: withoutNotes(p.call) };
  const m = callMeta(p.call);
  const title = p.project_title ?? "";
  const hay = [p.id, p.folder, m.topic, m.profile, title, m.people].join(" ").toLowerCase();
  const th = await textHash(p.transcript, p.summary);
  const prev = await db.prepare(`SELECT text_hash FROM calls WHERE id = ?1`).bind(p.id).first<{ text_hash: string }>();
  const reindex = !prev || prev.text_hash !== th;
  const rows = reindex ? chunks(p.transcript, p.summary)
    .map((c) => JSON.stringify([stemText(`${c.speaker} ${c.text}`), c.kind, c.ts, c.speaker, c.text])) : [];
  if (rows.length >= MAX_CHUNKS) throw new TooManyLines(`more than ${MAX_CHUNKS - 1} lines`);
  const num = `(SELECT num FROM calls WHERE id = ?1)`;
  const stmts: D1PreparedStatement[] = [];
  if (reindex) {
    stmts.push(db.prepare(`DELETE FROM chunks WHERE rowid BETWEEN ${num} * ${STRIDE} AND ${num} * ${STRIDE} + ${NOTE_BASE - 1}`)
      .bind(p.id));
  }
  stmts.push(db.prepare(
      `INSERT INTO calls (num, id, hash, folder, call, summary, has_transcript, topic, profile, people, seconds, hay, updated_at,
                          project_title, text_hash)
       VALUES ((SELECT coalesce(max(num), 0) + 1 FROM calls), ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
       ON CONFLICT (id) DO UPDATE SET hash = excluded.hash, folder = excluded.folder, call = excluded.call,
         summary = excluded.summary, has_transcript = excluded.has_transcript, topic = excluded.topic,
         profile = excluded.profile, people = excluded.people, seconds = excluded.seconds, hay = excluded.hay,
         updated_at = excluded.updated_at, project_title = excluded.project_title, text_hash = excluded.text_hash`,
    ).bind(p.id, p.hash, p.folder, JSON.stringify(p.call), p.summary, p.transcript.trim() ? 1 : 0,
           m.topic, m.profile, m.people, m.seconds, hay, new Date().toISOString(), title, th));
  if (reindex) {
    stmts.push(db.prepare(`INSERT OR REPLACE INTO transcripts (num, text) VALUES (${num}, ?2)`).bind(p.id, p.transcript));
  }
  for (let start = 0; start < rows.length;) {
    let end = start, size = 0;
    while (end < rows.length && (end === start || size < JSON_BATCH)) size += rows[end++].length + 1;
    stmts.push(db.prepare(
      `INSERT INTO chunks (rowid, stem, call_num, kind, ts, speaker, text)
       SELECT ${num} * ${STRIDE} + ?2 + key, json_extract(value, '$[0]'), ${num}, json_extract(value, '$[1]'),
              json_extract(value, '$[2]'), json_extract(value, '$[3]'), json_extract(value, '$[4]')
       FROM json_each(?3)`,
    ).bind(p.id, start, `[${rows.slice(start, end).join(",")}]`));
    start = end;
  }
  if (changes(merge)) stmts.push(...noteStatements(db, p.id, merge));
  if (restore) stmts.push(db.prepare(`DELETE FROM call_tombstones WHERE id = ?1`).bind(p.id));
  await db.batch(stmts);
}

interface NotesPlan {
  tombstones: string[]; // new tombstones
  remove: string[]; // stored notes to delete (tombstoned, or older than the newest MAX_NOTES)
  insert: Note[];
  all: Note[]; // the notes after the change, oldest first
  evicted: number; // stored or incoming notes left out by the MAX_NOTES limit
}

const changes = (plan: NotesPlan) => plan.tombstones.length > 0 || plan.remove.length > 0 || plan.insert.length > 0;
const byTime = (a: Note, b: Note) => (a.at < b.at ? -1 : a.at > b.at ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

/** What merging incoming notes and tombstones into a call's stored notes does. Never drops a stored note
 *  unless it is tombstoned or the limit applies: at most MAX_NOTES, the newest by (at, id), the same ones the
 *  Mac keeps (engine notes.newest), so two Macs with more than that together agree instead of resending. */
async function planNotes(db: D1Database, callId: string, incoming: Note[], deleted: string[]): Promise<NotesPlan> {
  const [stored, tombs] = await db.batch<{ id: string; at?: string; text?: string; source?: string }>([
    db.prepare(`SELECT id, at, text, source FROM notes WHERE call_id = ?1 ORDER BY at, id`).bind(callId),
    db.prepare(`SELECT id FROM note_tombstones WHERE call_id = ?1`).bind(callId),
  ]);
  const dead = new Set(tombs.results.map((t) => t.id));
  const tombstones = [...new Set(deleted)].filter((id) => NOTE_ID_RE.test(id) && !dead.has(id));
  tombstones.forEach((id) => dead.add(id));
  const have = stored.results as Note[];
  const remove = have.filter((n) => dead.has(n.id)).map((n) => n.id);
  let all = have.filter((n) => !dead.has(n.id));
  const ids = new Set(have.map((n) => n.id));
  const fresh: Note[] = [];
  for (const n of incoming) {
    if (ids.has(n.id) || dead.has(n.id)) continue;
    ids.add(n.id);
    fresh.push(n);
  }
  all = [...all, ...fresh].sort(byTime);
  const out = new Set(all.slice(0, Math.max(0, all.length - MAX_NOTES)).map((n) => n.id));
  all = all.filter((n) => !out.has(n.id));
  const insert = fresh.filter((n) => !out.has(n.id));
  remove.push(...have.filter((n) => out.has(n.id) && !dead.has(n.id)).map((n) => n.id));
  return { tombstones, remove, insert, all, evicted: out.size };
}

/** Statements that apply a notes plan, and rebuild the call's note chunks when its notes changed (new tombstones
 *  alone, for notes the call does not have, leave the search index as it is). */
function noteStatements(db: D1Database, callId: string, plan: NotesPlan): D1PreparedStatement[] {
  const now = new Date().toISOString();
  const num = `(SELECT num FROM calls WHERE id = ?1)`;
  const stmts: D1PreparedStatement[] = [];
  if (plan.tombstones.length) {
    stmts.push(db.prepare(`INSERT OR IGNORE INTO note_tombstones (id, call_id, at) SELECT value, ?1, ?2 FROM json_each(?3)`)
      .bind(callId, now, JSON.stringify(plan.tombstones)));
  }
  if (plan.remove.length) {
    stmts.push(db.prepare(`DELETE FROM notes WHERE call_id = ?1 AND id IN (SELECT value FROM json_each(?2))`)
      .bind(callId, JSON.stringify(plan.remove)));
  }
  if (plan.insert.length) {
    stmts.push(db.prepare(
      `INSERT OR IGNORE INTO notes (id, call_id, at, text, source)
       SELECT json_extract(value, '$.id'), ?1, json_extract(value, '$.at'), json_extract(value, '$.text'),
              json_extract(value, '$.source') FROM json_each(?2)`,
    ).bind(callId, JSON.stringify(plan.insert)));
  }
  if (!plan.remove.length && !plan.insert.length) return stmts;
  stmts.push(db.prepare(`DELETE FROM chunks WHERE rowid BETWEEN ${num} * ${STRIDE} + ${NOTE_BASE} AND ${num} * ${STRIDE} + ${STRIDE - 1}`)
    .bind(callId));
  if (plan.all.length) {
    const rows = plan.all.map((n) => {
      const c = noteChunk(n);
      return JSON.stringify([stemText(`${c.speaker} ${c.text}`), c.kind, c.ts, c.speaker, c.text]);
    });
    stmts.push(db.prepare(
      `INSERT INTO chunks (rowid, stem, call_num, kind, ts, speaker, text)
       SELECT ${num} * ${STRIDE} + ${NOTE_BASE} + key, json_extract(value, '$[0]'), ${num}, json_extract(value, '$[1]'),
              json_extract(value, '$[2]'), json_extract(value, '$[3]'), json_extract(value, '$[4]')
       FROM json_each(?2) WHERE ${num} IS NOT NULL`,
    ).bind(callId, `[${rows.join(",")}]`));
  }
  return stmts;
}

export async function callExists(db: D1Database, id: string): Promise<boolean> {
  await ensureSchema(db);
  return (await db.prepare(`SELECT 1 FROM calls WHERE id = ?1`).bind(id).first()) !== null;
}

/** Merge notes and tombstones into a stored call without touching the call. -> false if there is no such call. */
export async function mergeNotes(db: D1Database, callId: string, incoming: Note[], deleted: string[]): Promise<boolean> {
  if (!(await callExists(db, callId))) return false;
  const plan = await planNotes(db, callId, incoming, deleted);
  if (!changes(plan)) return true;
  await db.batch(noteStatements(db, callId, plan));
  return true;
}

/** A tombstone for a note (kept, so a stale client can't resurrect it), and the note gone. */
export async function deleteNote(db: D1Database, callId: string, noteId: string): Promise<void> {
  await ensureSchema(db);
  const plan = await planNotes(db, callId, [], [noteId]);
  if (changes(plan)) await db.batch(noteStatements(db, callId, plan)); // deleted before: nothing to write
}

export class NoteLimitError extends Error {}

/** Append one note (the add_note tool). Throws NoteLimitError when the call already has MAX_NOTES. */
export async function addNote(db: D1Database, callId: string, note: Note): Promise<void> {
  await ensureSchema(db);
  const plan = await planNotes(db, callId, [note], []);
  // add_note never pushes an older note out: at the limit it is refused.
  if (!plan.insert.length || plan.evicted) throw new NoteLimitError(`the call already has ${MAX_NOTES} notes, the limit`);
  await db.batch(noteStatements(db, callId, plan));
}

export async function notesOf(db: D1Database, callId: string): Promise<Note[]> {
  await ensureSchema(db);
  const { results } = await db.prepare(`SELECT id, at, text, source FROM notes WHERE call_id = ?1 ORDER BY at, id`)
    .bind(callId).all<Note>();
  return results;
}

/** Delete a call and leave a tombstone (id, deleted_at): a stale copy on another Mac can't come back. */
export async function deleteCall(db: D1Database, id: string, now = new Date().toISOString()): Promise<void> {
  await ensureSchema(db);
  const num = `(SELECT num FROM calls WHERE id = ?1)`;
  await db.batch([
    db.prepare(`DELETE FROM chunks WHERE rowid BETWEEN ${num} * ${STRIDE} AND ${num} * ${STRIDE} + ${STRIDE - 1}`).bind(id),
    db.prepare(`DELETE FROM transcripts WHERE num = ${num}`).bind(id),
    db.prepare(`DELETE FROM calls WHERE id = ?1`).bind(id),
    db.prepare(`DELETE FROM notes WHERE call_id = ?1`).bind(id),
    db.prepare(`DELETE FROM note_tombstones WHERE call_id = ?1`).bind(id),
    ...deleteAudioStatements(db, id),
    db.prepare(`INSERT INTO call_tombstones (id, at) VALUES (?1, ?2) ON CONFLICT (id) DO UPDATE SET at = excluded.at`)
      .bind(id, now),
  ]);
}

export interface CallTombstone {
  id: string;
  at: string;
}

/** Calls deleted on the server, oldest id first (GET /api/calls, "deleted"). */
export async function callTombstones(db: D1Database): Promise<CallTombstone[]> {
  await ensureSchema(db);
  const { results } = await db.prepare(`SELECT id, at FROM call_tombstones ORDER BY id`).all<CallTombstone>();
  return results;
}

export async function isTombstoned(db: D1Database, id: string): Promise<boolean> {
  await ensureSchema(db);
  return (await db.prepare(`SELECT 1 FROM call_tombstones WHERE id = ?1`).bind(id).first()) !== null;
}

export interface CallSummary {
  id: string;
  hash: string;
  folder: string;
  notes: string[];
  notes_deleted: string[];
  project_title: string;
  audio?: Record<string, string>;
  audio_removed_at?: string;
}

/** GET /api/calls: every call with what the client needs to diff (hash, folder, note ids, tombstones). */
export async function listHashes(db: D1Database): Promise<CallSummary[]> {
  await ensureSchema(db);
  const { results } = await db.prepare(
    `SELECT id, hash, folder, project_title,
       (SELECT json_group_array(n.id) FROM notes n WHERE n.call_id = calls.id) AS notes,
       (SELECT json_group_array(t.id) FROM note_tombstones t WHERE t.call_id = calls.id) AS notes_deleted,
       (SELECT json_group_object(a.track, a.sha256) FROM audio_tracks a WHERE a.call_id = calls.id) AS audio,
       (SELECT r.at FROM audio_removed r WHERE r.call_id = calls.id) AS audio_removed_at
     FROM calls ORDER BY id`,
  ).all<{ id: string; hash: string; folder: string; project_title: string; notes: string; notes_deleted: string; audio: string | null;
          audio_removed_at: string | null }>();
  return results.map((r) => {
    const audio = r.audio ? (JSON.parse(r.audio) as Record<string, string>) : {};
    return { id: r.id, hash: r.hash, folder: r.folder,
             notes: (JSON.parse(r.notes) as string[]).sort(),
             notes_deleted: (JSON.parse(r.notes_deleted) as string[]).sort(),
             project_title: r.project_title,
             // track -> sha256 of the stored audio (0.4.0+), only for calls that have some
             ...(Object.keys(audio).length ? { audio } : {}),
             // when a Mac removed the call's audio (0.4.0+): no Mac syncs its audio again
             ...(r.audio_removed_at ? { audio_removed_at: r.audio_removed_at } : {}) };
  });
}

/** GET /api/calls/{id}: the stored payload with its notes, for restoring the call on a Mac. */
export async function getStored(db: D1Database, id: string): Promise<Required<CallPayload> | null> {
  await ensureSchema(db);
  const r = await db.prepare(
    `SELECT id, hash, folder, call, summary, project_title, (SELECT text FROM transcripts t WHERE t.num = calls.num) AS transcript
     FROM calls WHERE id = ?1`,
  ).bind(id).first<{ id: string; hash: string; folder: string; call: string; summary: string | null; transcript: string | null;
                     project_title: string }>();
  if (!r) return null;
  const { results: tombs } = await db.prepare(`SELECT id FROM note_tombstones WHERE call_id = ?1 ORDER BY id`)
    .bind(id).all<{ id: string }>();
  return { schema: SCHEMA, id: r.id, hash: r.hash, folder: r.folder, call: JSON.parse(r.call) as Record<string, unknown>,
           transcript: r.transcript ?? "", summary: r.summary, notes: await notesOf(db, id),
           notes_deleted: tombs.map((t) => t.id), project_title: r.project_title };
}

export const VOICE_DIM = 256;
export const VOICE_ID_RE = /^[0-9a-f]{32}$/;

export interface Voice {
  id: string;
  name: string;
  profile: string;
  me: boolean;
  embedding: number[];
  seconds: number;
  updated_at: string;
}

export type VoiceRow = Voice | { id: string; deleted: true; updated_at: string };

const time = (s: string) => {
  const t = Date.parse(s);
  return Number.isNaN(t) ? 0 : t;
};

/** GET /api/voices: every voice print and every tombstone, by id. */
export async function listVoices(db: D1Database): Promise<VoiceRow[]> {
  await ensureSchema(db);
  const { results } = await db.prepare(
    `SELECT id, name, profile, me, embedding, seconds, updated_at, deleted FROM voices ORDER BY id`,
  ).all<{ id: string; name: string; profile: string; me: number; embedding: string; seconds: number; updated_at: string; deleted: number }>();
  return results.map((r) => r.deleted
    ? { id: r.id, deleted: true as const, updated_at: r.updated_at }
    : { id: r.id, name: r.name, profile: r.profile, me: r.me === 1, embedding: JSON.parse(r.embedding) as number[],
        seconds: r.seconds, updated_at: r.updated_at });
}

export type PutVoiceResult = { status: "ok" } | { status: "gone" } | { status: "conflict"; stored: Voice };

/** Store a voice print. -> gone when a tombstone is newer than it (deleted elsewhere after this change); conflict
 *  (with the stored record) when the stored one is newer and holds another embedding: two Macs enrolled the same voice
 *  at once, and the client merges the two prints and sends the result. A newer stored record with the same embedding
 *  is kept as is. */
export async function putVoice(db: D1Database, v: Voice): Promise<PutVoiceResult> {
  await ensureSchema(db);
  const prev = await db.prepare(
    `SELECT name, profile, me, embedding, seconds, updated_at, deleted FROM voices WHERE id = ?1`,
  ).bind(v.id).first<{ name: string; profile: string; me: number; embedding: string; seconds: number; updated_at: string;
                       deleted: number }>();
  if (prev?.deleted && time(prev.updated_at) >= time(v.updated_at)) return { status: "gone" };
  if (prev && !prev.deleted && time(prev.updated_at) > time(v.updated_at)) {
    if (prev.embedding === JSON.stringify(v.embedding)) return { status: "ok" };
    return { status: "conflict", stored: { id: v.id, name: prev.name, profile: prev.profile, me: prev.me === 1,
                                           embedding: JSON.parse(prev.embedding) as number[], seconds: prev.seconds,
                                           updated_at: prev.updated_at } };
  }
  await db.prepare(
    `INSERT INTO voices (id, name, profile, me, embedding, seconds, updated_at, deleted) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0)
     ON CONFLICT (id) DO UPDATE SET name = excluded.name, profile = excluded.profile, me = excluded.me,
       embedding = excluded.embedding, seconds = excluded.seconds, updated_at = excluded.updated_at, deleted = 0`,
  ).bind(v.id, v.name, v.profile, v.me ? 1 : 0, JSON.stringify(v.embedding), v.seconds, v.updated_at).run();
  return { status: "ok" };
}

/** Delete a voice print and keep a tombstone, so a stale copy on another Mac can't come back. */
export async function deleteVoice(db: D1Database, id: string, now = new Date().toISOString()): Promise<void> {
  await ensureSchema(db);
  await db.prepare(
    `INSERT INTO voices (id, updated_at, deleted) VALUES (?1, ?2, 1)
     ON CONFLICT (id) DO UPDATE SET name = '', profile = '', me = 0, embedding = '[]', seconds = 0,
       updated_at = excluded.updated_at, deleted = 1`,
  ).bind(id, now).run();
}
