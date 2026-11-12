// Sync API for the Sozvon app (docs/SERVER.md, "Sync protocol").
import type { OAuthHelpers } from "@cloudflare/workers-oauth-provider";
import { audioLimit, CHUNK, commitTrack, getChunk, isAudioRemoved, isTrack, listAudio, MAX_CHUNK_INDEX, MAX_START, putChunk,
         removeAudio, SHA_RE, StorageFull } from "./audio";
import { bearer, checkPassword, passwordProblem } from "./auth";
import { callExists, type CallPayload, callTombstones, deleteCall, deleteNote, deleteVoice, getStored, isTombstoned, listHashes, listVoices, MAX_CHUNKS,
         MAX_NOTES, mergeNotes, type Note, NOTE_ID_RE, putCall, putVoice, SCHEMA, TooManyLines, validNote, type Voice,
         VOICE_DIM, VOICE_ID_RE } from "./db";

export const VERSION = "0.4.2";
export const MAX_VOICE_BODY = 64_000; // bytes; a voice print is about 6 KB
export const MAX_COMMIT_BODY = 64_000; // bytes; an audio commit is under 200
export const MAX_BODY = 2_000_000; // bytes; D1 caps a row at 2 MB too
export const ID_RE = /^\d{4}-\d{2}-\d{2} \d{2}-\d{2}(-\d+)?$/;
const HASH_RE = /^[0-9a-f]{64}$/;

export interface Env {
  DB: D1Database;
  OAUTH_KV: KVNamespace;
  SOZVON_PASSWORD?: string;
  SOZVON_AUDIO_LIMIT_MB?: string; // optional: megabytes of audio to keep instead of AUDIO_LIMIT (audio.ts)
  OAUTH_PROVIDER?: OAuthHelpers; // set by the OAuth provider for the sign-in page
}

