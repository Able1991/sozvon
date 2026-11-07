// Search chunks of a call, as in engine/sozvon_engine/search.py: one per transcript.txt line
// ("[MM:SS] Name: text"), one per summary.md line, with the section heading in place of the speaker, and
// one per note (noteChunk).

export interface Chunk {
  kind: "transcript" | "summary" | "note";
  ts: string; // note: its date
  speaker: string; // summary: section heading; note: its source
  text: string;
}

const LINE = /^\[(\d+:\d{2}(?::\d{2})?)\]\s+(.+?):\s+(.*)$/;

export function chunks(transcript: string, summary: string | null): Chunk[] {
  const out: Chunk[] = [];
  for (const raw of transcript.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    const m = LINE.exec(line);
    out.push(m ? { kind: "transcript", ts: m[1], speaker: m[2], text: m[3] }
               : { kind: "transcript", ts: "", speaker: "", text: line });
  }
  let section = "";
  for (const raw of (summary ?? "").split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith("#")) section = line.replace(/^#+/, "").trim();
    else if (line && line.replace(/[-*_ ]/g, "") !== "") out.push({ kind: "summary", ts: "", speaker: section, text: line });
  }
  return out;
}

/** The search chunk of a note: its date in place of a timestamp, its source in place of a speaker. */
export function noteChunk(n: { at: string; text: string; source: string }): Chunk {
  return { kind: "note", ts: n.at.slice(0, 10), speaker: n.source, text: n.text.split(/\s+/).filter(Boolean).join(" ") };
}
