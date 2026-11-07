import { beforeAll, describe, expect, it } from "vitest";
import { type Env, handleApi, MAX_BODY, pathId, validatePayload } from "../src/api";
import { checkPassword, FAIL_DELAY_MS, MAX_FAILURES, safeEqual } from "../src/auth";
import { addNote, MAX_CHUNKS, mergeNotes, notesOf, putCall, TooManyLines } from "../src/db";
import { localD1 } from "./d1";

const ID = "2026-11-04 15-01";
const body = (over: Record<string, unknown> = {}) => ({
  schema: 1, id: ID, hash: "a".repeat(64), folder: `${ID} · acme`, call: { schema: 1, id: ID, topic: "launch" },
  transcript: "[00:01] Anna: hello", summary: null, ...over,
});

describe("validation", () => {
  it("accepts ids of the contract only", () => {
    expect(pathId("2026-11-04%2015-01")).toBe(ID);
    expect(pathId("2026-11-04%2015-01-2")).toBe("2026-11-04 15-01-2");
    for (const bad of ["2026-11-04", "2026-11-04%2015-01%20x", "..%2F..", "%E0%A4%A", "2026-11-04T15-01"]) expect(pathId(bad)).toBeNull();
  });
  it("checks every field", () => {
    expect(validatePayload(ID, body())).toMatchObject({ id: ID, summary: null });
    expect(validatePayload(ID, body({ summary: "# S" }))).toMatchObject({ summary: "# S" });
    for (const [over, msg] of [
      [{ schema: 2 }, "schema"], [{ id: "2026-11-04 15-02" }, "id"], [{ hash: "abc" }, "hash"], [{ hash: "A".repeat(64) }, "hash"],
      [{ folder: "" }, "folder"], [{ call: [] }, "call"], [{ transcript: 1 }, "transcript"], [{ summary: 5 }, "summary"],
      [{ project_title: 5 }, "project_title"], [{ project_title: "x".repeat(201) }, "project_title"],
    ] as const) expect(validatePayload(ID, body(over))).toContain(msg);
    expect(validatePayload(ID, [])).toContain("object");
    expect(validatePayload(ID, body({ project_title: " Acme Corp " }))).toMatchObject({ project_title: "Acme Corp" });
    expect(validatePayload(ID, body())).not.toHaveProperty("project_title");
  });
  it("compares secrets fully", async () => {
    expect(await safeEqual("secret", "secret")).toBe(true);
    expect(await safeEqual("secret", "secreT")).toBe(false);
    expect(await safeEqual("secret", "secret ")).toBe(false);
    expect(await safeEqual("", "x")).toBe(false);
  });
});

