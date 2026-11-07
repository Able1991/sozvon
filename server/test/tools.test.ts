import { beforeAll, describe, expect, it } from "vitest";
import { callMeta, notesOf, putCall } from "../src/db";
import { addNote, connectorFetch, deleteNote, connectorSearch, formatTimestamp, getCall, listCalls, searchCalls, sourceName, ToolError,
         trim } from "../src/tools";
import { localD1 } from "./d1";

let db: D1Database;
beforeAll(async () => {
  db = await localD1();
  await putCall(db, {
    schema: 1, id: "2026-11-04 15-01", hash: "a".repeat(64), folder: "2026-11-04 15-01 · acme · launch · Anna",
    call: { schema: 1, id: "2026-11-04 15-01", profile: "acme", names: ["Anna", "Борис"], topic: "launch", audio: { mic_seconds: 1755.6, system_seconds: 1755.8 } },
    transcript: "[00:01] Борис: Как дела с бюджетом?\n[00:05] Anna: Бюджеты утвердили.\n", summary: "# Summary\nЗапуск в понедельник.\n",
  });
  await putCall(db, {
    schema: 1, id: "2026-11-05 10-00-2", hash: "b".repeat(64), folder: "2026-11-05 10-00-2",
    call: { schema: 1, id: "2026-11-05 10-00-2" }, transcript: "", summary: null,
  });
});

describe("call metadata", () => {
  it("people are the participants, else the typed names of an older app", () => {
    expect(callMeta({ names: ["Anna"], participants: ["Anna Petrova", "Влад"] }).people).toBe("Anna Petrova, Влад");
    expect(callMeta({ names: ["Anna", "Борис"] }).people).toBe("Anna, Борис");
    expect(callMeta({ names: "Anna", participants: null }).people).toBe("");
  });
});

describe("local tool format", () => {
  it("formats durations like the engine", () => {
    expect(formatTimestamp(65.9)).toBe("01:05");
    expect(formatTimestamp(3725)).toBe("01:02:05");
    expect(trim("x".repeat(301))).toBe("x".repeat(299) + "…");
  });
  it("list_calls", async () => {
    expect(await listCalls(db)).toBe([
      "- 2026-11-05 10-00-2: no transcript",
      "- 2026-11-04 15-01: launch · acme · Anna, Борис · 29:15 · summary",
    ].join("\n"));
    expect(await listCalls(db, "", 1)).toMatch(/^- 2026-11-05 10-00-2/);
    expect(await listCalls(db, "борис")).toMatch(/^- 2026-11-04 15-01/); // participants, any case
    expect(await listCalls(db, "БЮДЖЕТЫ")).toMatch(/^- 2026-11-04 15-01/); // transcript text
    expect(await listCalls(db, "понедельник")).toMatch(/^- 2026-11-04 15-01/); // summary text
    expect(await listCalls(db, "nothing like this")).toBe("No calls found.");
  });
  it("get_call", async () => {
    expect(await getCall(db, "2026-11-04 15-01")).toBe("# Summary\nЗапуск в понедельник.\n");
    expect(await getCall(db, "2026-11-04 15-01 · acme · launch · Anna", "transcript")).toContain("[00:05] Anna");
    expect(await getCall(db, "2026-11-05 10-00-2", "both")).toBe("(no summary)\n\n---\n\n(no transcript)");
    await expect(getCall(db, "2026-01-01 00-00")).rejects.toThrow(ToolError);
  });
  it("search_calls", async () => {
    expect(await searchCalls(db, " ")).toBe("Empty query.");
    expect(await searchCalls(db, "zzz")).toBe("Nothing found.");
    expect((await searchCalls(db, "бюджет")).split("\n")).toEqual([
      "2026-11-04 15-01: [00:05] Anna: Бюджеты утвердили. (launch · acme)", // shorter line, higher BM25
      "2026-11-04 15-01: [00:01] Борис: Как дела с бюджетом? (launch · acme)",
    ]);
    expect(await searchCalls(db, "понедельник")).toBe("2026-11-04 15-01: [summary] Summary: Запуск в понедельник. (launch · acme)");
  });
});

describe("ChatGPT connector tools", () => {
  const origin = "https://sozvon.example.workers.dev";
  it("search returns one result per call", async () => {
    expect(await connectorSearch(db, origin, "бюджет запуск")).toEqual({
      results: [{ id: "2026-11-04 15-01", title: "2026-11-04 15-01 · launch · acme",
                  url: `${origin}/calls/2026-11-04%2015-01`, text: expect.any(String) }],
    });
    expect(await connectorSearch(db, origin, "")).toEqual({ results: [] });
  });
  it("fetch returns the whole call", async () => {
    const doc = await connectorFetch(db, origin, "2026-11-04 15-01");
    expect(doc).toMatchObject({ id: "2026-11-04 15-01", url: `${origin}/calls/2026-11-04%2015-01`,
      metadata: { date: "2026-11-04 15-01", topic: "launch", project: "acme", people: "Anna, Борис", duration: "29:15" } });
    expect(doc.text).toContain("Запуск в понедельник.");
    expect(doc.text).toContain("[00:05] Anna: Бюджеты утвердили.");
    await expect(connectorFetch(db, origin, "nope")).rejects.toThrow(ToolError);
  });
});

