import { beforeAll, describe, expect, it } from "vitest";
import { putCall } from "../src/db";
import { type Hit, MAX_ALSO, MAX_QUERY, queryList, rank, search } from "../src/search";
import { localD1 } from "./d1";
import fixture from "./search.fixture.json";

const hit = (rid: number, call_id: string, text: string): Hit =>
  ({ rid, call_id, kind: "transcript", ts: "", speaker: "", text, topic: "", profile: "" });

describe("rank", () => {
  it("fuses lists with RRF and blends in coverage", () => {
    const a = hit(1, "c1", "budget review"), b = hit(2, "c1", "budget"), c = hit(3, "c2", "review of the budget plan");
    const out = rank(["budget review"], [[b, a, c]], 10);
    // a and c cover both words, so they beat b although BM25 put b first
    expect(out.map((h) => h.rid)).toEqual([1, 3, 2]);
    expect(out[0].score).toBeCloseTo(0.5 * 1 + 0.5 * (1 / 61) / (1 / 60));
  });
  it("adds alternative phrasings and drops repeated text in one call", () => {
    const a = hit(1, "c1", "Same  words"), b = hit(2, "c1", "same words"), c = hit(3, "c2", "same words");
    const out = rank(["same", "words"], [[a, b], [c]], 10);
    expect(out.map((h) => h.rid)).toEqual([1, 3]);
  });
  it("returns nothing for empty lists and respects the limit", () => {
    expect(rank(["x"], [[]], 5)).toEqual([]);
    expect(rank(["x"], [[hit(1, "a", "x"), hit(2, "b", "x")]], 1)).toHaveLength(1);
  });
});

describe("query bounds", () => {
  it("keeps at most 5 alternative phrasings of at most 500 characters, like the engine", () => {
    const also = Array.from({ length: 9 }, (_, i) => `variant ${i}`);
    expect(queryList("q", also)).toEqual(["q", ...also.slice(0, MAX_ALSO)]);
    expect(queryList("я".repeat(2000))[0]).toHaveLength(MAX_QUERY);
    expect(queryList("q", "not a list" as unknown as unknown[])).toEqual(["q"]);
  });
});

// search.fixture.json: the same calls searched by engine/sozvon_engine/search.py.
describe("parity with the engine over D1", () => {
  let db: D1Database;
  beforeAll(async () => {
    db = await localD1();
    for (const c of fixture.calls) {
      await putCall(db, { schema: 1, id: c.id, hash: "0".repeat(64), folder: c.folder, call: c.call, transcript: c.transcript, summary: c.summary });
    }
  });

  const line = (h: { call_id: string; kind: string; ts: string; speaker: string; text: string }) =>
    [h.call_id, h.kind, h.ts, h.speaker, h.text].join(" | ");
  it.each(fixture.queries)("ranks $text $also like the engine", async ({ text, also, hits }) => {
    const got = await search(db, text, also, 10);
    // Lines with equal BM25 may come back in another order, which moves their RRF share between them:
    // the scores and the set of lines must match, and so must the best line when it is unique.
    expect(got.map((h) => h.score.toFixed(6))).toEqual(hits.map((h) => h.score.toFixed(6)));
    expect(got.map(line).sort()).toEqual(hits.map(line).sort());
    if (hits.length < 2 || hits[0].score > hits[1].score) expect(line(got[0])).toBe(line(hits[0]));
  });

  it("reindexes a call on PUT and finds nothing for an empty query", async () => {
    const c = fixture.calls[1];
    await putCall(db, { schema: 1, id: c.id, hash: "1".repeat(64), folder: c.folder, call: c.call, transcript: "[00:00] John: zebra crossing", summary: null });
    expect((await search(db, "zebra")).map((h) => h.call_id)).toEqual([c.id]);
    expect(await search(db, "node-selector")).toEqual([]);
    expect(await search(db, "  ", ["?"])).toEqual([]);
  });
});