describe("sync API", () => {
  let env: Env;
  beforeAll(async () => {
    env = { DB: await localD1(), OAUTH_KV: {} as KVNamespace, SOZVON_PASSWORD: "pw" };
  });
  const call = (method: string, path: string, opts: { auth?: string; body?: string; ip?: string } = {}) =>
    handleApi(new Request(`http://localhost${path}`, {
      method, body: opts.body,
      headers: { "CF-Connecting-IP": opts.ip ?? "1.1.1.1", ...(opts.auth === undefined ? { Authorization: "Bearer pw" } : opts.auth ? { Authorization: opts.auth } : {}) },
    }), env);

  it("serves health without a password", async () => {
    const r = await call("GET", "/api/health", { auth: "" });
    expect(await r.json()).toEqual({ ok: true, version: "0.4.2", schema: 1 });
  });
  it("puts, lists and deletes calls", async () => {
    expect((await call("PUT", "/api/calls/2026-11-04%2015-01", { body: JSON.stringify(body()) })).status).toBe(204);
    const id2 = "2026-11-05 10-00-2";
    expect((await call("PUT", `/api/calls/${encodeURIComponent(id2)}`, { body: JSON.stringify(body({ id: id2, hash: "b".repeat(64) })) })).status).toBe(204);
    expect((await call("PUT", "/api/calls/2026-11-04%2015-01", { body: JSON.stringify(body({ hash: "c".repeat(64) })) })).status).toBe(204);
    const row = (id: string, hash: string, folder: string, project_title = "") =>
      ({ id, hash, folder, notes: [], notes_deleted: [], project_title });
    expect(await (await call("GET", "/api/calls")).json()).toEqual({
      calls: [row(ID, "c".repeat(64), `${ID} · acme`), row(id2, "b".repeat(64), `${ID} · acme`)], deleted: [] });
    expect((await call("DELETE", `/api/calls/${encodeURIComponent(id2)}`)).status).toBe(204);
    expect((await call("DELETE", `/api/calls/${encodeURIComponent(id2)}`)).status).toBe(204);
    expect(await (await call("GET", "/api/calls")).json()).toMatchObject({ calls: [row(ID, "c".repeat(64), `${ID} · acme`)],
                                                                         deleted: [{ id: id2 }] });
    const titled = body({ hash: "c".repeat(64), project_title: "Acme Corp" });
    expect((await call("PUT", "/api/calls/2026-11-04%2015-01", { body: JSON.stringify(titled) })).status).toBe(204);
    expect(await (await call("GET", "/api/calls")).json()).toMatchObject({
      calls: [row(ID, "c".repeat(64), `${ID} · acme`, "Acme Corp")] });
  });
  it("rejects bad requests", async () => {
    expect((await call("PUT", "/api/calls/nope", { body: "{}" })).status).toBe(400);
    expect((await call("PUT", "/api/calls/2026-11-04%2015-01", { body: "{" })).status).toBe(400);
    expect((await call("PUT", "/api/calls/2026-11-04%2015-01", { body: JSON.stringify(body({ schema: 2 })) })).status).toBe(400);
    expect((await call("PUT", "/api/calls/2026-11-04%2015-01", { body: "x".repeat(MAX_BODY + 1) })).status).toBe(413);
    expect((await call("POST", "/api/calls")).status).toBe(405);
    expect((await call("POST", "/api/calls/2026-11-04%2015-01")).status).toBe(405);
    expect((await call("GET", "/api/calls/2026-11-04%2015-01/notes")).status).toBe(405);
    expect((await call("GET", "/api/calls/2026-11-04%2015-01/other")).status).toBe(404);
    expect((await call("GET", "/api/other")).status).toBe(404);
    expect((await call("DELETE", "/api/calls/2026-11-04%2015-01/notes/bad%20id")).status).toBe(400);
    expect((await call("POST", "/api/calls/2026-11-04%2015-01/notes", { body: JSON.stringify({ notes: [{ id: "x" }] }) })).status).toBe(400);
  });
  it("needs the password", async () => {
    expect((await call("GET", "/api/calls", { auth: "" })).status).toBe(401);
    expect((await call("GET", "/api/calls", { auth: "Bearer wrong" })).status).toBe(401);
    expect((await handleApi(new Request("http://localhost/api/calls"), { ...env, SOZVON_PASSWORD: "" })).status).toBe(503);
  });
});