const json = (body: unknown, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
const error = (status: number, message: string) => json({ error: message }, status);
const GONE = "the call was deleted; PUT it with \"restore\": true to bring it back";
const AUDIO_GONE = "the call's audio was removed; it is not stored on the server again";

/** A valid payload, or the reason it is not. */
export function validatePayload(id: string, body: unknown): CallPayload | string {
  if (!body || typeof body !== "object" || Array.isArray(body)) return "body must be a JSON object";
  const b = body as Record<string, unknown>;
  if (b.schema !== SCHEMA) return `schema must be ${SCHEMA}`;
  if (b.id !== id) return "id in the body does not match the path";
  if (typeof b.hash !== "string" || !HASH_RE.test(b.hash)) return "hash must be 64 lowercase hex characters";
  if (typeof b.folder !== "string" || !b.folder.trim() || b.folder.length > 255)
    return "folder must be a non-empty string of at most 255 characters";
  if (!b.call || typeof b.call !== "object" || Array.isArray(b.call)) return "call must be an object";
  if (typeof b.transcript !== "string") return "transcript must be a string";
  if (b.summary !== null && typeof b.summary !== "string") return "summary must be a string or null";
  if (b.project_title !== undefined && (typeof b.project_title !== "string" || b.project_title.length > 200))
    return "project_title must be a string of at most 200 characters";
  const notes = validateNotes(b);
  if (typeof notes === "string") return notes;
  return { schema: SCHEMA, id, hash: b.hash, folder: b.folder, call: b.call as Record<string, unknown>,
           transcript: b.transcript, summary: b.summary as string | null, ...notes,
           ...(typeof b.project_title === "string" ? { project_title: b.project_title.trim() } : {}) };
}

/** The optional "notes" and "notes_deleted" fields of a PUT or POST body, or the reason they are invalid. */
export function validateNotes(b: Record<string, unknown>): { notes?: Note[]; notes_deleted?: string[] } | string {
  const out: { notes?: Note[]; notes_deleted?: string[] } = {};
  if (b.notes !== undefined) {
    if (!Array.isArray(b.notes) || b.notes.length > MAX_NOTES * 5) return "notes must be a list of notes";
    const notes: Note[] = [];
    for (const v of b.notes) {
      const n = validNote(v);
      if (typeof n === "string") return n;
      notes.push(n);
    }
    out.notes = notes;
  }
  if (b.notes_deleted !== undefined) {
    if (!Array.isArray(b.notes_deleted) || b.notes_deleted.length > 10_000 ||
        !b.notes_deleted.every((i) => typeof i === "string" && NOTE_ID_RE.test(i))) return "notes_deleted must be a list of note ids";
    out.notes_deleted = b.notes_deleted as string[];
  }
  return out;
}

const PROFILE_RE = /^[a-z0-9_-]{0,64}$/;

/** A valid voice print for PUT /api/voices/{id}, or the reason it is not. */
export function validateVoice(id: string, body: unknown): Voice | string {
  if (!body || typeof body !== "object" || Array.isArray(body)) return "body must be a JSON object";
  const b = body as Record<string, unknown>;
  if (b.id !== undefined && b.id !== id) return "id in the body does not match the path";
  if (typeof b.name !== "string" || !b.name.trim() || [...b.name.trim()].length > 80) return "name must be 1 to 80 characters";
  const profile = b.profile ?? "";
  if (typeof profile !== "string" || !PROFILE_RE.test(profile)) return "profile must be a project slug or empty";
  if (b.me !== undefined && typeof b.me !== "boolean") return "me must be a boolean";
  if (!Array.isArray(b.embedding) || b.embedding.length !== VOICE_DIM ||
      !b.embedding.every((x) => typeof x === "number" && Number.isFinite(x))) return `embedding must be ${VOICE_DIM} finite numbers`;
  if (typeof b.seconds !== "number" || !Number.isFinite(b.seconds) || b.seconds < 0 || b.seconds > 10_000)
    return "seconds must be a number from 0 to 10000";
  if (typeof b.updated_at !== "string" || !b.updated_at.trim() || b.updated_at.length > 40 || Number.isNaN(Date.parse(b.updated_at)))
    return "updated_at must be an ISO 8601 time";
  return { id, name: b.name.trim(), profile, me: b.me === true, embedding: b.embedding as number[], seconds: b.seconds,
           updated_at: b.updated_at };
}

/** The call id from /api/calls/{id}, or null when it is not a valid id. */
export function pathId(segment: string): string | null {
  let id: string;
  try {
    id = decodeURIComponent(segment);
  } catch {
    return null;
  }
  return ID_RE.test(id) ? id : null;
}

/** The parsed JSON body, or the 413 or 400 answer when it is larger than limit bytes (declared or actual) or not JSON. */
async function readJson(request: Request, limit: number): Promise<{ body: unknown } | Response> {
  const declared = Number(request.headers.get("Content-Length") ?? "0");
  if (declared > limit) return error(413, `body is larger than ${limit} bytes`);
  const buf = await request.arrayBuffer();
  if (buf.byteLength > limit) return error(413, `body is larger than ${limit} bytes`);
  try {
    return { body: JSON.parse(new TextDecoder().decode(buf)) as unknown };
  } catch {
    return error(400, "body is not valid JSON");
  }
}

/** The error answer for a request without the right password, or null when it has it. */
async function authError(request: Request, env: Env): Promise<Response | null> {
  const problem = passwordProblem(env.SOZVON_PASSWORD);
  if (problem) return error(503, problem);
  // No bearer token is not an attempt: it is not counted and not slowed down. A page on another site can make the
  // owner's browser send such requests (it can't add an Authorization header), and they must not lock the owner out.
  const attempt = bearer(request);
  if (!attempt) return error(401, "password required");
  const auth = await checkPassword(env.DB, request, env.SOZVON_PASSWORD, attempt);
  if (auth === "unset") return error(503, "SOZVON_PASSWORD is not set on the server");
  if (auth === "locked") return error(429, "too many wrong passwords, try again in 15 minutes");
  if (auth !== "ok") return error(401, "wrong password");
  return null;
}

/** The sync API. Any unexpected error is a JSON 500 (the app shows it), never Cloudflare's HTML error page. */
export async function handleApi(request: Request, env: Env): Promise<Response> {
  try {
    return await routeApi(request, env);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return error(500, `server error: ${message.slice(0, 300)}`);
  }
}

async function routeApi(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  if (pathname === "/api/health" && request.method === "GET") return json({ ok: true, version: VERSION, schema: SCHEMA });

  if (pathname === "/api/voices" || pathname.startsWith("/api/voices/")) return routeVoices(request, env, pathname);

  // /api/calls, /api/calls/{id}, /api/calls/{id}/notes, /api/calls/{id}/notes/{note id}
  const parts = pathname === "/api/calls" ? [] : pathname.startsWith("/api/calls/") ? pathname.slice("/api/calls/".length).split("/") : null;
  if (!parts) return error(404, "not found");
  const route = parts.length === 0 ? "list" : parts.length === 1 ? "call"
    : parts.length === 2 && parts[1] === "notes" ? "notes" : parts.length === 3 && parts[1] === "notes" ? "note"
    : parts.length === 2 && parts[1] === "audio" ? "audio"
    : parts.length === 4 && parts[1] === "audio" && parts[3] === "commit" ? "commit"
    : parts.length === 4 && parts[1] === "audio" ? "chunk" : null;
  if (!route) return error(404, "not found");
  const allowed = { list: ["GET"], call: ["GET", "PUT", "DELETE"], notes: ["POST"], note: ["DELETE"], audio: ["GET", "DELETE"],
                    commit: ["POST"], chunk: ["GET", "PUT"] }[route];
  if (!allowed.includes(request.method)) return error(405, "method not allowed");

  const denied = await authError(request, env);
  if (denied) return denied;

  if (route === "list") return json({ calls: await listHashes(env.DB), deleted: await callTombstones(env.DB) });

  const id = pathId(parts[0]);
  if (!id) return error(400, "invalid call id");
  if (route === "note") {
    let noteId: string;
    try {
      noteId = decodeURIComponent(parts[2]);
    } catch {
      return error(400, "invalid note id");
    }
    if (!NOTE_ID_RE.test(noteId)) return error(400, "invalid note id");
    if (await isTombstoned(env.DB, id)) return error(410, GONE);
    await deleteNote(env.DB, id, noteId);
    return new Response(null, { status: 204 });
  }
  if (route === "audio" || route === "commit" || route === "chunk") return routeAudio(request, env, id, route, parts);
  if (route === "call" && request.method === "GET") {
    const stored = await getStored(env.DB, id);
    return stored ? json(stored) : error(404, "unknown call");
  }
  if (route === "call" && request.method === "DELETE") {
    await deleteCall(env.DB, id);
    return new Response(null, { status: 204 });
  }
  const read = await readJson(request, MAX_BODY);
  if (read instanceof Response) return read;
  const { body } = read;
  if (route === "notes") {
    if (!body || typeof body !== "object" || Array.isArray(body)) return error(400, "body must be a JSON object");
    const notes = validateNotes(body as Record<string, unknown>);
    if (typeof notes === "string") return error(400, notes);
    if (await isTombstoned(env.DB, id)) return error(410, GONE);
    const found = await mergeNotes(env.DB, id, notes.notes ?? [], notes.notes_deleted ?? []);
    return found ? new Response(null, { status: 204 }) : error(404, "unknown call");
  }
  const payload = validatePayload(id, body);
  if (typeof payload === "string") return error(400, payload);
  // A deleted call comes back only when the user restored it on purpose ("restore": true).
  const restore = (body as Record<string, unknown>).restore === true;
  if (!restore && (await isTombstoned(env.DB, id))) return error(410, GONE);
  try {
    await putCall(env.DB, payload, restore);
  } catch (e) {
    if (e instanceof TooManyLines) return error(413, `more than ${MAX_CHUNKS - 1} lines`);
    throw e;
  }
  return new Response(null, { status: 204 });
}

/** /api/voices and /api/voices/{id}: voice prints, for the Sozvon app only (same password and lockout as calls). */
async function routeVoices(request: Request, env: Env, pathname: string): Promise<Response> {
  const rest = pathname === "/api/voices" ? null : pathname.slice("/api/voices/".length);
  if (rest !== null && (!rest || rest.includes("/"))) return error(404, "not found");
  const allowed = rest === null ? ["GET"] : ["PUT", "DELETE"];
  if (!allowed.includes(request.method)) return error(405, "method not allowed");

  const denied = await authError(request, env);
  if (denied) return denied;

  if (rest === null) return json({ voices: await listVoices(env.DB) });
  if (!VOICE_ID_RE.test(rest)) return error(400, "invalid voice id");
  if (request.method === "DELETE") {
    await deleteVoice(env.DB, rest);
    return new Response(null, { status: 204 });
  }
  const read = await readJson(request, MAX_VOICE_BODY);
  if (read instanceof Response) return read;
  const voice = validateVoice(rest, read.body);
  if (typeof voice === "string") return error(400, voice);
  const put = await putVoice(env.DB, voice);
  if (put.status === "gone") return error(410, "the voice was deleted later than this change");
  // Changed elsewhere after this version and with another print: the client merges the two and sends the result.
  if (put.status === "conflict") return json({ error: "the voice was changed later than this change", voice: put.stored }, 409);
  return new Response(null, { status: 204 });
}

/** Call audio: /api/calls/{id}/audio, .../audio/{track}/commit, .../audio/{track}/{idx}. */
async function routeAudio(request: Request, env: Env, id: string, route: "audio" | "commit" | "chunk",
                          parts: string[]): Promise<Response> {
  if (route === "audio") {
    if (request.method === "DELETE") {
      await removeAudio(env.DB, id);
      return new Response(null, { status: 204 });
    }
    return json(await listAudio(env.DB, id));
  }
  const track = parts[2];
  if (!isTrack(track)) return error(400, "track must be mic or system");
  if (route === "commit") {
    const read = await readJson(request, MAX_COMMIT_BODY);
    if (read instanceof Response) return read;
    const b = (read.body && typeof read.body === "object" ? read.body : {}) as Record<string, unknown>;
    if (!Number.isInteger(b.size) || (b.size as number) < 0 || !Number.isInteger(b.chunks) || (b.chunks as number) < 1 ||
        (b.chunks as number) > MAX_CHUNK_INDEX + 1 || typeof b.sha256 !== "string" || !SHA_RE.test(b.sha256)) {
      return error(400, "commit needs size, chunks and sha256");
    }
    const start = b.start ?? null;
    if (start !== null && (typeof start !== "number" || !Number.isFinite(start) || start < 0 || start > MAX_START)) {
      return error(400, `start must be a number of seconds from 0 to ${MAX_START}`);
    }
    if (await isTombstoned(env.DB, id)) return error(410, GONE);
    if (await isAudioRemoved(env.DB, id)) return error(410, AUDIO_GONE);
    const why = await commitTrack(env.DB, id, track, { size: b.size as number, chunks: b.chunks as number, sha256: b.sha256,
                                                       start: start as number | null });
    return why ? error(409, why) : new Response(null, { status: 204 });
  }
  const idx = /^\d{1,4}$/.test(parts[3]) ? Number(parts[3]) : -1;
  if (idx < 0 || idx > MAX_CHUNK_INDEX) return error(400, "invalid chunk index");
  if (request.method === "GET") {
    const data = await getChunk(env.DB, id, track, idx);
    return data ? new Response(data, { headers: { "Content-Type": "application/octet-stream", "Cache-Control": "no-store" } })
      : error(404, "no such chunk");
  }
  const sha = request.headers.get("X-Sozvon-Sha256") ?? "";
  if (!SHA_RE.test(sha)) return error(400, "X-Sozvon-Sha256 must be the sha256 of the whole track");
  if (Number(request.headers.get("Content-Length") ?? "0") > CHUNK) return error(413, `a chunk is at most ${CHUNK} bytes`);
  const data = await request.arrayBuffer();
  if (data.byteLength > CHUNK) return error(413, `a chunk is at most ${CHUNK} bytes`);
  if (!data.byteLength) return error(400, "empty chunk");
  if (await isTombstoned(env.DB, id)) return error(410, GONE);
  if (await isAudioRemoved(env.DB, id)) return error(410, AUDIO_GONE);
  if (!(await callExists(env.DB, id))) return error(404, "unknown call");
  const limit = audioLimit(env);
  try {
    await putChunk(env.DB, id, track, idx, sha, data, Date.now(), limit);
  } catch (e) {
    if (e instanceof StorageFull) return error(507, `the storage for audio is full (${limit} bytes)`);
    throw e;
  }
  return new Response(null, { status: 204 });
}
