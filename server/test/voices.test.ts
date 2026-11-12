import { beforeAll, describe, expect, it } from "vitest";
import { type Env, handleApi, MAX_VOICE_BODY, validateVoice } from "../src/api";
import { ensureSchema, putVoice } from "../src/db";
import { connectorSearch, listCalls, searchCalls } from "../src/tools";
import { localD1 } from "./d1";

const ID = "0123456789abcdef0123456789abcdef";
const emb = () => Array.from({ length: 256 }, (_, i) => (i === 0 ? 1 : 0));
const voice = (over: Record<string, unknown> = {}) => ({
  id: ID, name: "Александр Бородин", profile: "acme", me: false, embedding: emb(), seconds: 42.5,
  updated_at: "2026-01-05T10:00:00Z", ...over,
});

describe("voice validation", () => {
  it("accepts a voice print", () => {
    expect(validateVoice(ID, voice())).toMatchObject({ id: ID, name: "Александр Бородин", me: false, seconds: 42.5 });
    expect(validateVoice(ID, voice({ id: undefined, profile: undefined }))).toMatchObject({ profile: "" });
  });
  it("checks every field", () => {
    for (const [over, msg] of [
      [{ id: "f".repeat(32) }, "id"], [{ name: "" }, "name"], [{ name: "x".repeat(81) }, "name"], [{ name: 5 }, "name"],
      [{ profile: "Acme Corp" }, "profile"], [{ me: "yes" }, "me"],
      [{ embedding: emb().slice(1) }, "embedding"], [{ embedding: [...emb().slice(1), "1"] }, "embedding"],
      [{ embedding: [...emb().slice(1), null] }, "embedding"], [{ embedding: "[]" }, "embedding"],
      [{ seconds: -1 }, "seconds"], [{ seconds: 10_001 }, "seconds"], [{ seconds: "1" }, "seconds"],
      [{ updated_at: "" }, "updated_at"], [{ updated_at: "yesterday" }, "updated_at"],
    ] as const) expect(validateVoice(ID, voice(over))).toContain(msg);
    expect(validateVoice(ID, "x".repeat(80))).toContain("object");
    expect(validateVoice(ID, voice({ name: "x".repeat(80) }))).not.toBeTypeOf("string");
  });
});

