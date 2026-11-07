import { describe, expect, it } from "vitest";
import { ftsQuery, stem, stemText, words } from "../src/textproc";
import fixture from "./textproc.fixture.json";

// textproc.fixture.json was produced by engine/sozvon_engine/textproc.py (snowballstemmer 3.1.1).
describe("parity with the engine", () => {
  it("stems every word like the engine", () => {
    for (const [w, s] of Object.entries(fixture.stems)) expect([w, stem(w)]).toEqual([w, s]);
  });
  it.each(fixture.texts)("tokenizes $text", ({ text, words: w, stem_text, fts_query }) => {
    expect(words(text)).toEqual(w);
    expect(stemText(text)).toEqual(stem_text);
    expect(ftsQuery(text)).toEqual(fts_query);
  });
});

describe("textproc", () => {
  it("keeps short words and numbers as they are", () => {
    expect(words("Я ok 42 ОЙ")).toEqual(["я", "ok", "42", "ой"]);
  });
  it("matches Russian and English word forms", () => {
    expect(stem("бюджетами")).toBe(stem("бюджет"));
    expect(stem("budgets")).toBe(stem("budget"));
  });
  it("turns dotted and dashed tokens into phrases", () => {
    expect(ftsQuery("node-selector 10.9.8.7")).toBe('"node selector" OR "10 9 8 7"');
    expect(ftsQuery("a ? !")).toBe("");
  });
  it("handles letters outside the BMP", () => {
    expect(words("𝒜bc x")).toEqual(["𝒜bc", "x"]);
  });
});