describe("notes over the sync API", () => {
  let env: Env;
  beforeAll(async () => {
    env = { DB: await localD1(), OAUTH_KV: {} as KVNamespace, SOZVON_PASSWORD: "pw" };
  });
  const call = (method: string, path: string, b?: unknown) =>
    handleApi(new Request(`http://localhost${path}`, {
      method, body: b === undefined ? undefined : JSON.stringify(b), headers: { Authorization: "Bearer pw" },
    }), env);
  const P = "/api/calls/2026-11-04%2015-01";
  const note = (id: string, text = `note ${id}`, at = `2026-11-04T1${id.length}:00:00Z`) => ({ id, at, text, source: "app" });
  const list = async () => ((await (await call("GET", "/api/calls")).json()) as { calls: { notes: string[]; notes_deleted: string[] }[] }).calls[0];

  it("GET of one call returns the stored payload with its notes", async () => {
    expect((await call("GET", P)).status).toBe(404);
    expect((await call("POST", `${P}/notes`, { notes: [note("a")] })).status).toBe(404); // no such call yet
    expect((await call("PUT", P, body({ summary: "# S", notes: [note("a")], call: { schema: 1, id: ID, notes: ["junk"] } }))).status).toBe(204);
    const stored = await (await call("GET", P)).json();
    expect(stored).toEqual({ schema: 1, id: ID, hash: "a".repeat(64), folder: `${ID} · acme`, call: { schema: 1, id: ID },
                             transcript: "[00:01] Anna: hello", summary: "# S", notes: [note("a")], notes_deleted: [],
                             project_title: "" });
  });
  it("PUT merges notes and never drops the ones it has", async () => {
    expect((await call("PUT", P, body({ notes: [note("bb")] }))).status).toBe(204);
    expect((await list()).notes).toEqual(["a", "bb"]);
    expect((await call("PUT", P, body())).status).toBe(204); // an old client without notes
    expect((await list()).notes).toEqual(["a", "bb"]);
    expect((await call("PUT", P, body({ notes: [{ ...note("a"), text: "edited" }] }))).status).toBe(204);
    expect(((await (await call("GET", P)).json()) as { notes: { text: string }[] }).notes[0].text).toBe("note a"); // append-only
  });
  it("tombstones keep deleted notes from coming back", async () => {
    expect((await call("DELETE", `${P}/notes/a`)).status).toBe(204);
    expect(await list()).toMatchObject({ notes: ["bb"], notes_deleted: ["a"] });
    expect((await call("PUT", P, body({ notes: [note("a"), note("bb")] }))).status).toBe(204); // a stale client
    expect((await call("POST", `${P}/notes`, { notes: [note("a"), note("ccc")] })).status).toBe(204);
    expect(await list()).toMatchObject({ notes: ["bb", "ccc"], notes_deleted: ["a"] });
    expect((await call("PUT", P, body({ notes_deleted: ["bb"] }))).status).toBe(204);
    expect(await list()).toMatchObject({ notes: ["ccc"], notes_deleted: ["a", "bb"] });
    expect(((await (await call("GET", P)).json()) as { notes_deleted: string[] }).notes_deleted).toEqual(["a", "bb"]);
  });
  it("validates notes", () => {
    expect(validatePayload(ID, body({ notes: [note("ok")] }))).toMatchObject({ notes: [note("ok")] });
    for (const bad of [{ notes: "x" }, { notes: [{ ...note("a"), id: "a b" }] }, { notes: [{ ...note("a"), text: " " }] },
                       { notes: [{ ...note("a"), text: "я".repeat(4001) }] }, { notes: [{ ...note("a"), at: "" }] },
                       { notes_deleted: ["a/b"] }, { notes_deleted: "a" }]) {
      expect(typeof validatePayload(ID, body(bad))).toBe("string");
    }
    expect(validatePayload(ID, body({ notes: [{ ...note("a"), text: "я".repeat(4000) }] }))).not.toBeTypeOf("string");
    expect(validatePayload(ID, body({ notes: [{ ...note("a"), source: 5 }] }))).toMatchObject({ notes: [{ source: "assistant" }] });
  });
  it("keeps at most 200 notes per call", async () => {
    const many = Array.from({ length: 205 }, (_, i) => note(`n${i}`, "x", `2026-11-05T00:00:${String(i % 60).padStart(2, "0")}Z`));
    expect((await call("POST", `${P}/notes`, { notes: many })).status).toBe(204);
    expect((await list()).notes.length).toBe(200);
  });
  it("deleting the call deletes its notes", async () => {
    expect((await call("DELETE", P)).status).toBe(204);
    expect(await (await call("GET", "/api/calls")).json()).toMatchObject({ calls: [], deleted: [{ id: ID }] });
    expect((await call("PUT", P, body({ restore: true }))).status).toBe(204);
    expect(await list()).toMatchObject({ notes: [], notes_deleted: [] });
  });
});

