import { describe, expect, it } from "vitest";
import { ensureSchema, putCall } from "../src/db";
import { listCalls } from "../src/tools";
import { localD1 } from "./d1";

describe("schema upgrade", () => {
  it("adds project_title to a calls table created by an older server, keeping its rows", async () => {
    const db = await localD1();
    // The calls table as server 0.3.1 created it.
    await db.prepare(`CREATE TABLE calls (
      num INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, hash TEXT NOT NULL, folder TEXT NOT NULL,
      call TEXT NOT NULL, summary TEXT, has_transcript INTEGER NOT NULL,
      topic TEXT NOT NULL, profile TEXT NOT NULL, people TEXT NOT NULL, seconds REAL NOT NULL,
      hay TEXT NOT NULL, updated_at TEXT NOT NULL)`).run();
    await db.prepare(`INSERT INTO calls VALUES (1, '2026-11-01 10-00', ?1, '2026-11-01 10-00', '{}', NULL, 0,
      '', 'vitrina', '', 0, '', '')`).bind("a".repeat(64)).run();
    await ensureSchema(db);
    expect(await listCalls(db)).toBe("- 2026-11-01 10-00: vitrina · no transcript");
    await putCall(db, { schema: 1, id: "2026-11-01 10-00", hash: "b".repeat(64), folder: "2026-11-01 10-00",
                        call: { profile: "vitrina" }, transcript: "", summary: null, project_title: "Витрина" });
    expect(await listCalls(db)).toBe("- 2026-11-01 10-00: Витрина · no transcript");
  });
});
