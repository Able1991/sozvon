import { expect, it } from "vitest";
import { chunks } from "../src/chunks";

it("parses transcript lines and summary sections like the engine", () => {
  const tr = "[00:01] Anna: Hello there\n\n[1:02:03] Борис Иванов: Привет: да\nno speaker line\n";
  const sm = "# Summary\nOverview text\n\n## Decisions\n- Ship it\n---\n***\n";
  expect(chunks(tr, sm)).toEqual([
    { kind: "transcript", ts: "00:01", speaker: "Anna", text: "Hello there" },
    { kind: "transcript", ts: "1:02:03", speaker: "Борис Иванов", text: "Привет: да" },
    { kind: "transcript", ts: "", speaker: "", text: "no speaker line" },
    { kind: "summary", ts: "", speaker: "Summary", text: "Overview text" },
    { kind: "summary", ts: "", speaker: "Decisions", text: "- Ship it" },
  ]);
  expect(chunks("", null)).toEqual([]);
});