describe("call tombstones", () => {
  let env: Env;
  beforeAll(async () => {
    env = { DB: await localD1(), OAUTH_KV: {} as KVNamespace, SOZVON_PASSWORD: "pw" };
  });
  const call = (method: string, path: string, b?: unknown) =>
    handleApi(new Request(`http://localhost${path}`, {
      method, body: b === undefined ? undefined : JSON.stringify(b), headers: { Authorization: "Bearer pw" },
    }), env);
  const P = "/api/calls/2026-11-04%2015-01";
  const note = { id: "n1", at: "2026-11-04T12:00:00Z", text: "x", source: "app" };
  const list = async () => (await (await call("GET", "/api/calls")).json()) as
    { calls: { id: string }[]; deleted: { id: string; at: string }[] };

  it("DELETE leaves a tombstone with the time", async () => {
    expect((await call("PUT", P, body())).status).toBe(204);
    const before = Date.now();
    expect((await call("DELETE", P)).status).toBe(204);
    const l = await list();
    expect(l.calls).toEqual([]);
    expect(l.deleted.map((d) => d.id)).toEqual([ID]);
    expect(Date.parse(l.deleted[0].at)).toBeGreaterThanOrEqual(before - 1000);
    expect((await call("GET", P)).status).toBe(404);
  });
  it("a stale copy gets 410 Gone, its notes too", async () => {
    const r = await call("PUT", P, body());
    expect(r.status).toBe(410);
    expect(((await r.json()) as { error: string }).error).toContain("restore");
    expect((await call("PUT", P, body({ restore: "yes" }))).status).toBe(410);
    expect((await call("POST", `${P}/notes`, { notes: [note] })).status).toBe(410);
    expect((await call("DELETE", `${P}/notes/n1`)).status).toBe(410);
    expect((await list()).calls).toEqual([]);
  });
  it("a bad body is still 400, not 410", async () => {
    expect((await call("PUT", P, body({ schema: 2 }))).status).toBe(400);
  });
  it("restore: true clears the tombstone and stores the call", async () => {
    expect((await call("PUT", P, body({ restore: true, notes: [note] }))).status).toBe(204);
    const l = await list();
    expect(l.deleted).toEqual([]);
    expect(l.calls.map((c) => c.id)).toEqual([ID]);
    expect(((await (await call("GET", P)).json()) as Record<string, unknown>).restore).toBeUndefined();
    expect((await call("PUT", P, body({ hash: "d".repeat(64) }))).status).toBe(204); // an ordinary update again
    expect((await call("POST", `${P}/notes`, { notes: [{ ...note, id: "n2" }] })).status).toBe(204);
  });
  it("deleting again updates the tombstone", async () => {
    expect((await call("DELETE", P)).status).toBe(204);
    expect((await call("DELETE", P)).status).toBe(204);
    expect((await list()).deleted.map((d) => d.id)).toEqual([ID]);
  });
});

describe("password attempts", () => {
  it("slows down wrong attempts and locks an IP out after too many", async () => {
    const db = await localD1();
    const req = (ip: string) => new Request("http://localhost/", { headers: { "CF-Connecting-IP": ip } });
    const t = Date.now();
    expect(await checkPassword(db, req("9.9.9.9"), "pw", "bad")).toBe("wrong");
    expect(Date.now() - t).toBeGreaterThanOrEqual(FAIL_DELAY_MS - 50);
    const now = 1_000_000;
    for (let i = 0; i < MAX_FAILURES; i++) await db.prepare("INSERT OR REPLACE INTO auth_failures VALUES ('8.8.8.8', ?1, ?2)").bind(i + 1, now).run();
    expect(await checkPassword(db, req("8.8.8.8"), "pw", "pw", now + 1000)).toBe("locked");
    expect(await checkPassword(db, req("7.7.7.7"), "pw", "pw", now + 1000)).toBe("ok"); // other IPs are not affected
    expect(await checkPassword(db, req("8.8.8.8"), "pw", "pw", now + 16 * 60 * 1000)).toBe("ok"); // the window passed
    expect(await checkPassword(db, req("8.8.8.8"), undefined, "pw")).toBe("unset");
  });
});


