import { beforeAll, describe, expect, it } from "vitest";
import { type Env, handleApi, MAX_COMMIT_BODY } from "../src/api";
import { AUDIO_LIMIT, audioBytes, CHUNK } from "../src/audio";
import { putCall } from "../src/db";
import { getCall, searchCalls } from "../src/tools";
import { localD1 } from "./d1";

const ID = "2026-11-04 15-01";
const P = `/api/calls/${encodeURIComponent(ID)}`;
const ID2 = "2026-11-04 16-00";
const P2 = `/api/calls/${encodeURIComponent(ID2)}`;
const SHA = "a".repeat(64);
const SHA2 = "b".repeat(64);
const bytes = (n: number, v = 7) => new Uint8Array(n).fill(v);

describe("audio API", () => {
  let env: Env;
  beforeAll(async () => {
    env = { DB: await localD1(), OAUTH_KV: {} as KVNamespace, SOZVON_PASSWORD: "pw" };
    await putCall(env.DB, { schema: 1, id: ID, hash: "c".repeat(64), folder: ID, call: { id: ID }, transcript: "[00:01] A: hi", summary: null });
    await putCall(env.DB, { schema: 1, id: ID2, hash: "e".repeat(64), folder: ID2, call: { id: ID2 }, transcript: "[00:01] B: yo", summary: null });
  });
  const req = (method: string, path: string, opts: { auth?: string; body?: BodyInit; sha?: string; ip?: string } = {}) =>
    handleApi(new Request(`http://localhost${path}`, {
      method, body: opts.body,
      headers: { "CF-Connecting-IP": opts.ip ?? "3.3.3.3", ...(opts.sha ? { "X-Sozvon-Sha256": opts.sha } : {}),
                 ...(opts.auth === undefined ? { Authorization: "Bearer pw" } : opts.auth ? { Authorization: opts.auth } : {}) },
    }), env);
  const commit = (track: string, size: number, chunks: number, sha256 = SHA, extra: Record<string, unknown> = {}, path = P) =>
    req("POST", `${path}/audio/${track}/commit`, { body: JSON.stringify({ size, chunks, sha256, ...extra }) });

  it("needs the password", async () => {
    expect((await req("GET", `${P}/audio`, { auth: "", ip: "8.8.8.1" })).status).toBe(401);
    expect((await req("PUT", `${P}/audio/mic/0`, { auth: "Bearer x", body: bytes(3), sha: SHA, ip: "8.8.8.2" })).status).toBe(401);
  });

  it("uploads in chunks, resumes, commits and serves a track", async () => {
    expect(await (await req("GET", `${P}/audio`)).json()).toEqual({ tracks: [], pending: [], audio_removed_at: null });
    expect((await req("PUT", `${P}/audio/mic/0`, { body: bytes(CHUNK, 1), sha: SHA })).status).toBe(204);
    // Interrupted here: the staged chunk is listed, and committing too early is refused.
    expect(await (await req("GET", `${P}/audio`)).json()).toEqual({
      tracks: [], pending: [{ track: "mic", sha256: SHA, chunks: [{ idx: 0, size: CHUNK }] }], audio_removed_at: null });
    expect((await commit("mic", CHUNK + 10, 2)).status).toBe(409);
    expect((await req("PUT", `${P}/audio/mic/1`, { body: bytes(10, 2), sha: SHA })).status).toBe(204);
    expect((await commit("mic", CHUNK + 11, 2)).status).toBe(409);
    expect((await commit("mic", CHUNK + 10, 2)).status).toBe(204);
    const list = (await (await req("GET", `${P}/audio`)).json()) as { tracks: Record<string, unknown>[]; pending: unknown[] };
    expect(list.pending).toEqual([]);
    expect(list.tracks).toMatchObject([{ track: "mic", size: CHUNK + 10, chunks: 2, sha256: SHA, start: null }]);
    const c1 = await req("GET", `${P}/audio/mic/1`);
    expect(c1.headers.get("Content-Type")).toBe("application/octet-stream");
    expect(new Uint8Array(await c1.arrayBuffer())).toEqual(bytes(10, 2));
    expect((await (await req("GET", `${P}/audio/mic/0`)).arrayBuffer()).byteLength).toBe(CHUNK);
    expect((await req("GET", `${P}/audio/mic/2`)).status).toBe(404);
    expect(await (await req("GET", "/api/calls")).json()).toMatchObject({ calls: [{ id: ID, audio: { mic: SHA } }, { id: ID2 }] });
    expect(await audioBytes(env.DB)).toBe(CHUNK + 10);
  });

  it("replaces a version only on commit", async () => {
    expect((await req("PUT", `${P}/audio/mic/0`, { body: bytes(5, 9), sha: SHA2 })).status).toBe(204);
    // Until the new version is committed the old one is served whole.
    expect((await (await req("GET", `${P}/audio/mic/0`)).arrayBuffer()).byteLength).toBe(CHUNK);
    expect((await commit("mic", 5, 1, SHA2)).status).toBe(204);
    expect(new Uint8Array(await (await req("GET", `${P}/audio/mic/0`)).arrayBuffer())).toEqual(bytes(5, 9));
    expect((await req("GET", `${P}/audio/mic/1`)).status).toBe(404);
    expect(await audioBytes(env.DB)).toBe(5);
  });

  it("a chunk of another version drops the staged ones", async () => {
    await req("PUT", `${P}/audio/system/0`, { body: bytes(4), sha: SHA });
    await req("PUT", `${P}/audio/system/1`, { body: bytes(4), sha: SHA });
    await req("PUT", `${P}/audio/system/0`, { body: bytes(6), sha: SHA2 });
    const list = (await (await req("GET", `${P}/audio`)).json()) as { pending: unknown[] };
    expect(list.pending).toEqual([{ track: "system", sha256: SHA2, chunks: [{ idx: 0, size: 6 }] }]);
  });

  it("refuses new audio with 507 when the storage is full, text keeps working", async () => {
    await env.DB.prepare(`INSERT INTO audio_tracks (call_id, track, size, chunks, sha256, updated_at) VALUES ('2026-01-01 00-00', 'mic', ?1, 1, ?2, 'x')`)
      .bind(AUDIO_LIMIT - 100, SHA).run();
    expect((await req("PUT", `${P}/audio/system/1`, { body: bytes(200), sha: SHA2 })).status).toBe(507);
    expect((await req("PUT", `${P}/audio/system/1`, { body: bytes(50), sha: SHA2 })).status).toBe(204);
    const text = { schema: 1, id: ID, hash: "d".repeat(64), folder: ID, call: { id: ID }, transcript: "[00:01] A: hello", summary: null };
    expect((await req("PUT", P, { body: JSON.stringify(text) })).status).toBe(204);
    await env.DB.prepare(`DELETE FROM audio_tracks WHERE call_id = '2026-01-01 00-00'`).run();
  });

  it("rejects bad requests", async () => {
    expect((await req("PUT", `${P}/audio/both/0`, { body: bytes(3), sha: SHA })).status).toBe(400);
    expect((await req("PUT", `${P}/audio/mic/x`, { body: bytes(3), sha: SHA })).status).toBe(400);
    expect((await req("PUT", `${P}/audio/mic/10000`, { body: bytes(3), sha: SHA })).status).toBe(400);
    expect((await req("PUT", `${P}/audio/mic/0`, { body: bytes(3) })).status).toBe(400);
    expect((await req("PUT", `${P}/audio/mic/0`, { body: bytes(CHUNK + 1), sha: SHA })).status).toBe(413);
    expect((await req("PUT", `/api/calls/${encodeURIComponent("2026-11-09 10-00")}/audio/mic/0`, { body: bytes(3), sha: SHA })).status).toBe(404);
    expect((await req("POST", `${P}/audio/mic/commit`, { body: "{}" })).status).toBe(400);
    for (const start of [-1, 86_401, "1", true]) {
      expect((await commit("mic", 5, 1, SHA, { start })).status).toBe(400);
    }
    // The commit body is capped like a voice print's.
    expect((await req("POST", `${P}/audio/mic/commit`, { body: " ".repeat(MAX_COMMIT_BODY + 1) })).status).toBe(413);
    expect((await req("POST", `${P}/audio`)).status).toBe(405);
    expect((await req("DELETE", `${P}/audio/mic/0`)).status).toBe(405);
  });

  it("never shows audio to the MCP tools", async () => {
    expect(await getCall(env.DB, ID, "full")).not.toContain("audio_chunks");
    expect(await searchCalls(env.DB, "mic")).not.toContain(SHA);
  });

  it("keeps each track's start offset", async () => {
    await req("PUT", `${P2}/audio/mic/0`, { body: bytes(5), sha: SHA });
    expect((await commit("mic", 5, 1, SHA, { start: 0.29 }, P2)).status).toBe(204);
    await req("PUT", `${P2}/audio/system/0`, { body: bytes(6), sha: SHA2 });
    expect((await commit("system", 6, 1, SHA2, { start: 0 }, P2)).status).toBe(204);
    const list = (await (await req("GET", `${P2}/audio`)).json()) as { tracks: Record<string, unknown>[] };
    expect(list.tracks).toMatchObject([{ track: "mic", start: 0.29 }, { track: "system", start: 0 }]);
  });

  it("deleting a call's audio marks it removed: no Mac uploads it again", async () => {
    expect((await req("DELETE", `${P}/audio`)).status).toBe(204);
    const list = (await (await req("GET", `${P}/audio`)).json()) as { tracks: unknown[]; pending: unknown[]; audio_removed_at: string };
    expect(list.tracks).toEqual([]);
    expect(list.pending).toEqual([]);
    expect(Date.parse(list.audio_removed_at)).not.toBeNaN();
    // A second delete keeps the first time.
    expect((await req("DELETE", `${P}/audio`)).status).toBe(204);
    expect(((await (await req("GET", `${P}/audio`)).json()) as { audio_removed_at: string }).audio_removed_at).toBe(list.audio_removed_at);
    expect(await audioBytes(env.DB)).toBe(11); // only the other call's
    // Another Mac that still has the tracks can't bring them back.
    expect((await req("PUT", `${P}/audio/mic/0`, { body: bytes(5), sha: SHA })).status).toBe(410);
    expect((await commit("mic", 5, 1)).status).toBe(410);
    const calls = (await (await req("GET", "/api/calls")).json()) as { calls: Record<string, unknown>[] };
    expect(calls.calls.find((c) => c.id === ID)).toMatchObject({ audio_removed_at: list.audio_removed_at });
    expect(calls.calls.find((c) => c.id === ID)).not.toHaveProperty("audio");
    expect(calls.calls.find((c) => c.id === ID2)).not.toHaveProperty("audio_removed_at");
  });

  it("deletes a call's audio with the call", async () => {
    expect(await audioBytes(env.DB)).toBe(11);
    expect((await req("DELETE", P2)).status).toBe(204);
    expect(await audioBytes(env.DB)).toBe(0);
    expect((await req("PUT", `${P2}/audio/mic/0`, { body: bytes(5), sha: SHA })).status).toBe(410);
  });
});
