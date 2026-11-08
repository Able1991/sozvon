<p align="center"><img src="docs/images/icon.png" width="128" alt="Sozvon"></p>

<h1 align="center">Sozvon</h1>

<p align="center">Records calls on your Mac and transcribes them locally: who said what, with timestamps, plus a summary with decisions and action items.</p>

<p align="center">
<a href="https://github.com/Able1991/sozvon/actions/workflows/ci.yml"><img src="https://github.com/Able1991/sozvon/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
<a href="https://github.com/Able1991/sozvon/actions/workflows/security.yml"><img src="https://github.com/Able1991/sozvon/actions/workflows/security.yml/badge.svg" alt="Security"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT"></a>
</p>

<p align="center"><b><a href="https://github.com/Able1991/sozvon/releases/latest/download/Sozvon.dmg">Download for Mac</a></b> · <a href="https://able1991.github.io/sozvon/">Website</a> · <a href="https://able1991.github.io/sozvon/docs.html">Documentation</a> · <a href="README.ru.md">Русский</a></p>

<p align="center"><img src="docs/images/en-calls.png" width="820" alt="Calls window"></p>

## Features

- **One button.** A floating panel above all windows (including full-screen Zoom) or a menu bar icon: Record, take the call, Stop. Works with Zoom, Google Meet, FaceTime, Telegram, TrueConf, anything: it captures system audio and the microphone, no virtual audio drivers.
- **Offers to record, never records by itself.** When Zoom, Telegram, a browser or another call app turns on the microphone, the panel asks "A call is on in Zoom. Record?". Not Now keeps it quiet until that call ends.
- **Title and people from Calendar.** After Stop, the form is already filled from the meeting in your calendar: topic, participants and project.
- **Later.** No time to describe the call right after Stop? Press Later: the call waits under "Waiting for Description" in the menu, and Sozvon reminds you once you are free.
- **Mark what matters.** Press the star on the panel or ⌃⌥I during the call: that moment is starred in the transcript and explained in the summary.
- **Never a silent recording.** If your mic or the other side goes silent for two minutes, Sozvon captures that audio again by itself and tells you if that did not help.
- **Local.** Speech recognition and speaker separation run on Apple silicon. Audio leaves your Mac only for your own server, if you set one up and keep Send call audio on.
- **No echo without headphones.** On speakers your mic hears the other side too; Sozvon removes that echo from your track before recognition, on the Mac, and raises a very quiet mic; the player plays this cleaned voice, so you hear yourself without the echo. During a recording it warns when the system input volume is below 50% or your voice has been barely audible for three minutes. Headphones are still best.
- **Who said what.** Your voice and the other side are recorded on separate tracks, remote speakers are separated by voice, and the assistant names them from the conversation ("Masha, how are you?").
- **Knows voices.** Record a 20-second sample of your voice in Settings > General > My voice (add one per call language if you like). Settings > General > Voices > Show… lists every saved voice and deletes any of them. When a transcript names everyone right, Remember Voices confirms them in one click. Name a speaker in a call once, and Sozvon saves their voice print for the project and names that voice by itself in the project's next calls, even two people with the same first name. Voice prints are biometric data: they stay on your Mac (and your own server, if you use one), and deleting one deletes it everywhere.
- **Summary** in the language of the call: a short overview, decisions, action items with owners, open questions. Optional, through Claude Code, Codex or Cursor on your own subscription.
- **Projects.** People, terms and replacements per client, so recognition spells names and jargon correctly. Projects can be discovered automatically from your Claude Code, Codex or Cursor sessions.
- **Calls window.** Calls grouped by day, search across everything including transcript text, a card with the summary, the transcript and notes.
- **Listen along.** Click a transcript line and the call plays from there, with the current line highlighted. Back and forward 15 s, 1x, 1.5x, 2x.
- **Fix the transcript.** Rename a speaker (with name suggestions, in the whole transcript or just one line), swap two mixed-up people, or fix a misheard word and let the project remember the fix for the next calls. Then Update Summary rewrites only the summary to match.
- **Delete audio automatically** after a week, 15, 30 or 60 days if you like, on your own server too: transcripts, summaries and notes stay.
- **Import recordings.** Drop an old m4a, mp3, wav, mp4 or mov onto the Calls window and it is transcribed like a new call.
- **Tasks to Reminders.** Your action items from the summary, and notes if you want, go to Apple Reminders, with due dates when the call named a clear day.
- **Notes.** Leave a note on a call (a decision, a follow-up), or let Claude, Codex and Cursor add one. Notes show under the call and search finds them.
- **Claude, Codex and Cursor can read your calls** through MCP: "what did we decide with the client last week?". Ranked search finds any word form, and the assistant passes alternative phrasings, because speech is transcribed as it was said.
- **Ask about a call from your phone (optional).** Your own small server in your own free Cloudflare account, set up with one button, lets Claude or ChatGPT answer from the phone or the web while the Mac is off. We never see your data.
- **Sync across Macs.** A second Mac connected to the same server gets your calls with their audio, notes and voice prints; a call you delete in Sozvon goes away on the others too (to the Trash).
- **Multiple languages** in one call, Russian and English UI, light and dark mode.

