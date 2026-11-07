# Your own Sozvon server (optional)

Ask Claude or ChatGPT about your calls from your phone or the web, even when your Mac is off.

**Your calls stay yours.** You run the server yourself, in your own free Cloudflare account. Your calls never go to the Sozvon developers or to any shared service: we host nothing and never see your data. One password protects it, and one command deletes all of it.

What to know before you turn it on:

- **Not end-to-end encrypted.** The server has to read the text to search it. Cloudflare stores it encrypted at rest, and anyone with access to your Cloudflare account can read it.
- **The assistant reads what it opens.** When Claude or ChatGPT reads a call, that text goes to Anthropic or OpenAI, as with any connector.
- **What is uploaded:** transcripts, summaries, notes and call details (date, topic, project, people, duration), and, unless you turn it off (`SOZVON_SYNC_AUDIO=0`, Settings), the call audio, so a new Mac gets your recordings too. The audio of other people is then in your Cloudflare account, under your responsibility: make sure they agree. Audio is never shown to Claude, ChatGPT or any connector. When Sozvon deletes a call's audio automatically after the days you chose, it deletes the server copy too, and no Mac uploads that call's audio again (your other Macs keep their own copy until their own setting removes it).
- **Voice prints, if you use them.** Voice prints (Settings: your own sample, and the voices of people you named in a call) are biometric data. Without an own server they never leave your Mac. With one, they sync to your own Cloudflare account, so your other Macs recognize the same voices; that copy is under your responsibility. Turn it off with `SOZVON_SYNC_VOICES=0` (Settings). Voice prints are never shown to Claude, ChatGPT or any connector. Deleting a voice in Sozvon deletes it everywhere: on this Mac, on the server and on your other Macs.
- **Consent is on you.** Make sure the people you record agree to their words being stored and searched this way.
- **Assistants read, and can leave notes.** Connectors can list, read and search calls, add notes to a call (`add_note`) and delete a note (`delete_note`): you see the notes in the Calls window on your Mac. They cannot change or delete calls.
- **Two-way sync, deletions only from Sozvon.** A new Mac connected to the same server downloads your calls: text and notes, plus audio and voice prints when those toggles are on. Only calls you move to the Trash in Sozvon are deleted on the server; a call that is just missing from the calls folder is downloaded back, never deleted there.

## Setup

1. **Connect Cloudflare.** In Sozvon on your Mac: Settings > Cloud > **Connect Cloudflare**, then **Allow** in the browser. A free Cloudflare account is enough; you can sign up on the same page.

   Sozvon then does the rest in your account, in about a minute: picks your `workers.dev` subdomain (creates one if the account has none), creates the D1 database `sozvon` and the KV namespace `sozvon-oauth` (or reuses them, so running it again never duplicates or loses anything), uploads the server bundled with the app as the Worker `sozvon`, sets a strong random `SOZVON_PASSWORD` (or reuses the current one, see below) and keeps a copy of it in that KV namespace, turns on `https://sozvon.<your-subdomain>.workers.dev`, waits for it to answer and syncs: uploads your calls and downloads the ones already on the server. The Cloud tab then says how many, for example "downloaded 12 calls, 3 sent". If you allowed several accounts, Sozvon asks which one to use.

2. **Connect your assistant** with the address `https://sozvon.<your-subdomain>.workers.dev/mcp` and log in with the password. Both are on the Cloud tab, each with a copy button.
   - **Claude:** click **Open Claude** on the Cloud tab. It puts the address on the clipboard and opens the Add custom connector dialog at `https://claude.ai/customize/connectors?modal=add-custom-connector`: paste the address, name it Sozvon, add it and sign in with the password. The connector then also works in the Claude mobile and desktop apps. On Team and Enterprise plans an owner may need to allow custom connectors.
   - **ChatGPT:** chatgpt.com/plugins > the + button > Add custom MCP server. Enter a name (Sozvon), paste the address, choose OAuth, confirm the warning with "I understand and want to continue", then "Create as a plugin" and sign in with the password. Custom MCP servers need a paid ChatGPT plan, and on Business, Enterprise and Edu workspaces an admin decides who may add them; OpenAI changes plan availability often, so check help.openai.com if the menu is missing.

