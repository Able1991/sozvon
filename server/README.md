# Sozvon server

Your own server for [Sozvon](https://github.com/Able1991/sozvon): ask Claude or ChatGPT about your calls from your phone or the web, even when your Mac is off.

It runs in your own Cloudflare account (the free plan is enough), so your calls never go to the Sozvon developers or any shared service. What Sozvon uploads to it: the text of your calls (transcripts, summaries, notes, call details) and, by default, the call audio, so another Mac of yours gets the recordings; turn off Send call audio in Settings > Cloud (`SOZVON_SYNC_AUDIO=0`), and only text goes up. Voice prints go up only if you turn on Send voice prints there (`SOZVON_SYNC_VOICES=1`, off by default), so your other Macs recognize the same voices. Audio and voice prints are served only to the Sozvon app, never to Claude, ChatGPT or any connector. Voice prints are biometric data and the audio has other people's voices: on your server they are your responsibility, including those people's consent. One password, `SOZVON_PASSWORD` (at least 20 characters), protects it: Sozvon on your Mac uploads with it, and you log in with it once when you connect Claude or ChatGPT.

**Easiest:** in Sozvon, Settings > Cloud > **Connect Cloudflare**, then Allow in the browser. Sozvon creates the database, uploads this server to your account, sets the password and syncs your calls. Then click Open Claude (or Open ChatGPT) on the same tab and add the connector address shown there.

**Or deploy it yourself**, with the button or `npx wrangler deploy` (Node.js 22 or later), and enter the address and password in Sozvon under Settings > Cloud > Enter the address manually:

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/Able1991/sozvon/tree/main/server)

What it offers: MCP at `/mcp` (OAuth sign-in with the password) with `list_calls`, `get_call`, `search_calls`, `add_note`, `delete_note` and the ChatGPT `search` and `fetch` tools. Assistants can read and search calls, add notes to a call and delete a note; they cannot change or delete a call, its transcript or its summary, and they never get audio or voice prints. The sync API at `/api/` is used by the app.

Kept small for the free plan: at most 350 MB of audio (about 4 hours of calls, then only text syncs), the newest 200 notes per call, the search index is rewritten only when a call's text changes (a new title or folder name writes one row), and client registration and `/authorize` allow 20 requests an hour per IP (an IPv6 /64 counts as one) and 300 a day in total. Connect Cloudflare also keeps a copy of the password in the KV namespace (`sozvon:password`) for your other Macs; the Worker never reads it.

Setup details, permissions, limits, privacy, troubleshooting, how to delete everything and the sync protocol: [docs/SERVER.md](../docs/SERVER.md).

```bash
npm install
npm test          # typecheck, unit tests, tests against a local D1
npx wrangler dev  # http://localhost:8787, with SOZVON_PASSWORD in .dev.vars
```
