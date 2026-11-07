// MCP tools over D1. list_calls, get_call, search_calls and add_note answer like the local tools in
// engine/sozvon_engine/mcp/tools.py; search and fetch follow the ChatGPT connector shape.
// add_note and delete_note are the only writes: notes, limited (db.ts); a deleted note leaves a tombstone.
import { addNote as storeNote, deleteNote as dropNote, ensureSchema, MAX_NOTE_TEXT, type Note, NoteLimitError, notesOf, PROJECT } from "./db";
import { search as rankedSearch } from "./search";
import { words } from "./textproc";

export const T = {
  noCalls: "No calls found.",
  hasSummary: "summary",
  hasTranscript: "transcript",
  noTranscript: "no transcript",
  noSummaryFile: "(no summary)",
  noTranscriptFile: "(no transcript)",
  emptyQuery: "Empty query.",
  nothingFound: "Nothing found.",
  noCall: (id: string) => `no call ${id}`,
  notes: "Notes",
  note: "note",
  notesN: (n: number) => `notes: ${n}`,
  noteAdded: (id: string) => `Note added to call ${id}. It is visible in the Sozvon app.`,
  noteDeleted: (note: string, id: string) => `Note ${note} deleted from call ${id}.`,
  noNote: (id: string) => `no note ${id} on this call`,
  noteEmpty: "the note is empty",
  noteTooLong: `the note is longer than ${MAX_NOTE_TEXT} characters`,
};