**Permissions.** Sozvon is a public Cloudflare OAuth application (publisher `sozvon.ottkit.io`, Authorization Code with PKCE, no client secret). It asks for exactly these scopes: Account Settings Read (`account-settings.read`, the account name and its workers.dev subdomain), D1 Write (`d1.write`), Workers Editor (`workers-scripts.edit`), Workers Admin (`workers-scripts.admin`, needed to create the Worker) and Workers KV Storage Write (`workers-kv-storage.write`, to create the namespace and read or write the password copy). It asks for no refresh token: the access token lives about an hour, only in memory, and is dropped once setup finishes. Nothing goes to the Sozvon developers. To revoke the access, open the Cloudflare dashboard: My Profile > Access Management, the list of authorized applications ([direct link](https://dash.cloudflare.com/?to=/profile/access-management/authorization)), Revoke. The server keeps running; only Sozvon's access to your account ends.

**Updating the server.** When a newer Sozvon ships a newer server, the Cloud tab shows **Update server**: you sign in again and Sozvon uploads the new version. Your calls, the password and the connectors stay as they are.

Changing the password (`npx wrangler secret put SOZVON_PASSWORD` or the dashboard) signs out every connector; log in again with the new one and update it in Sozvon Settings > Cloud > Own address. The copy in KV keeps the old password until you run Connect Cloudflare again, so a new Mac would set a new one.

**A new Mac.** Sozvon keeps the server password in `.env`, and Connect Cloudflare also stores a copy in the server's own KV namespace (the one bound as `OAUTH_KV`, `sozvon-oauth`) under the key `sozvon:password`, with the same Cloudflare sign-in. The Worker never reads or serves that key: only someone signed in to your Cloudflare account can see it. Connect Cloudflare on another Mac reads the copy and keeps it if the server accepts it, so the connectors stay signed in. Otherwise (no copy, or the server does not take it) it sets a new password and says that the connectors need to sign in again. Entering the address by hand does not fill in the password: type both, and Sozvon checks them once on Enter or Save. Either way the new Mac downloads every call from the server.

### Manually: the Deploy button or wrangler

If you prefer to deploy yourself, or the app was built without Node.js and says Connect Cloudflare is unavailable:

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/Able1991/sozvon/tree/main/server)

Click the button and sign in to Cloudflare. When asked for `SOZVON_PASSWORD`, enter a long password, for example from `openssl rand -base64 24`. Cloudflare creates the Worker, the database and the sign-in storage. If the setup page did not ask for the password, add it in the Cloudflare dashboard: Workers & Pages > sozvon > Settings > Variables and Secrets > Add, type Secret, name `SOZVON_PASSWORD`. Then in Sozvon: Settings > Cloud > Own address, and paste the address and the password.

Or with Node.js 22 or later:

```bash
git clone https://github.com/Able1991/sozvon && cd sozvon/server
npm install
npx wrangler login
npx wrangler deploy                      # creates the D1 database and the KV namespace on first deploy
npx wrangler secret put SOZVON_PASSWORD  # paste your password
```

Older Wrangler versions do not create resources by themselves: run `npx wrangler d1 create sozvon` and `npx wrangler kv namespace create OAUTH_KV`, then add the printed ids to `wrangler.jsonc` (`database_id` and `id`). No migrations are needed: the server creates its tables on first use.

A server deployed this way can later be taken over by Connect Cloudflare: it reuses the database and namespace the `sozvon` Worker is bound to, so no calls are lost. Such a server has no password copy in KV: unless this Mac already has its password (entered by hand), the first Connect sets a new password once (log in to the connectors again) and keeps a copy from then on.

## If something goes wrong

- **"Cloudflare denied access (GET accounts: ...)".** The message names the request that failed and Cloudflare's reason. Usually a permission was not allowed: click Connect Cloudflare again and allow everything on the Cloudflare page. Workers Admin is needed to create the Worker the first time. Failed requests are also written to `~/Library/Logs/Sozvon/cloudflare.log` (method, path without the account id, status and Cloudflare's message; never the token or the password).
- **"The server is uploaded but does not answer yet".** A new `workers.dev` address can take a minute to come up. Try again a minute later: it reuses everything it created.
- **The connector sign-in says "This authorization expired or was already used; start again".** The sign-in page was opened from an old link, reloaded or submitted twice. Start connecting again in Claude or ChatGPT.
- **"The server did not accept the password" in the Cloud tab, or a wrong password at sign-in.** The password was changed on the server. Enter the current one under Own address in the Cloud tab. After 10 wrong attempts from one IP the server refuses for 15 minutes.
- **Requests fail late in the day.** A daily free plan limit was reached (see below); everything works again after 00:00 UTC.