describe("review fixes", () => {
  it("answers an unexpected error with JSON 500, not Cloudflare's HTML page", async () => {
    const broken = { prepare() { throw new Error("D1 is down"); }, batch() { throw new Error("D1 is down"); } } as unknown as D1Database;
    const r = await handleApi(new Request("http://localhost/api/calls", { headers: { Authorization: "Bearer pw" } }),
                              { DB: broken, OAUTH_KV: {} as KVNamespace, SOZVON_PASSWORD: "pw" });
    expect(r.status).toBe(500);
    expect(await r.json()).toEqual({ error: "server error: D1 is down" });
  });
  it("cleans old password failures and never counts a correct password", async () => {
    const db = await localD1();
    const req = (ip: string) => new Request("http://localhost/", { headers: { "CF-Connecting-IP": ip } });
    const now = 5_000_000;
    await checkPassword(db, req("1.0.0.1"), "pw", "pw", now); // creates the schema
    await db.prepare("INSERT INTO auth_failures VALUES ('1.0.0.2', 3, ?1)").bind(now - 20 * 60 * 1000).run(); // window over
    await db.prepare("INSERT INTO auth_failures VALUES ('1.0.0.3', 3, ?1)").bind(now - 60 * 1000).run(); // still fresh
    expect(await checkPassword(db, req("1.0.0.4"), "pw", "pw", now)).toBe("ok");
    expect(await checkPassword(db, req("1.0.0.4"), "pw", "bad", now)).toBe("wrong");
    const { results } = await db.prepare("SELECT ip, n FROM auth_failures ORDER BY ip").all<{ ip: string; n: number }>();
    expect(results).toEqual([{ ip: "1.0.0.3", n: 3 }, { ip: "1.0.0.4", n: 1 }]);
  });
  it("keeps the newest 200 notes when two Macs together have more, and add_note never pushes one out", async () => {
    const db = await localD1();
    const P = { schema: 1 as const, id: ID, hash: "a".repeat(64), folder: ID, call: {}, transcript: "", summary: null };
    const at = (i: number) => `2026-11-05T${String(Math.floor(i / 60)).padStart(2, "0")}:${String(i % 60).padStart(2, "0")}:00Z`;
    const n = (i: number) => ({ id: `n${String(i).padStart(3, "0")}`, at: at(i), text: "x", source: "app" });
    await putCall(db, { ...P, notes: Array.from({ length: 150 }, (_, i) => n(i + 80)) }); // n080..n229
    expect(await mergeNotes(db, ID, Array.from({ length: 80 }, (_, i) => n(i)), [])).toBe(true); // older ones: n000..n079
    let ids = (await notesOf(db, ID)).map((x) => x.id);
    expect(ids.length).toBe(200);
    expect(ids[0]).toBe("n030");
    expect(ids.at(-1)).toBe("n229");
    expect(await mergeNotes(db, ID, [n(5)], [])).toBe(true); // too old: a no-op, nothing written
    expect((await notesOf(db, ID)).map((x) => x.id)).toEqual(ids);
    await expect(addNote(db, ID, n(300))).rejects.toThrow("200");
    await putCall(db, { ...P, notes: [n(300)] }); // a sync: the newest note goes in, the oldest out
    ids = (await notesOf(db, ID)).map((x) => x.id);
    expect(ids.length).toBe(200);
    expect(ids[0]).toBe("n031");
    expect(ids.at(-1)).toBe("n300");
  });
});

describe("too many lines", () => {
  it("putCall refuses more lines than a call's rowid range holds", async () => {
    const db = await localD1();
    const transcript = "a\n".repeat(MAX_CHUNKS);
    await expect(putCall(db, { schema: 1, id: ID, hash: "a".repeat(64), folder: ID, call: {}, transcript, summary: null }))
      .rejects.toBeInstanceOf(TooManyLines);
  });
  it("any other RangeError is a 500, not a 413 about lines", async () => {
    const real = await localD1();
    const db = new Proxy(real, {
      get(t, prop) {
        if (prop === "prepare") {
          return (sql: string) => {
            if (sql.includes("INSERT INTO calls")) throw new RangeError("Invalid string length");
            return t.prepare(sql);
          };
        }
        const v = Reflect.get(t, prop);
        return typeof v === "function" ? v.bind(t) : v;
      },
    });
    const r = await handleApi(new Request("http://localhost/api/calls/2026-11-04%2015-01", {
      method: "PUT", body: JSON.stringify(body()), headers: { Authorization: "Bearer pw" } }),
      { DB: db, OAUTH_KV: {} as KVNamespace, SOZVON_PASSWORD: "pw" });
    expect(r.status).toBe(500);
    expect(await r.json()).toEqual({ error: "server error: Invalid string length" });
  });
});
