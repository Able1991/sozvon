// D1 rows written by a PUT (the free plan allows 100,000 a day): chunks is an FTS5 table, so every line
// costs several rows in its shadow tables. A PUT that changes only metadata must not rewrite them.
import { beforeAll, describe, expect, it } from "vitest";
import { addNote, deleteNote, mergeNotes, notesOf, putCall } from "../src/db";
import { localD1 } from "./d1";

let db: D1Database;
let written = 0;

/** The database, counting meta.rows_written of everything it runs. */
function counting(real: D1Database): D1Database {
  const wrap = (stmt: D1PreparedStatement): D1PreparedStatement => new Proxy(stmt, {
    get(t, prop) {
      if (prop === "bind") return (...a: unknown[]) => wrap(t.bind(...a));
      if (prop === "run" || prop === "all" || prop === "first") {
        return async (...a: unknown[]) => {
          if (prop === "first") return (t.first as (...x: unknown[]) => unknown)(...a);
          const r = await (t[prop] as (...x: unknown[]) => Promise<D1Result>)(...a);
          written += r.meta.rows_written ?? 0;
          return r;
        };
      }
      const v = Reflect.get(t, prop);
      return typeof v === "function" ? v.bind(t) : v;
    },
  });
  return new Proxy(real, {
    get(t, prop) {
      if (prop === "prepare") return (sql: string) => wrap(t.prepare(sql));
      if (prop === "batch") {
        return async (stmts: D1PreparedStatement[]) => {
          const rs = await t.batch(stmts.map((s) => (s as unknown as { __target?: D1PreparedStatement }).__target ?? s));
          for (const r of rs) written += r.meta.rows_written ?? 0;
          return rs;
        };
      }
      const v = Reflect.get(t, prop);
      return typeof v === "function" ? v.bind(t) : v;
    },
  });
}

const ID = "2026-11-04 15-01";
const LINES = 100;
const transcript = Array.from({ length: LINES }, (_, i) =>
  `[00:${String(i % 60).padStart(2, "0")}] Анна: строка номер ${i} про бюджет и запуск продукта`).join("\n");
const payload = (over = {}) => ({ schema: 1 as const, id: ID, hash: "a".repeat(64), folder: ID,
  call: { schema: 1, id: ID, topic: "launch" }, transcript, summary: null, ...over });

async function rows(fn: () => Promise<unknown>): Promise<number> {
  written = 0;
  await fn();
  return written;
}

describe("D1 writes", () => {
  const counts: Record<string, number> = {};
  beforeAll(async () => {
    db = counting(await localD1());
    await putCall(db, { ...payload(), id: "2026-01-01 00-00" }); // the schema exists, other rows too
  });
  it("a metadata-only PUT does not rewrite the FTS index", async () => {
    counts.first = await rows(() => putCall(db, payload()));
    counts.metadata = await rows(() => putCall(db, payload({ folder: `${ID} · renamed`, project_title: "Acme", hash: "b".repeat(64) })));
    counts.text = await rows(() => putCall(db, payload({ transcript: transcript + "\n[01:00] Я: ещё строка", hash: "c".repeat(64) })));
    counts.note = await rows(() => addNote(db, ID, { id: "n1", at: "2026-11-05T10:00:00Z", text: "заметка про бюджет", source: "app" }));
    counts.sameNotes = await rows(() => mergeNotes(db, ID, [{ id: "n1", at: "2026-11-05T10:00:00Z", text: "x", source: "app" }], []));
    counts.metadataWithNote = await rows(() => putCall(db, payload({ transcript: transcript + "\n[01:00] Я: ещё строка", hash: "d".repeat(64), folder: "x" })));
    console.log(`D1 rows written for a ${LINES}-line call:`, JSON.stringify(counts));
    expect(counts.first).toBeGreaterThan(LINES); // several rows per line (FTS5 shadow tables)
    expect(counts.metadata).toBeLessThan(10);
    expect(counts.metadataWithNote).toBeLessThan(10);
    expect(counts.text).toBeGreaterThan(LINES);
    expect(counts.sameNotes).toBe(0);
  });
  it("still finds the call after metadata-only PUTs", async () => {
    const r = await db.prepare(`SELECT count(*) AS n FROM chunks WHERE chunks MATCH 'бюджет'`).first<{ n: number }>();
    expect(r?.n).toBeGreaterThan(LINES); // both calls' lines and the note
  });
});

describe("D1 writes of note deletions", () => {
  it("a tombstone for a note the call lacks does not rebuild the note chunks, and a repeat writes nothing", async () => {
    const n2 = { id: "n2", at: "2026-11-05T11:00:00Z", text: "вторая заметка", source: "app" };
    await addNote(db, ID, n2);
    const added = await rows(() => addNote(db, ID, { ...n2, id: "n3", at: "2026-11-05T12:00:00Z" })); // a rebuild of 3 note chunks
    const missing = await rows(() => deleteNote(db, ID, "never-existed"));
    const again = await rows(() => deleteNote(db, ID, "never-existed"));
    expect(missing).toBeGreaterThan(0);
    expect(missing).toBeLessThan(added); // only the tombstone row
    expect(again).toBe(0);
    expect((await notesOf(db, ID)).map((n) => n.id)).toEqual(["n1", "n2", "n3"]);
    const hit = await db.prepare(`SELECT count(*) AS n FROM chunks WHERE chunks MATCH 'втор'`).first<{ n: number }>();
    expect(hit?.n).toBe(2); // the note chunks are still there: n2 and n3
  });
});