<p align="center">
<img src="docs/images/en-panel.png" width="300" alt="Floating panel">
&nbsp;
<img src="docs/images/en-menu.png" width="250" alt="Menu">
</p>

## Installation

1. Download `Sozvon.dmg` from [Releases](https://github.com/Able1991/sozvon/releases/latest) and drag Sozvon to Applications. The app is signed and notarized by Apple.
2. Launch it. The setup assistant asks for your name, the language of your calls, a recognition model and an assistant for summaries, then installs the engine: 5-10 minutes, 1-4 GB depending on the model. No tokens or sign-ups.
3. Allow the Microphone, Screen Recording and System Audio Recording (System Settings shows the last two under Screen & System Audio Recording; setup and Settings > General > Permissions have buttons for each). Video is not recorded, only audio. System audio comes through a Core Audio process tap, so FaceTime calls are heard too. Setup ends with a three second test recording that proves recording works before the first call; until setup is finished, the rest of the menu is unavailable. Access to Reminders is asked only when you first use To Reminders. The call prompt needs no permission.

**Updates** install themselves: once a day Sozvon downloads a new version in the background and installs it when there is no recording, call or open window. Versions before 0.1.2 need one manual update.

**Requirements:** a Mac with Apple silicon (M1 or later), macOS 15 Sequoia or later. For summaries and project discovery: [Claude Code](https://claude.com/code), [Codex CLI](https://github.com/openai/codex) or [Cursor CLI](https://cursor.com/cli) installed, optional.

<p align="center">
<img src="docs/images/en-setup-model.png" width="360" alt="Choosing a model">
&nbsp;
<img src="docs/images/en-callinfo.png" width="360" alt="After a call">
</p>

## Recognition models

| Model | Size | Languages | Notes |
|---|---|---|---|
| **Whisper Turbo** (recommended) | 1.6 GB | 99 | Fast and accurate, uses the project vocabulary |
| Whisper Large v3 | 3.1 GB | 99 | Most accurate, about 2x slower |
| Whisper Small | 0.5 GB | 99 | For Macs with 8 GB of memory |
| GigaAM v3 (Sber) | 0.2 GB | Russian | Light and fast, no project vocabulary |
| Parakeet v3 (NVIDIA) | 0.7 GB | 25 European | Very fast, no project vocabulary |

Speaker separation: [pyannote](https://github.com/pyannote/pyannote-audio) (31 MB, installed with the app). Switch models in Settings → Recognition. The same tab has "Transcribe at low priority": transcription yields to other apps.

## Claude Code, Codex and Cursor (MCP)

Settings → Assistants → Connect. Cursor has no `mcp add` command, so for Cursor Sozvon adds its entry to `~/.cursor/mcp.json` itself, keeping comments and other servers; the Cursor app and Cursor CLI both read that file. While running, Sozvon keeps one shared MCP server on `127.0.0.1` for all sessions (about 40 MB). The assistant gets these tools:

| Tool | What it does |
|---|---|
| `list_calls` | list calls: date, topic, project, people, duration; filter by any text |
| `get_call` | summary and/or transcript of a call, with its notes |
| `search_calls` | ranked search across all transcripts, summaries and notes, with timestamps; matches word forms; `also` takes 2-3 alternative phrasings of the query |
| `add_note` | leave a note on a call (a decision, a follow-up); it shows in the Calls window |
| `delete_note` | delete a note from a call, by the id `get_call` shows |
| `transcribe` | transcribe any audio or video file |
| `list_profiles`, `add_terms`, `add_replacement`, `remove_replacement` | projects, terms and replacements |
| `list_models`, `show_vocab`, `preview_prompt` | models, the vocabulary and the hint the model gets |

Manual setup and details: [documentation](https://able1991.github.io/sozvon/docs.html#mcp). The server requires the token from `~/Library/Application Support/Sozvon/.mcp-token`.

### Your own server (optional)

To ask Claude or ChatGPT about your calls from your phone or the web while the Mac is off, set up your own small server in your free Cloudflare account: Settings > Cloud > Connect Cloudflare, then Allow. Then Open Claude (or ChatGPT) on the same tab adds it as a connector ([docs/SERVER.md](docs/SERVER.md)). It runs in your account, so your calls never go to us or any shared service, and you can delete everything at any time. The text of your calls always goes up. Two toggles on the same tab, both on by default, decide the rest: Send call audio (stored in chunks in your own Cloudflare D1; the free plan holds about 80 hours of calls, after that the server refuses new audio, only text syncs and Sozvon says so) and Send voice prints. The voices of other people are then in your Cloudflare account, under your responsibility, including their consent. Claude and ChatGPT never get audio or voice prints, only text. Sync goes both ways: a new Mac connected to the same server downloads your calls with their audio (so the player works), notes and voice prints, only calls you delete in Sozvon are deleted there, and a call deleted on one Mac goes to the Trash on the others. Connect Cloudflare keeps a copy of the server password in your own Cloudflare account, so Connect on a new Mac reuses it and the connectors stay signed in. Through the server Claude and ChatGPT can list, read and search calls, add notes and delete a note, but never change or delete a call. When a new Sozvon brings a new server, press Update server on the Cloud tab once.

## What goes online

| What | Where | When |
|---|---|---|
| Recording, transcription, echo removal, speaker separation, imported recordings | nowhere, only `~/Documents/Calls` | always |
| Voice prints (your sample and the people you named) | nowhere, `~/Library/Application Support/Sozvon/voices` | once you record a sample or name a speaker |
| Which app is using the microphone (for the call prompt; only the app, never the audio) | nowhere, read on the Mac | while "Offer to record when a call starts" is on |
| The meeting at the time of a recording (title, attendees) for the call form | nowhere, read from Calendar on the Mac | after each recording, unless turned off in Settings |
| Tasks and notes you send to Reminders | nowhere, the Reminders app on this Mac (if Reminders syncs through iCloud, Apple syncs them further) | only when you press To Reminders |
| Python environment, models | PyPI, huggingface.co | once, during setup |
| uv binary (if missing), CPython for `uv sync`, fallback archive of the speaker separation models (release `models-v1`) | github.com | once, during setup |
| Transcript text for the summary and speaker names | Anthropic (Claude Code), OpenAI (Codex) or Cursor and the model chosen in it | only if an assistant is selected |
| Whatever the assistant reads through MCP | Anthropic, OpenAI or Cursor | only when you ask it |
| Project discovery: project folder names, memory notes in `~/.claude` (or sessions in `~/.codex`, or past chats in `~/.cursor/projects`), replies of open sessions. Claude is limited to reading inside `~/.claude`. Codex runs in a `read-only` sandbox: it blocks writes but not reads, and the model itself decides what it reads. Cursor runs in read-only ask mode, and its limit to those folders is also only an instruction | Anthropic, OpenAI or Cursor | only when you click Find Projects |
| Updates | github.com: the latest release's appcast.xml, and the new DMG when there is one | once a day; automatic install can be turned off in Settings > About |
| Transcripts, summaries, notes and call details, so Claude or ChatGPT can answer from your phone | your own server in your own Cloudflare account, never us ([how it works](docs/SERVER.md)) | only if you set one up |
| Call audio, so a new Mac can play your calls (never shown to Claude or ChatGPT) | your own server in your own Cloudflare account | only with your own server and Send call audio on (the default) |
| Voice prints, so your other Macs recognize the same voices (never shown to Claude or ChatGPT) | your own server in your own Cloudflare account | only with your own server and Send voice prints on (the default) |
| Cloudflare sign-in and setup: creating the database, the sign-in storage and the Worker in your account | dash.cloudflare.com, api.cloudflare.com | only when you press Connect Cloudflare or Update server |

No telemetry and no servers of our own. Choose "Local only", skip the own server, and nothing except the update check leaves your Mac. Every commit is checked by [Gitleaks](https://github.com/gitleaks/gitleaks), [Semgrep](https://semgrep.dev) and [CodeQL](https://codeql.github.com).

## How it works

```
Package.swift       SwiftPM: SozvonCore (logic, covered by tests) + Sozvon (the app)
Sources/SozvonCore/ recording state, transcription queue, engine launcher, call.json, settings
Sources/Sozvon/     menu bar, recording (Core Audio process tap, ScreenCaptureKit), panel, SwiftUI windows, MCP server
Tests/              XCTest for SozvonCore
engine/
  sozvon_engine/    engine: recognition, pyannote, languages, vocabularies, projects, summary, MCP
  bin/              process_call.py (full pipeline), discover_projects.py (project discovery), sync_server.py (own server sync), voice.py (voice prints)
  server.py         MCP server (stdio or shared HTTP)
  models.json       models with pinned revisions
  setup.sh          installs the engine into ~/Library/Application Support/Sozvon
server/             optional own server: Cloudflare Worker + D1 + KV, MCP for Claude and ChatGPT connectors, sync API
docs/               website (GitHub Pages), CONTRACT.md (app and engine contract), SIGNING.md, SERVER.md
build.sh            builds the .app and .dmg, signing, notarization
```

After Stop: tracks are aligned → a very quiet track is raised and the other side's echo is removed from the microphone → recognition with hints from the project → speaker separation → names from saved voice prints, then from context → `transcript.md`, `summary.md`.

## Building and testing

```bash
git clone https://github.com/Able1991/sozvon && cd sozvon
./test.sh              # Python, localization, the own server (with Node.js 22+), Swift
SLOW=1 ./test.sh       # plus end-to-end tests with real Whisper
./build.sh install     # ~/Applications/Sozvon.app
./build.sh dmg         # build/Sozvon.dmg
```

Requires Xcode Command Line Tools and [uv](https://docs.astral.sh/uv/). Optional: Node.js 22 or later, to bundle the server into the app for Connect Cloudflare (without it the app builds, and the button says it is unavailable) and to run the server tests (`./test.sh` skips them without it; in CI they are required). Signing and releases: [docs/SIGNING.md](docs/SIGNING.md).

## License

MIT. Models: Whisper (MIT), pyannote (MIT, CC BY 4.0), GigaAM (MIT), Parakeet (CC BY 4.0).