describe("project title", () => {
  const ID = "2026-10-01 09-00";
  beforeAll(async () => {
    await putCall(db, {
      schema: 1, id: ID, hash: "d".repeat(64), folder: `${ID} · Витрина`, project_title: "Витрина (Ромашка)",
      call: { schema: 1, id: ID, profile: "vitrina" }, transcript: "[00:01] Я: тарифы на хранение", summary: null,
    });
  });
  it("shows the title instead of the slug, and finds the call by it", async () => {
    expect(await listCalls(db, "ромашка")).toBe(`- ${ID}: Витрина (Ромашка) · transcript`);
    expect(await listCalls(db, "vitrina")).toMatch(/^- 2026-10-01 09-00/);
    expect(await searchCalls(db, "тарифы")).toBe(`${ID}: [00:01] Я: тарифы на хранение (Витрина (Ромашка))`);
    expect((await connectorSearch(db, "https://x", "тарифы")).results[0].title).toBe(`${ID} · Витрина (Ромашка)`);
    const doc = await connectorFetch(db, "https://x", ID);
    expect(doc.title).toBe(`${ID} · Витрина (Ромашка)`);
    expect(doc.metadata.project).toBe("Витрина (Ромашка)");
  });
});

describe("notes", () => {
  const ID = "2026-11-05 10-00-2";
  it("add_note appends a note that get_call, list_calls, search and fetch show", async () => {
    expect(await addNote(db, ID, "  Перезвонить Анне про скидку  ", "Claude")).toBe(`Note added to call ${ID}. It is visible in the Sozvon app.`);
    const out = await getCall(db, ID, "both");
    expect(out).toMatch(/^\(no summary\)\n\n---\n\n\(no transcript\)\n\n---\n\n## Notes\n- 20\d\d-\d\d-\d\d \d\d:\d\d · claude · [0-9a-f-]{36}: Перезвонить Анне про скидку$/);
    expect(await listCalls(db, "", 1)).toBe("- 2026-11-05 10-00-2: no transcript · notes: 1");
    expect(await listCalls(db, "скидку")).toMatch(/^- 2026-11-05 10-00-2/);
    expect(await searchCalls(db, "скидка")).toMatch(/^2026-11-05 10-00-2: \[note 20\d\d-\d\d-\d\d\] claude: Перезвонить Анне про скидку$/);
    expect((await connectorSearch(db, "https://x", "скидка")).results[0]).toMatchObject({ id: ID, text: "note (claude): Перезвонить Анне про скидку" });
    const doc = await connectorFetch(db, "https://x", ID);
    expect(doc.text).toContain("# Notes\n\n- ");
    expect(doc.metadata.notes).toBe("1");
  });
  it("re-uploading the call keeps its notes searchable", async () => {
    await putCall(db, { schema: 1, id: ID, hash: "c".repeat(64), folder: ID, call: { schema: 1, id: ID },
                        transcript: "[00:01] Я: новая расшифровка", summary: null });
    expect(await searchCalls(db, "скидка")).toMatch(/claude: Перезвонить Анне про скидку/);
    expect(await searchCalls(db, "расшифровка")).toMatch(/\[00:01\] Я: новая расшифровка/);
  });
  it("add_note checks its input", async () => {
    await expect(addNote(db, "2026-01-01 00-00", "x", "")).rejects.toThrow(ToolError);
    await expect(addNote(db, ID, "  ", "")).rejects.toThrow("the note is empty");
    await expect(addNote(db, ID, "я".repeat(4001), "")).rejects.toThrow("longer than 4000");
    expect(await addNote(db, ID, "я".repeat(4000), "")).toContain("Note added");
  });
  it("delete_note removes a note and leaves a tombstone", async () => {
    await addNote(db, ID, "удалить меня", "");
    const id = (await notesOf(db, ID)).find((n) => n.text === "удалить меня")!.id;
    expect(await deleteNote(db, ID, ` ${id} `)).toBe(`Note ${id} deleted from call ${ID}.`);
    expect((await notesOf(db, ID)).some((n) => n.id === id)).toBe(false);
    expect(await searchCalls(db, "удалить меня")).not.toContain(id);
    await expect(deleteNote(db, ID, id)).rejects.toThrow("no note");
    await expect(deleteNote(db, "2026-01-01 00-00", id)).rejects.toThrow(ToolError);
    const { results } = await db.prepare("SELECT id FROM note_tombstones WHERE call_id = ?1").bind(ID).all<{ id: string }>();
    expect(results.map((r) => r.id)).toContain(id);
  });
  it("names the source like the engine", () => {
    expect(sourceName("Claude")).toBe("claude");
    expect(sourceName("ChatGPT")).toBe("chatgpt");
    expect(sourceName("claude-code")).toBe("claude-code");
    expect(sourceName("codex-mcp-client")).toBe("codex");
    expect(sourceName("My Tool!!")).toBe("my-tool");
    expect(sourceName("")).toBe("assistant");
    expect(sourceName(undefined)).toBe("assistant");
  });
});
