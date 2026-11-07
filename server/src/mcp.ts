// The MCP server: read-only tools plus add_note and delete_note, the only writes (notes).
// Stateless (a fresh McpServer per request), no Durable Objects.
import { McpServer } from "@modelcontextprotocol/server";
import { createMcpHandler, getMcpAuthContext } from "agents/mcp/server";
import { env } from "cloudflare:workers";
import { z } from "zod";
import { VERSION, type Env } from "./api";
import { MAX_ALSO, MAX_QUERY } from "./search";
import { addNote, connectorFetch, deleteNote, connectorSearch, getCall, listCalls, searchCalls, ToolError } from "./tools";

const readOnly = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
const appendOnly = { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false };
const NOTES_VISIBLE = "Notes are visible to the user in the Sozvon app on their Mac.";
const text = (t: string) => ({ content: [{ type: "text" as const, text: t }] });
const structured = (value: object) =>
  ({ content: [{ type: "text" as const, text: JSON.stringify(value) }], structuredContent: value as Record<string, unknown> });

async function run<T>(fn: () => Promise<T>, wrap: (v: T) => ReturnType<typeof text> | ReturnType<typeof structured>) {
  try {
    return wrap(await fn());
  } catch (e) {
    if (e instanceof ToolError) return { ...text(`ERROR: ${e.message}`), isError: true };
    throw e;
  }
}

function createServer() {
  const db = (env as unknown as Env).DB;
  const props = getMcpAuthContext()?.props ?? {};
  const origin = String(props.origin ?? "");
  const client = String(props.client ?? ""); // the connector's name, saved at sign-in
  const server = new McpServer({ name: "sozvon", version: VERSION });

  server.registerTool("list_calls", {
    description: "List calls recorded by Sozvon, newest first: id (the date and time it started), topic, project, participants, duration, notes.",
    inputSchema: z.object({
      query: z.string().default("").describe("Optional case-insensitive filter over topic, project, participants, summary, transcript and notes."),
      limit: z.number().int().default(20).describe("Maximum number of calls."),
    }),
    annotations: readOnly,
  }, ({ query, limit }) => run(() => listCalls(db, query, limit), text));

  server.registerTool("get_call", {
    description: `Summary and/or transcript of a Sozvon call, followed by its notes (if any). ${NOTES_VISIBLE}`,
    inputSchema: z.object({
      call_id: z.string().describe('Call id from list_calls (the "YYYY-MM-DD HH-MM" date the recording started; a second recording in the same minute gets a "-2" suffix).'),
      part: z.enum(["summary", "transcript", "both"]).default("summary").describe("summary, transcript or both."),
    }),
    annotations: readOnly,
  }, ({ call_id, part }) => run(() => getCall(db, call_id, part), text));

  server.registerTool("search_calls", {
    description: [
      "Search all Sozvon call transcripts, summaries and notes, best matches first.",
      "",
      'Ranked full-text search: words match by stem in Russian and English ("budgets" finds "budget"), and lines that contain more of the query words rank higher. Speech is transcribed as spoken, so pass also: 2-3 alternative phrasings of how the answer was likely said (the other language, synonyms, colloquial wording, product or people names). All phrasings are searched and fused.',
      "",
      "Each line: call id: [timestamp] speaker: utterance (call topic · project). Summary lines show the summary section instead of a timestamp and speaker, note lines the date and who added the note. Open a call with get_call(call_id).",
    ].join("\n"),
    inputSchema: z.object({
      text: z.string().max(MAX_QUERY).describe("What to look for: keywords, a phrase or a short question."),
      limit: z.number().int().default(20).describe("Maximum number of lines."),
      also: z.array(z.string().max(MAX_QUERY)).max(MAX_ALSO).default([])
        .describe(`Optional 2-3 alternative phrasings of the same query (at most ${MAX_ALSO}).`),
    }),
    annotations: readOnly,
  }, ({ text: q, limit, also }) => run(() => searchCalls(db, q, limit, also), text));

  server.registerTool("add_note", {
    description: [
      "Add a note (a comment) to a Sozvon call: a decision, a follow-up, a correction, context for later.",
      "",
      `${NOTES_VISIBLE} get_call shows them and search_calls finds them. Notes can't be edited; delete_note removes one. At most 4000 characters each and 200 per call.`,
    ].join("\n"),
    inputSchema: z.object({
      call_id: z.string().describe("Call id from list_calls or search_calls."),
      text: z.string().describe("The note, plain text."),
    }),
    annotations: appendOnly,
  }, ({ call_id, text: note }) => run(() => addNote(db, call_id, note, client), text));

  server.registerTool("delete_note", {
    description: [
      "Delete a note from a Sozvon call, when the user asks for it.",
      "",
      `The note disappears from the Sozvon app on the user's Mac and from this server. get_call lists each note as "- date time · source · note id: text".`,
    ].join("\n"),
    inputSchema: z.object({
      call_id: z.string().describe("Call id from list_calls or search_calls."),
      note_id: z.string().describe("The note's id from get_call."),
    }),
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
  }, ({ call_id, note_id }) => run(() => deleteNote(db, call_id, note_id), text));

  // ChatGPT connectors (chat search, deep research) look for exactly these two tools.
  server.registerTool("search", {
    description: "Search the user's Sozvon calls (transcripts, summaries and notes, Russian and English). Returns one result per call, best first; pass a result id to fetch.",
    inputSchema: z.object({ query: z.string().max(MAX_QUERY).describe("What to look for: keywords, a phrase or a short question.") }),
    outputSchema: z.object({
      results: z.array(z.object({ id: z.string(), title: z.string(), url: z.string(), text: z.string() })),
    }),
    annotations: readOnly,
  }, ({ query }) => run(() => connectorSearch(db, origin, query), structured));

  server.registerTool("fetch", {
    description: `Full summary, transcript and notes of one Sozvon call by its id (from search). ${NOTES_VISIBLE}`,
    inputSchema: z.object({ id: z.string().describe("Call id from search.") }),
    outputSchema: z.object({
      id: z.string(), title: z.string(), text: z.string(), url: z.string(), metadata: z.record(z.string(), z.string()),
    }),
    annotations: readOnly,
  }, ({ id }) => run(() => connectorFetch(db, origin, id), structured));

  return server;
}

export const mcpHandler = createMcpHandler(createServer);
