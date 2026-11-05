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

- **One button.** A floating panel above all windows (including full-screen Zoom) or a menu bar icon: Record, take the call, Stop. Works with Zoom, Google Meet, Telegram, TrueConf, anything: it captures system audio and the microphone, no virtual audio drivers.
- **Local.** Speech recognition and speaker separation run on Apple silicon. Audio never leaves your Mac.
- **Who said what.** Your voice and the other side are recorded on separate tracks, remote speakers are separated by voice, and the assistant names them from the conversation ("Masha, how are you?").
- **Summary** in the language of the call: a short overview, decisions, action items with owners, open questions. Optional, through Claude Code or Codex on your own subscription.
- **Projects.** People, terms and replacements per client, so recognition spells names and jargon correctly. Projects can be discovered automatically from your Claude Code or Codex sessions.
- **Calls window.** Calls grouped by day, search across everything including transcript text, a card with the summary and transcript.
- **Claude and Codex can read your calls** through MCP: "what did we decide with the client last week?".
- **Multiple languages** in one call, Russian and English UI, light and dark mode.

<p align="center">
<img src="docs/images/en-panel.png" width="300" alt="Floating panel">
&nbsp;
<img src="docs/images/en-menu.png" width="250" alt="Menu">
</p>

## Installation

1. Download `Sozvon.dmg` from [Releases](https://github.com/Able1991/sozvon/releases/latest) and drag Sozvon to Applications. The app is signed and notarized by Apple.
2. Launch it. The setup assistant asks for your name, the language of your calls, a recognition model and an assistant for summaries, then installs the engine: 5-10 minutes, 1-4 GB depending on the model. No tokens or sign-ups.
3. Allow Microphone and Screen & System Audio Recording. Video is not recorded, only audio.

**Requirements:** a Mac with Apple silicon (M1 or later), macOS 15 Sequoia or later. For summaries and project discovery: [Claude Code](https://claude.com/code) or [Codex CLI](https://github.com/openai/codex) installed, optional.

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

Speaker separation: [pyannote](https://github.com/pyannote/pyannote-audio) (31 MB, installed with the app). Switch models in Settings → Recognition. The same tab has "Don't slow down my Mac": transcription yields to other apps.

## Claude Code and Codex (MCP)

Settings → Claude & Codex → Connect. While running, Sozvon keeps one shared MCP server on `127.0.0.1` for all sessions (about 40 MB). The assistant gets these tools:

| Tool | What it does |
|---|---|
| `list_calls` | list calls: date, topic, project, people, duration; filter by any text |
| `get_call` | summary and/or transcript of a call |
| `search_calls` | search a phrase across all transcripts, with timestamps |
| `transcribe` | transcribe any audio or video file |
| `list_profiles`, `add_terms`, `add_replacement` | projects, terms and replacements |

Manual setup and details: [documentation](https://able1991.github.io/sozvon/docs.html#mcp). The server requires the token from `~/Library/Application Support/Sozvon/.mcp-token`.

## What goes online

| What | Where | When |
|---|---|---|
| Recording, transcription, speaker separation | nowhere, only `~/Documents/Calls` | always |
| Python environment, models | PyPI, huggingface.co | once, during setup |
| uv binary (if missing), CPython for `uv sync`, fallback archive of the speaker separation models (release `models-v1`) | github.com | once, during setup |
| Transcript text for the summary and speaker names | Anthropic (Claude Code) or OpenAI (Codex) | only if an assistant is selected |
| Whatever the assistant reads through MCP | Anthropic or OpenAI | only when you ask it |
| Project discovery: project folder names, memory notes in `~/.claude` (or sessions in `~/.codex`), replies of open sessions. Claude is limited to reading inside `~/.claude`. Codex runs in a `read-only` sandbox: it blocks writes but not reads, and the model itself decides what it reads | Anthropic or OpenAI | only when you click Find Projects |
| Update check | api.github.com | once a day, can be turned off |

No telemetry and no servers of our own. Choose "Local only" and nothing except the update check leaves your Mac. Every commit is checked by [Gitleaks](https://github.com/gitleaks/gitleaks), [Semgrep](https://semgrep.dev) and [CodeQL](https://codeql.github.com).

## How it works

```
Package.swift       SwiftPM: SozvonCore (logic, covered by tests) + Sozvon (the app)
Sources/SozvonCore/ recording state, transcription queue, engine launcher, call.json, settings
Sources/Sozvon/     menu bar, recording (ScreenCaptureKit), panel, SwiftUI windows, MCP server
Tests/              XCTest for SozvonCore
engine/
  sozvon_engine/    engine: recognition, pyannote, languages, vocabularies, projects, summary, MCP
  bin/              process_call.py (full pipeline), discover_projects.py (project discovery)
  server.py         MCP server (stdio or shared HTTP)
  models.json       models with pinned revisions
  setup.sh          installs the engine into ~/Library/Application Support/Sozvon
docs/               website (GitHub Pages), CONTRACT.md (app and engine contract), SIGNING.md
build.sh            builds the .app and .dmg, signing, notarization
```

After Stop: tracks are aligned → recognition with hints from the project → the other side's echo is removed from the microphone → speaker separation → names from context → `transcript.md`, `summary.md`.

## Building and testing

```bash
git clone https://github.com/Able1991/sozvon && cd sozvon
./test.sh              # Python, Swift, localization checks
SLOW=1 ./test.sh       # plus end-to-end tests with real Whisper
./build.sh install     # ~/Applications/Sozvon.app
./build.sh dmg         # build/Sozvon.dmg
```

Requires Xcode Command Line Tools and [uv](https://docs.astral.sh/uv/). Signing and releases: [docs/SIGNING.md](docs/SIGNING.md).

## License

MIT. Models: Whisper (MIT), pyannote (MIT, CC BY 4.0), GigaAM (MIT), Parakeet (CC BY 4.0).
