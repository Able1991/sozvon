# Security

## Reporting a vulnerability

Please report it privately: open [a new security advisory](https://github.com/Able1991/sozvon/security/advisories/new) (the Security tab of the repository, Report a vulnerability). Do not open a public issue for it.

Say what you found, how to reproduce it and which version of Sozvon you used. You will get an answer within a few days. Once a fix is released, the advisory is published with credit to you, unless you prefer otherwise.

Only the latest release gets fixes.

## In scope

- The Sozvon app for macOS (`Sources/`), its Python engine (`engine/`) and the local MCP server on `127.0.0.1`.
- The server you deploy to your own Cloudflare account (`server/`): the sync API, the sign-in page and OAuth, the MCP endpoint.
- The build and release pipeline (`build.sh`, `.github/workflows`) and the update feed.

Out of scope: problems in Claude Code, Codex, Cursor, Cloudflare or macOS themselves (report those to their vendors), attacks that need the Mac to be already compromised, and running out of the Cloudflare free plan's quotas under a flood of requests.

## Threat model

- **Processing is local.** Recording, transcription, speaker separation and voice prints run on the Mac. There is no Sozvon cloud and no telemetry. The table in the [README](README.md#what-goes-online) lists everything that leaves the Mac and when.
- **Summaries are opt-in and go to the assistant you chose** (Claude Code, Codex or Cursor, on your own subscription). What people say on a call is untrusted text for that assistant. Claude gets no tools for a summary. Codex runs without its shell, your MCP servers, plugins and web search. Cursor has no such switches: it runs in read-only ask mode inside its sandbox, in an empty folder, and Sozvon does not use it where the sandbox does not start. Links in a summary open only when they are `http` or `https`.
- **Your own server is yours.** It runs in your Cloudflare account and gets the text of your calls and, unless you turn it off, call audio. Voice prints go there only if you turn that on. One password of at least 20 characters protects it: the app sends it, and you type it once to sign Claude or ChatGPT in. Connectors can read and search calls and add notes; they never get audio or voice prints. Connect Cloudflare keeps a copy of the password in the server's KV namespace, readable only with your Cloudflare sign-in. Whoever controls your Cloudflare account controls the server and its data.
- **Your Mac account is trusted.** The engine, the models, the settings (`.env`, mode 600, with the server password) and the calls live in your home folder, and the engine runs with the app's microphone, system audio and calendar permissions. Anything that already runs as you can read your calls and change the engine, so Sozvon does not defend against it.
- **Other accounts on the same Mac are not trusted.** The local MCP server listens only on `127.0.0.1` and needs a random password kept in files with mode 600. Two known limits on a shared Mac: the port is fixed, and connecting Claude Code passes the password as a command-line argument for a moment (`claude mcp add` takes it no other way).