## Free plan limits

Personal use fits the Cloudflare free plan with a wide margin.

| Service | Free plan |
|---|---|
| Workers | 100,000 requests a day, 10 ms CPU per request |
| D1 database | 5 million rows read and 100,000 rows written a day, 500 MB per database, 5 GB per account |
| KV (sign-in sessions, the password copy) | 100,000 reads and 1,000 writes a day |

**Audio** is stored in the D1 database too, in chunks of 1.9 MB (R2 would need a payment card). The free 5 GB hold about 80 hours of calls. The server keeps at most 4,000,000,000 bytes of audio in total and refuses more with `507`, so the text of new calls always fits; Sozvon then says that the free storage for audio is full and goes on syncing text. Audio of calls you delete, and audio Sozvon removes automatically, frees the space.

Over a daily limit, requests fail until 00:00 UTC. Nothing is charged: the free plan never bills. Text is what costs writes: every transcript line goes into the search index, and D1 also counts the index's internal tables, so each line costs several rows. A one-hour call is roughly 1 to 3 thousand row writes on first upload, and about as much again when its text changes (a transcript fix). The free plan's 100,000 writes a day cover a few dozen hours of new calls a day; a large archive goes up over a few days. A change of metadata only (folder name, project title, topic) rewrites one row, a note a few. For reference, measured on a local D1 for a 100-line call (`server/test/writes.test.ts`): first upload about 103 rows, a text change about 203, a metadata-only change 1, `add_note` 3; the real D1 bills more for the text writes. Very long calls (several hours) can exceed the CPU limit on upload. Workers Paid ($5 a month) raises all of these limits.

## Delete everything

```bash
cd sozvon/server
npx wrangler delete                 # the Worker
npx wrangler d1 delete sozvon       # the database with all calls
npx wrangler kv namespace list      # find the namespace id (sozvon-oauth if Connect Cloudflare made it), then:
npx wrangler kv namespace delete --namespace-id <id>
```

Or in the Cloudflare dashboard: delete the `sozvon` Worker (Workers & Pages), the `sozvon` database (Storage & Databases > D1) and its KV namespace (sign-in sessions and the password copy). Then remove the connector in Claude or ChatGPT, clear the server in Sozvon Settings and, if you used Connect Cloudflare, revoke Sozvon's access as described under Permissions.

## How it works