/** Short lowercase source from an MCP client name, as notes.source_name in the engine. */
export function sourceName(raw: string | undefined | null): string {
  const name = String(raw ?? "").toLowerCase().replace(/_/g, "-").split(/\s+/).filter(Boolean).join(" ");
  for (const [needle, source] of [["claude-code", "claude-code"], ["claude code", "claude-code"], ["codex", "codex"],
                                  ["chatgpt", "chatgpt"], ["openai", "chatgpt"], ["claude", "claude"]]) {
    if (name.includes(needle)) return source;
  }
  return name.replace(/[^a-z0-9.-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "assistant";
}

export function formatTimestamp(seconds: number): string {
  const s = Math.max(0, seconds);
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = Math.floor(s % 60);
  const p = (n: number) => String(n).padStart(2, "0");
  return h ? `${p(h)}:${p(m)}:${p(sec)}` : `${p(m)}:${p(sec)}`;
}

export const trim = (text: string, n = 300) => ([...text].length <= n ? text : [...text].slice(0, n - 1).join("").trimEnd() + "…");

interface CallRow {
  num: number;
  id: string;
  folder: string;
  topic: string;
  profile: string;
  people: string;
  seconds: number;
  has_summary: number;
  has_transcript: number;
  notes: number;
}

const CALL_COLS = `num, id, folder, topic, ${PROJECT} AS profile, people, seconds, summary IS NOT NULL AS has_summary, has_transcript,
  (SELECT count(*) FROM notes WHERE notes.call_id = calls.id) AS notes`;
const clamp = (n: number, max = 200) => Math.max(1, Math.min(max, Math.floor(n) || 1));

function callLine(c: CallRow): string {
  const state = c.has_summary ? T.hasSummary : c.has_transcript ? T.hasTranscript : T.noTranscript;
  // As the engine: the id already is the date, empty parts are left out.
  const bits = [c.topic, c.profile, c.people,
                c.seconds ? formatTimestamp(c.seconds) : "", state, c.notes ? T.notesN(c.notes) : ""];
  return `- ${c.id}: ` + bits.filter(Boolean).join(" · ");
}

/** Phrase query matching the words of q in one line of a transcript or summary, by stem and in any case. */
const phrase = (q: string) => {
  const w = words(q);
  return w.length ? `"${w.join(" ")}"` : "";
};

export async function listCalls(db: D1Database, query = "", limit = 20): Promise<string> {
  await ensureSchema(db);
  const q = query.trim().toLowerCase();
  let stmt;
  if (!q) stmt = db.prepare(`SELECT ${CALL_COLS} FROM calls ORDER BY folder DESC LIMIT ?1`).bind(clamp(limit));
  else {
    const fts = phrase(q);
    stmt = db.prepare(
      `SELECT ${CALL_COLS} FROM calls WHERE instr(hay, ?2) > 0
         ${fts ? "OR num IN (SELECT call_num FROM chunks WHERE chunks MATCH ?3)" : ""}
       ORDER BY folder DESC LIMIT ?1`,
    ).bind(...[clamp(limit), q, ...(fts ? [fts] : [])]);
  }
  const { results } = await stmt.all<CallRow>();
  return results.length ? results.map(callLine).join("\n") : T.noCalls;
}

interface FullCall extends CallRow {
  summary: string | null;
  transcript: string | null;
}

async function findCall(db: D1Database, id: string): Promise<FullCall | null> {
  await ensureSchema(db);
  return db.prepare(
    `SELECT ${CALL_COLS}, summary, (SELECT text FROM transcripts t WHERE t.num = calls.num) AS transcript
     FROM calls WHERE id = ?1 OR folder = ?1 ORDER BY id = ?1 DESC LIMIT 1`,
  ).bind(id).first<FullCall>();
}

export class ToolError extends Error {}

/** "## Notes" and one "- date time · source · id: text" line per note, as the engine's notes.format_section
 *  (the id is what delete_note takes). */
export function notesSection(notes: Note[]): string {
  return [`## ${T.notes}`, ...notes.map((n) => `- ${n.at.slice(0, 16).replace("T", " ")} · ${n.source} · ${n.id}: ${n.text}`)].join("\n");
}

export async function getCall(db: D1Database, callId: string, part = "summary"): Promise<string> {
  const c = await findCall(db, callId.trim());
  if (!c) throw new ToolError(T.noCall(callId));
  const out: string[] = [];
  if (part === "summary" || part === "both") out.push(c.summary ?? T.noSummaryFile);
  if (part === "transcript" || part === "both") out.push(c.has_transcript && c.transcript ? c.transcript : T.noTranscriptFile);
  const notes = c.notes ? await notesOf(db, c.id) : [];
  if (notes.length) out.push(notesSection(notes));
  return out.join("\n\n---\n\n");
}

/** add_note: append a note to a call; the user sees it in the Sozvon app after the next sync. */
export async function addNote(db: D1Database, callId: string, text: string, source: string): Promise<string> {
  const c = await findCall(db, callId.trim());
  if (!c) throw new ToolError(T.noCall(callId));
  const body = text.trim();
  if (!body) throw new ToolError(T.noteEmpty);
  if ([...body].length > MAX_NOTE_TEXT) throw new ToolError(T.noteTooLong);
  const note: Note = { id: crypto.randomUUID(), at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"), text: body,
                       source: sourceName(source) };
  try {
    await storeNote(db, c.id, note);
  } catch (e) {
    if (e instanceof NoteLimitError) throw new ToolError(e.message);
    throw e;
  }
  return T.noteAdded(c.id);
}

/** delete_note: remove a note and leave a tombstone, so the Mac deletes it too on the next sync. */
export async function deleteNote(db: D1Database, callId: string, noteId: string): Promise<string> {
  const c = await findCall(db, callId.trim());
  if (!c) throw new ToolError(T.noCall(callId));
  const id = noteId.trim();
  if (!(await notesOf(db, c.id)).some((n) => n.id === id)) throw new ToolError(T.noNote(id));
  await dropNote(db, c.id, id);
  return T.noteDeleted(id, c.id);
}

export async function searchCalls(db: D1Database, text: string, limit = 20, also: string[] = []): Promise<string> {
  if (!text.trim()) return T.emptyQuery;
  const hits = await rankedSearch(db, text, also, clamp(limit));
  if (!hits.length) return T.nothingFound;
  return hits.map((h) => {
    const where = h.kind === "summary" ? `[${T.hasSummary}] ${h.speaker}`.trim()
      : h.kind === "note" ? `[${T.note} ${h.ts}] ${h.speaker}`.trim() : (h.ts ? `[${h.ts}] ` : "") + h.speaker;
    const about = [h.topic, h.profile].filter(Boolean).join(" · ");
    return `${h.call_id}: ` + (where.trim() ? `${where.trim()}: ` : "") + trim(h.text) + (about ? ` (${about})` : "");
  }).join("\n");
}

// --- ChatGPT connector tools (search / fetch) ---

export const callUrl = (origin: string, id: string) => `${origin}/calls/${encodeURIComponent(id)}`;

const title = (c: { id: string; topic: string; profile: string }) =>
  [c.id, c.topic, c.profile].filter(Boolean).join(" · ");

export interface SearchResult {
  id: string;
  title: string;
  url: string;
  text: string;
}

/** One result per call, best call first; text is the call's best matching line. */
export async function connectorSearch(db: D1Database, origin: string, query: string, limit = 10): Promise<{ results: SearchResult[] }> {
  if (!query.trim()) return { results: [] };
  const results: SearchResult[] = [];
  for (const h of await rankedSearch(db, query, [], 80)) {
    if (results.some((r) => r.id === h.call_id)) continue;
    const where = h.kind === "summary" ? h.speaker : h.kind === "note" ? `${T.note} (${h.speaker})`
      : [h.ts && `[${h.ts}]`, h.speaker].filter(Boolean).join(" ");
    results.push({ id: h.call_id, title: title({ id: h.call_id, topic: h.topic, profile: h.profile }),
                   url: callUrl(origin, h.call_id), text: trim((where ? `${where}: ` : "") + h.text) });
    if (results.length >= limit) break;
  }
  return { results };
}

export interface Document {
  id: string;
  title: string;
  text: string;
  url: string;
  metadata: Record<string, string>;
}

export async function connectorFetch(db: D1Database, origin: string, id: string): Promise<Document> {
  const c = await findCall(db, id.trim());
  if (!c) throw new ToolError(T.noCall(id));
  const notes = c.notes ? await notesOf(db, c.id) : [];
  const text = [`# ${T.hasSummary}`, c.summary ?? T.noSummaryFile, `# ${T.hasTranscript}`,
                c.has_transcript && c.transcript ? c.transcript : T.noTranscriptFile,
                ...(notes.length ? [`# ${T.notes}`, notesSection(notes).split("\n").slice(1).join("\n")] : [])].join("\n\n");
  const metadata: Record<string, string> = { date: c.id.slice(0, 16) }; // the id starts with "YYYY-MM-DD HH-MM"
  if (c.topic) metadata.topic = c.topic;
  if (c.profile) metadata.project = c.profile;
  if (c.people) metadata.people = c.people;
  if (c.seconds) metadata.duration = formatTimestamp(c.seconds);
  if (notes.length) metadata.notes = String(notes.length);
  return { id: c.id, title: title(c), text, url: callUrl(origin, c.id), metadata };
}