describe("voices API", () => {
  let env: Env;
  beforeAll(async () => {
    env = { DB: await localD1(), OAUTH_KV: {} as KVNamespace, SOZVON_PASSWORD: "pw-long-enough-for-tests" };
  });
  const call = (method: string, path: string, opts: { auth?: string; body?: string; ip?: string } = {}) =>
    handleApi(new Request(`http://localhost${path}`, {
      method, body: opts.body,
      headers: { "CF-Connecting-IP": opts.ip ?? "2.2.2.2", ...(opts.auth === undefined ? { Authorization: "Bearer pw-long-enough-for-tests" } : opts.auth ? { Authorization: opts.auth } : {}) },
    }), env);

  it("reports version 0.4.2", async () => {
    expect(await (await call("GET", "/api/health", { auth: "" })).json()).toEqual({ ok: true, version: "0.4.2", schema: 1 });
  });
  it("needs the password", async () => {
    expect((await call("GET", "/api/voices", { auth: "Bearer nope", ip: "9.9.9.9" })).status).toBe(401);
    expect((await call("PUT", `/api/voices/${ID}`, { auth: "", body: JSON.stringify(voice()), ip: "9.9.9.8" })).status).toBe(401);
    expect((await call("DELETE", `/api/voices/${ID}`, { auth: "", ip: "9.9.9.7" })).status).toBe(401);
  });
  it("puts, lists, replaces and deletes voices with tombstones", async () => {
    expect(await (await call("GET", "/api/voices")).json()).toEqual({ voices: [] });
    expect((await call("PUT", `/api/voices/${ID}`, { body: JSON.stringify(voice()) })).status).toBe(204);
    expect(await (await call("GET", "/api/voices")).json()).toEqual({ voices: [voice()] });
    const newer = voice({ seconds: 90, updated_at: "2026-02-06T10:00:00Z", name: "Саша" });
    expect((await call("PUT", `/api/voices/${ID}`, { body: JSON.stringify(newer) })).status).toBe(204);
    expect(await (await call("GET", "/api/voices")).json()).toEqual({ voices: [newer] });

    expect((await call("DELETE", `/api/voices/${ID}`)).status).toBe(204);
    expect((await call("DELETE", `/api/voices/${ID}`)).status).toBe(204);
    const list = (await (await call("GET", "/api/voices")).json()) as { voices: Record<string, unknown>[] };
    expect(list.voices).toHaveLength(1);
    expect(list.voices[0]).toMatchObject({ id: ID, deleted: true });
    expect(Object.keys(list.voices[0]).sort()).toEqual(["deleted", "id", "updated_at"]);

    // A stale copy from another Mac can't bring it back; a change made after the deletion can.
    expect((await call("PUT", `/api/voices/${ID}`, { body: JSON.stringify(newer) })).status).toBe(410);
    const later = voice({ updated_at: "2999-01-01T00:00:00Z" });
    expect((await call("PUT", `/api/voices/${ID}`, { body: JSON.stringify(later) })).status).toBe(204);
    expect(await (await call("GET", "/api/voices")).json()).toEqual({ voices: [later] });
  });
  it("answers 409 with the stored print when a newer one with another embedding is there", async () => {
    const vid = "b".repeat(32);
    const other = Array.from({ length: 256 }, (_, i) => (i === 1 ? 1 : 0));
    const newer = voice({ id: vid, updated_at: "2026-03-01T10:00:00Z" });
    expect((await call("PUT", `/api/voices/${vid}`, { body: JSON.stringify(newer) })).status).toBe(204);
    // Another Mac enrolled the same voice a moment earlier: its PUT lands later and gets the stored print back.
    const older = voice({ id: vid, updated_at: "2026-03-01T09:59:00Z", embedding: other, seconds: 10 });
    const r = await call("PUT", `/api/voices/${vid}`, { body: JSON.stringify(older) });
    expect(r.status).toBe(409);
    expect(((await r.json()) as { voice: unknown }).voice).toEqual(newer);
    // The same embedding, older: the newer record stays and nothing fails.
    const same = voice({ id: vid, updated_at: "2026-03-01T09:00:00Z", name: "Старое имя" });
    expect((await call("PUT", `/api/voices/${vid}`, { body: JSON.stringify(same) })).status).toBe(204);
    const list = (await (await call("GET", "/api/voices")).json()) as { voices: Record<string, unknown>[] };
    expect(list.voices.find((v) => v.id === vid)).toEqual(newer);
    // The merged print, newer than both, is stored.
    const merged = voice({ id: vid, updated_at: "2026-03-01T10:01:00Z", embedding: other });
    expect((await call("PUT", `/api/voices/${vid}`, { body: JSON.stringify(merged) })).status).toBe(204);
  });
  it("rejects bad requests", async () => {
    expect((await call("PUT", "/api/voices/nope", { body: JSON.stringify(voice()) })).status).toBe(400);
    expect((await call("DELETE", `/api/voices/${ID.toUpperCase()}`)).status).toBe(400);
    expect((await call("PUT", `/api/voices/${ID}`, { body: "{" })).status).toBe(400);
    expect((await call("PUT", `/api/voices/${ID}`, { body: JSON.stringify(voice({ seconds: 1e9 })) })).status).toBe(400);
    expect((await call("PUT", `/api/voices/${ID}`, { body: "x".repeat(MAX_VOICE_BODY + 1) })).status).toBe(413);
    expect((await call("POST", "/api/voices")).status).toBe(405);
    expect((await call("GET", `/api/voices/${ID}`)).status).toBe(405);
    expect((await call("GET", `/api/voices/${ID}/x`)).status).toBe(404);
  });
  it("never shows voices to the MCP tools", async () => {
    await putVoice(env.DB, { ...voice({ id: "a".repeat(32), name: "Зинаида Уникальная" }), me: false, profile: "" } as never);
    expect(await searchCalls(env.DB, "Зинаида Уникальная")).not.toContain("Зинаида");
    expect(await listCalls(env.DB, "Зинаида")).not.toContain("Зинаида");
    expect((await connectorSearch(env.DB, "https://x", "Зинаида")).results).toEqual([]);
  });
  it("creates the voices table on an older database", async () => {
    await ensureSchema(env.DB);
    const has = await env.DB.prepare(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'voices'`).first();
    expect(has).not.toBeNull();
  });
});