- A Cloudflare Worker (`server/`) with a D1 database. Transcript lines, summary lines and notes are indexed in SQLite FTS5 with the same Russian and English Snowball stemming and ranking as `search_calls` in the app (BM25 per phrasing, Reciprocal Rank Fusion, coverage re-ranking).
- `/mcp`: MCP over Streamable HTTP, stateless, no Durable Objects. OAuth 2.1 through Cloudflare's `workers-oauth-provider`: discovery (`/.well-known/oauth-protected-resource`, `/.well-known/oauth-authorization-server`), dynamic client registration and Client ID Metadata Documents, PKCE S256. The sign-in page asks for `SOZVON_PASSWORD`.
- Tools: `list_calls(query, limit)`, `get_call(call_id, part)`, `search_calls(text, limit, also)`, `add_note(call_id, text)` and `delete_note(call_id, note_id)` with the same names, arguments and output as the app's local tools (projects by their title, see `project_title` below), plus `search(query)` and `fetch(id)` in the shape ChatGPT connectors and deep research expect. `add_note` and `delete_note` are the only writes: notes can't be edited, `get_call` shows each note's id for `delete_note`, a deleted note leaves a tombstone so the Macs delete it too, at most 4,000 characters each and 200 per call; the note's source is the connector's name given at sign-in (`claude`, `chatgpt`). Notes are stored in the D1 tables `notes` (id, call_id, at, text, source) and `note_tombstones` (id, call_id, at). Citation links `https://<server>/calls/<id>` show a generic page, never call content.
- Each call keeps a hash of its transcript and summary (`text_hash`): a `PUT` with the same text (a new folder name, title or other metadata) does not rewrite the search index.
- `search_calls` takes at most 5 phrasings in `also`, each cut to 500 characters, and the `search` query is at most 500 characters.
- Passwords are compared in constant time. A wrong password waits one second, and 10 wrong attempts from one IP lock it out for 15 minutes. The sign-in form checks its consent handle (and the cookie this browser got with the form) before the password, so a forged post can't use up your attempts and lock you out.
- Client registration (`POST /oauth/register`) and `/authorize` are limited to 20 requests an hour per IP (`429` after that), so nobody can burn the KV free plan's 1,000 writes a day.
- The sign-in page allows posting only to itself and to the client's callback, including loopback callbacks (`localhost`, `127.0.0.0/8`, `[::1]`) of desktop clients.
- An unexpected error in the sync API is a JSON `500` with the reason, never Cloudflare's HTML error page.

## Sync protocol

The app talks to the server over HTTPS with JSON. Version: `schema` 1.

**Authentication:** every request except health sends `Authorization: Bearer <SOZVON_PASSWORD>`.

**Call id:** as in [CONTRACT.md](CONTRACT.md), `^\d{4}-\d{2}-\d{2} \d{2}-\d{2}(-\d+)?$`, for example `2026-11-04 15-01`. In paths it is URL-encoded: `/api/calls/2026-11-04%2015-01`.

### `GET /api/health`

No authentication. `200`:

```json
{"ok": true, "version": "<server version>", "schema": 1}
```

### `GET /api/calls`

`200` with every stored call and what the client needs to diff: the hash the client sent with it, the folder
name, the ids of its notes and of its deleted notes (tombstones), each sorted, and the project title it was
sent with (`""` if none):

```json
{"calls": [{"id": "2026-11-04 15-01", "hash": "<sha256 hex>", "folder": "2026-11-04 15-01 · Acme",
            "notes": ["<note id>"], "notes_deleted": ["<note id>"], "project_title": "Acme Corp"}],
 "deleted": [{"id": "2026-11-03 10-00", "at": "2026-11-05T10:00:00.000Z"}]}
```

`deleted` lists call tombstones: calls deleted with `DELETE /api/calls/{id}` and when, sorted by id.

### `GET /api/calls/{id}`

`200` with the stored payload, for restoring the call on a Mac: the fields of `PUT` below as stored, with all
current notes (oldest first) and the tombstones. `404` when the server has no such call.

```json
{"schema": 1, "id": "2026-11-04 15-01", "hash": "<sha256 hex>", "folder": "<folder name>",
 "call": {"...": "call.json object without notes"}, "transcript": "<transcript.txt>", "summary": "<summary.md or null>",
 "notes": [{"id": "<uuid>", "at": "2026-11-05T09:12:44Z", "text": "<note>", "source": "claude"}],
 "notes_deleted": ["<note id>"], "project_title": "<project title or empty>"}
```

### `PUT /api/calls/{id}`

Creates or replaces the call, merges its notes and reindexes it for search. Body, at most 2,000,000 bytes:

```json
{
  "schema": 1,
  "id": "2026-11-04 15-01",
  "hash": "<sha256 hex the client computed over the payload>",
  "folder": "<folder name>",
  "call": {"...": "call.json object"},
  "transcript": "<transcript.txt content>",
  "summary": "<summary.md content or null>",
  "notes": [{"id": "<uuid>", "at": "<ISO 8601 UTC>", "text": "<1 to 4000 characters>", "source": "<who added it>"}],
  "notes_deleted": ["<note id>"],
  "project_title": "<the project's title on this Mac, optional>"
}
```

