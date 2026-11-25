// A trimmed call wins everywhere: the server stores the trim time and refuses text and audio from older copies.
import { beforeAll, describe, expect, it } from "vitest";
import { type Env, handleApi } from "../src/api";

const ID = "2026-11-04 15-01";
const P = `/api/calls/${encodeURIComponent(ID)}`;
const SHA = "a".repeat(64);
const T1 = "2026-11-05T10:00:00Z";
const T2 = "2026-11-05T11:00:00Z";
const T2_MS = "2026-11-05T11:00:00.000Z"; // what the server holds after the milliseconds case above
const trimmed = (at: string) => ({ at, head: 12, tail: 30 });
const body = (call: Record<string, unknown> = {}, over: Record<string, unknown> = {}) => ({
  schema: 1, id: ID, hash: "a".repeat(64), folder: ID, call: { schema: 1, id: ID, topic: "t", ...call },
  transcript: "[00:01] Anna: hello", summary: null, ...over,
});

describe("trim sync", () => {
  let env: Env;
  beforeAll(async () => {
    const { localD1 } = await import("./d1");
    env = { DB: await localD1(), OAUTH_KV: {} as KVNamespace, SOZVON_PASSWORD: "pw-long-enough-for-tests" };
  });
  const req = (method: string, path: string, opts: { body?: BodyInit; trimmedAt?: string } = {}) =>
    handleApi(new Request(`http://localhost${path}`, {
      method, body: opts.body,
      headers: { "CF-Connecting-IP": "5.5.5.5", Authorization: "Bearer pw-long-enough-for-tests",
                 ...(opts.trimmedAt !== undefined ? { "X-Sozvon-Trimmed-At": opts.trimmedAt } : {}),
                 "X-Sozvon-Sha256": SHA },
    }), env);
  const put = (b: unknown) => req("PUT", P, { body: JSON.stringify(b) });
  const list = async () => ((await (await req("GET", "/api/calls")).json()) as { calls: Record<string, unknown>[] }).calls
    .find((c) => c.id === ID)!;

  it("old clients without the field still sync untrimmed calls", async () => {
    expect((await put(body())).status).toBe(204);
    expect((await put(body({}, { hash: "b".repeat(64) }))).status).toBe(204);
    expect(await list()).not.toHaveProperty("trimmed_at");
    expect((await req("PUT", `${P}/audio/mic/0`, { body: new Uint8Array(5), trimmedAt: "" })).status).toBe(204);
    expect((await req("POST", `${P}/audio/mic/commit`, { body: JSON.stringify({ size: 5, chunks: 1, sha256: SHA }) })).status).toBe(204);
  });

  it("accepts a newer trim and lists it", async () => {
    expect((await put(body({ trimmed: trimmed(T1) }))).status).toBe(204);
    expect(await list()).toMatchObject({ trimmed_at: T1 });
    expect((await put(body({ trimmed: trimmed(T2) }))).status).toBe(204);
    expect(await list()).toMatchObject({ trimmed_at: T2 });
    // The whole trimmed object comes back with the call.
    const got = (await (await req("GET", P)).json()) as { call: { trimmed: unknown } };
    expect(got.call.trimmed).toEqual(trimmed(T2));
    // The same trim again is not older: accepted.
    expect((await put(body({ trimmed: trimmed(T2) }))).status).toBe(204);
  });

  it("refuses a call upload without the trim once stored (409 trimmed)", async () => {
    const r = await put(body());
    expect(r.status).toBe(409);
    expect(await r.json()).toEqual({ error: "trimmed", trimmed_at: T2 });
    expect(await list()).toMatchObject({ trimmed_at: T2 });
  });

  it("refuses an older trim", async () => {
    const r = await put(body({ trimmed: trimmed(T1) }));
    expect(r.status).toBe(409);
    expect(await r.json()).toEqual({ error: "trimmed", trimmed_at: T2 });
    // Times are compared as times: the same instant with milliseconds is not older.
    expect((await put(body({ trimmed: trimmed("2026-11-05T11:00:00.000Z") }))).status).toBe(204);
    expect((await put(body({ trimmed: trimmed("2026-11-05T10:59:59.999Z") }))).status).toBe(409);
  });

  it("rejects a malformed trimmed field", async () => {
    expect((await put(body({ trimmed: { at: "yesterday" } }))).status).toBe(400);
    expect((await put(body({ trimmed: "x" }))).status).toBe(400);
  });

  it("refuses audio chunks with an older X-Sozvon-Trimmed-At", async () => {
    for (const at of [T1, ""]) {
      const r = await req("PUT", `${P}/audio/mic/0`, { body: new Uint8Array(5), trimmedAt: at });
      expect(r.status).toBe(409);
      expect(await r.json()).toEqual({ error: "trimmed", trimmed_at: T2_MS });
      const c = await req("POST", `${P}/audio/mic/commit`, { body: JSON.stringify({ size: 5, chunks: 1, sha256: SHA }), trimmedAt: at });
      expect(c.status).toBe(409);
      expect(await c.json()).toEqual({ error: "trimmed", trimmed_at: T2_MS });
    }
    expect((await req("PUT", `${P}/audio/mic/0`, { body: new Uint8Array(5), trimmedAt: T2 })).status).toBe(204);
    expect((await req("POST", `${P}/audio/mic/commit`, { body: JSON.stringify({ size: 5, chunks: 1, sha256: SHA }), trimmedAt: T2 })).status).toBe(204);
  });

  it("deleting the call forgets its trim", async () => {
    expect((await req("DELETE", P)).status).toBe(204);
    expect((await req("PUT", P, { body: JSON.stringify({ ...body(), restore: true }) })).status).toBe(204);
    expect(await list()).not.toHaveProperty("trimmed_at");
  });
});