`204` on success. `410 Gone` when the call has a tombstone (it was deleted, see `DELETE` below), unless the body has `"restore": true`: then the tombstone is cleared and the call is stored. The client sends `restore` only for a call the user deliberately put back in Sozvon. The server checks that `schema` is 1, `id` equals the id in the path, `hash` is 64 lowercase hex characters, `folder` is a non-empty string of at most 255 characters, `call` is an object, `transcript` is a string and `summary` is a string or null. It stores `hash` as given and does not recompute it. The client computes it over `call`, `transcript` and `summary` only, so neither a note nor a folder rename resends the call.

The app's `call` is a whitelist of `call.json`: `schema`, `id`, `created_at`, `status`, `profile`, `names`, `participants`, `topic`, `languages`, `summary`, plus `audio` with only `mic_seconds` and `system_seconds`. Never `terms`, `engine`, `info_pending`, track start times or notes (those travel in `notes`). The server lists and searches a call's people from `participants`, else `names` (calls from an older app).

`project_title` is optional: the display title of the call's project on the Mac that sent it (`call.profile` holds only the project's slug, for example `polka` for "Полка (Ростелеком)"). At most 200 characters, trimmed. The tools show it instead of the slug and fall back to the slug when it is missing or empty; `list_calls` filters by both. It is not part of the hash, so a Mac that does not have the project never resends the call. Instead the client resends a call when its own non-empty title differs from the `project_title` in `GET /api/calls`.

`notes` and `notes_deleted` are optional (notes carried inside `call` are merged the same way and never stored inside `call`), at most 1,000 notes and 10,000 ids in one body. A note is an object with `id` (1 to 64 letters, digits or dashes), `at` (at most 40 characters), `text` (not blank, at most 4,000 characters) and `source` (at most 40 characters; anything else becomes `assistant`). The merge:

- notes are **never dropped** because the payload lacks them: the stored notes are the union of the stored ones and the payload's, by id;
- an id the server already has keeps its stored note (append-only, no edits);
- `notes_deleted` ids become tombstones, and tombstoned notes are removed and never added again;
- at most 200 notes per call: the server keeps the newest 200 by (`at`, `id`), the same ones the app keeps, and drops older ones. `add_note` on a call that already has 200 is refused.

### `POST /api/calls/{id}/notes`

Merges notes into a stored call without touching the call, exactly as `PUT` does. Body `{"notes": [...], "notes_deleted": [...]}`, both optional. `204`, `404` when the server has no such call, or `410` when the call was deleted (it has a tombstone).

### `DELETE /api/calls/{id}`

Deletes the call, its notes, its note tombstones and its index, and keeps a call tombstone (the id and the time of deletion), so another Mac that still has the call can't upload it back: its `PUT` gets `410` until a `PUT` with `"restore": true`. `204`, also when the call did not exist (the tombstone is kept anyway). The app sends it only for calls the user deleted in Sozvon.

### `DELETE /api/calls/{id}/notes/{note id}`

Deletes a note and keeps a tombstone for it, so a client with a stale copy can't bring it back. `204`, also when the note did not exist (the tombstone is kept anyway); `410` when the call was deleted.

### Audio

Tracks are `mic` and `system` (`mic.m4a`, `system.m4a`, AAC as recorded). D1 tables: `audio_chunks` (call_id, track, idx, data BLOB), `audio_tracks` (call_id, track, size, chunks, sha256, updated_at, start), `audio_staging` (the chunks of uploads not committed yet; abandoned ones go after 7 days) and `audio_removed` (call_id, at: calls whose audio a Mac removed). The audio total is the sum of the size columns of `audio_tracks` and `audio_staging`. `GET /api/calls` lists `"audio": {"mic": "<sha256>", "system": "<sha256>"}` for each call that has some, and `"audio_removed_at"` for each call whose audio was removed.

- `PUT /api/calls/{id}/audio/{track}/{idx}`: one chunk, raw bytes (`Content-Type: application/octet-stream`), at most 1,900,000 bytes, `idx` 0 to 9999, header `X-Sozvon-Sha256` with the sha256 of the whole track. Staged until the commit; a chunk with another sha256 drops the staged chunks of that track. `204`; `404` when the server has no such call, `410` when it was deleted or its audio was removed, `413` over 1,900,000 bytes, `507` when the audio total would pass 4,000,000,000 bytes.
- `POST /api/calls/{id}/audio/{track}/commit` with `{"size", "chunks", "sha256", "start"}` (`start` optional: the track's start offset in seconds after the call's earlier track, 0 for that one, at most 86,400): checks that chunks `0` to `chunks - 1` of that sha256 are staged and add up to `size`, then replaces the stored track with them in one batch (the old version is served whole until then). `204`, `409` when chunks are missing, `410` when the call was deleted or its audio was removed, `413` for a body over 64,000 bytes.
- `GET /api/calls/{id}/audio`: `{"tracks": [{"track", "size", "chunks", "sha256", "updated_at", "start"}], "pending": [{"track", "sha256", "chunks": [{"idx", "size"}]}], "audio_removed_at": null}`; `pending` lets an interrupted upload resume, `start` is `null` when the uploading Mac did not know it, `audio_removed_at` is the time a Mac removed the call's audio (`null` when never).
- `GET /api/calls/{id}/audio/{track}/{idx}`: the chunk's raw bytes, `404` when missing.
- `DELETE /api/calls/{id}/audio`: removes the call's audio (stored and staged) and marks it removed (the first time is kept), `204` also when there was none. From then on no Mac stores that call's audio again: chunk uploads and commits answer `410`. `DELETE /api/calls/{id}` removes its audio too.

Same password, lockout and error format as the calls. No MCP tool reads audio.

### `GET /api/voices`

`200` with every voice print and every voice tombstone, sorted by id:

```json
{"voices": [{"id": "<32 hex>", "name": "Александр Пантелеев", "profile": "acme", "me": false,
             "embedding": [256 numbers], "seconds": 42.5, "updated_at": "2026-11-05T10:00:00Z"},
            {"id": "<32 hex>", "deleted": true, "updated_at": "2026-11-06T09:00:00.000Z"}]}
```

### `PUT /api/voices/{id}`

Creates or replaces a voice print. Body (at most 64,000 bytes): `id` (optional, must equal the path), `name`
(1 to 80 characters, trimmed), `profile` (a project slug `[a-z0-9_-]{0,64}`, optional), `me` (boolean, optional),
`embedding` (exactly 256 finite numbers), `seconds` (0 to 10,000), `updated_at` (ISO 8601). `204`; `410` when the
voice was deleted at or after the body's `updated_at` (a stale copy from another Mac never brings it back); `409`
with `{"error", "voice": <the stored record>}` when the stored record is newer than the body and holds another
embedding (two Macs enrolled the same voice at once: the app merges the two prints and sends the result). A newer
stored record with the same embedding is kept and the answer is `204`.

### `DELETE /api/voices/{id}`

Deletes the voice print and keeps a tombstone (`deleted`, `updated_at` the time of deletion). `204`, also when it
did not exist.

Voice ids are 32 lowercase hex characters (`400` otherwise). The voices endpoints use the same password, the same
lockout after wrong passwords and the same error format as the calls. Voices live in the D1 table `voices` (id, name,
profile, me, embedding as JSON, seconds, updated_at, deleted), created on first use like the other tables. No MCP
tool reads it.

### Sync rules of the app

`bin/sync_server.py` ([CONTRACT.md](CONTRACT.md), section 3):

1. calls deleted in Sozvon (`<data>/server-deleted.json`) are deleted on the server, which keeps a call tombstone; an id whose folder is back with its `call.json` is dropped from the list instead;
2. calls the user put back in Sozvon (undo of Move to Trash, `<data>/server-restore.json`) are sent with `"restore": true`;
3. a call in `deleted` (deleted on another Mac) is never uploaded: its folder on this Mac goes to the macOS Trash, so it can be put back. A call being recorded or waiting for transcription (`recorded`, `processing`, no `call.json`, or a `call.json` without a status and without `transcript.txt`) is left for the next sync. A call this Mac already removed for a tombstone and the user put back from the Finder Trash stays on this Mac only (logged once); to bring it back to the server, move it to the Trash in Sozvon and undo;
4. server calls with no folder on this Mac are downloaded (never deleted); in the folder name from the server control and separator characters (Unicode Cc, Cs, Zl, Zp) and leading dots are dropped and `/`, `\` and `:` become `-`; the name must start with the id, else the id alone is used;
5. notes are merged both ways by id with tombstones; both sides keep the newest 200 per call by (`at`, `id`);
6. finished calls with a different hash are sent with `PUT`, and so is a call whose non-empty project title on this Mac changed since this Mac last sent it (`<data>/server-titles.json`). A title that only differs from the server's is sent once, never back and forth between two Macs.

7. audio (`SOZVON_SYNC_AUDIO`, default on): tracks whose sha256 differs from the server's go up in chunks after the text, resuming an interrupted upload; a call with no tracks on the Mac gets the server's; a call whose audio the app removed (`audio_removed_at`) never syncs audio and its server copy is deleted and marked removed (even with audio sync off); a call the server marks removed is never uploaded or downloaded by any Mac, and Macs that still have its tracks keep them. Each track's start offset goes up with it and comes down into `call.json`. A `507` stops audio uploads for that sync, with one `STATUS:` line;
8. voice prints: deletions made in Sozvon are always sent; with voice sync on (`SOZVON_SYNC_VOICES`, default on) records go up when the server lacks them or holds an older one, come down when missing on the Mac or newer on the server (never over a newer one on the Mac), and server tombstones delete them on the Mac. Counts are a `STATUS:` line, the `RESULT` line stays the same.

The first sync after updating to a Sozvon with this hash (no folder name, whitelisted `call`) uploads every call once more.

A failed request for one call (a `413`, a `5xx`, a timeout) does not stop the sync: it prints `STATUS: Не получилось с <id>: <reason>. Повторю при следующей синхронизации` (in English with an English interface), counts the call as failed and goes on. The last line is `RESULT: ok <sent> <deleted> <downloaded> <trashed> <failed>`, and the exit code is 1 when `failed` is above 0; the Cloud tab then shows "Not sent: N". A wrong password, or 3 calls in a row with no answer at all, stops the sync.

A missing calls folder stops the sync before anything happens.

### Errors

JSON `{"error": "<message>"}` with:

| Status | When |
|---|---|
| 400 | invalid call id, note id or voice id, body is not JSON, a field is invalid, or a sign-in request is invalid or expired |
| 401 | missing or wrong password |
| 404 | unknown path, no such call (`GET /api/calls/{id}`, `POST .../notes`, an audio chunk upload), or no such audio chunk (`GET .../audio/{track}/{idx}`) |
| 405 | wrong method for the path |
| 410 | the call was deleted (a call tombstone): `PUT` without `"restore": true`, `POST .../notes`, `DELETE .../notes/{note id}`, audio chunk uploads and commits; the call's audio was removed (audio chunk uploads and commits); or a voice was deleted after the change in a `PUT /api/voices/{id}` |
| 409 | an audio commit whose chunks are not all staged; a `PUT /api/voices/{id}` older than the stored record, which holds another voice print (the reply has the stored record as `"voice"`; the app merges the two and sends the result) |
| 413 | body larger than 2,000,000 bytes, or more than 998,999 lines; an audio chunk larger than 1,900,000 bytes; a voice print or audio commit body larger than 64,000 bytes |
| 429 | too many wrong passwords from this IP, retry in 15 minutes; or more than 20 `POST /oauth/register` or `/authorize` requests an hour from this IP |
| 503 | `SOZVON_PASSWORD` is not set on the server |
| 507 | the audio storage is full (4,000,000,000 bytes): no new audio, text still works |
| 500 | server or database error (for example a daily free plan limit), retry later |

## Development

```bash
cd server
npm install
npm test                                              # typecheck, unit tests, tests against a local D1
echo 'SOZVON_PASSWORD=test-password' > .dev.vars
npx wrangler dev                                      # http://localhost:8787
curl localhost:8787/api/health
```
