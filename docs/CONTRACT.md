# App and engine contract

The Sozvon app (Swift) and the engine (Python, `engine/`) communicate only through what is described here:
environment variables, the `.env` settings file, command-line arguments, files in the call folder,
exit codes and protocol lines in the output. Everything else is internal and may change.

Contract version: **1**. A breaking change bumps the version and requires a migration on both sides.

## 1. Folders

| What | Where | Written by |
|---|---|---|
| Engine data (`SOZVON_DATA_DIR`) | `~/Library/Application Support/Sozvon` | the app copies the code, `setup.sh` installs the environment |
| Engine code | `<data>/server.py`, `install.py`, `models.py`, `sozvon_engine/`, `bin/`, `models.json`, `pyproject.toml`, `uv.lock`, `.python-version`, `setup.sh`, `vocab.default.json`, `ENGINE_VERSION` | the app, from the bundle, when `ENGINE_VERSION` changes |
| Python environment | `<data>/.venv` | `setup.sh` (`uv sync --frozen`) |
| Models | `<data>/models/<dir>/` + `.complete` marker | the installer, from `models.json` |
| Projects | `<data>/profiles/<slug>.json` | the app, the engine, MCP |
| Last project discovery reply | `<data>/profiles/.discover-last.txt` (raw assistant text, for debugging; overwritten on every discovery run) | `bin/discover_projects.py` |
| Shared vocabulary | `<data>/vocab.json` | the engine, MCP |
| Calls (`SOZVON_CALLS_DIR`) | `~/Documents/Calls/<id>[ · project · topic · people]/` | the app and the engine |

Engine state markers in `<data>`: `.engine-version` (version of the copied code),
`.venv-lock` (hash of the `uv.lock` the environment was built for), `.installed` (install time),
`.no-diarization` (the speaker separation models failed to install), `.mcp-token` (MCP token, mode 600).

## 2. Environment variables

The app sets them on every engine launch. The engine reads `.env` in the data folder as
defaults; environment variables take precedence over `.env`.

| Variable | Value | Set by |
|---|---|---|
| `SOZVON_DATA_DIR` | engine data folder | the app |
| `SOZVON_CALLS_DIR` | calls folder | the app |
| `SOZVON_UI_LANG` | `ru` or `en`: language of engine messages and transcript files | the app |
| `SOZVON_THREADS` | thread limit on performance cores ("Don't slow down my Mac" mode) | the app |
| `SOZVON_MCP_PORT`, `SOZVON_MCP_TOKEN` | port and token of the shared MCP server | the app |
| `SOZVON_PYANNOTE_TAR` | path to the speaker separation model archive in the bundle | the app (for `setup.sh`) |
| `SOZVON_PYANNOTE_URL`, `SOZVON_PYANNOTE_SHA` | alternative URL and SHA-256 of the speaker separation model archive (for development) | nobody by default |

`.env` keys (written by the app from its settings, `SOZVON_ENV_VERSION=1`):

| Key | Values |
|---|---|
| `SOZVON_ME` | how to label the user |
| `SOZVON_LLM` | `claude`, `codex`, `none`, `auto` |
| `SOZVON_SUMMARY_MODEL` | Claude model for summaries, speaker naming and project discovery (default `sonnet`) |
| `SOZVON_LANGUAGE` | call languages: `ru`, `ru,en`, `auto` |
| `SOZVON_LANG_SWITCH` | `1`: detect the language of each phrase |
| `SOZVON_MODEL` | key from `models.json`: `turbo`, `large-v3`, `small`, `gigaam`, `parakeet` |
| `SOZVON_SMART_NAMES` | `0`: do not name speakers through the assistant |
| `SOZVON_CODEX_MODEL` | Codex model (`codex exec -m`); empty: the default model from the Codex settings. Not written by the app, for manual configuration only |
| `HF_TOKEN` | optional Hugging Face token |

## 3. Command line

`bin/process_call.py <call folder>` transcribes a call. Everything about the call comes from `call.json`;
the arguments below only override its fields (for manual runs and tests):
`--profile`, `--names`, `--topic`, `--terms`, `--language`, `--speakers`, `--switch`,
`--no-diarize`, `--no-summary`, `--me`.

`bin/discover_projects.py` discovers projects. `server.py` runs MCP over stdio, `server.py --http`
runs the shared server on `127.0.0.1:$SOZVON_MCP_PORT` with a bearer token. `models.py <data> <model>` downloads a model.
`install.py <data>` (called by `setup.sh` after `uv sync`) installs the model from `SOZVON_MODEL`,
the speaker separation models and the `.venv-lock`, `.installed`, `.no-diarization` markers; progress lines
start with `==> `.

## 4. Call folder

```
2026-11-04 15-01 · Acme · launch · Anna/
  mic.m4a, system.m4a     tracks (AAC)
  call.json               metadata (below), the source of truth
  meta.json               old calls: track offsets (no longer written by the app, read by the engine if call.json has no audio)
  transcript.md / .txt    transcript
  summary.md              summary (if any)
  process.log             transcription log
```

The folder name is for humans only. The **call id** is the minute the recording started, `2026-11-04 15-01`;
the second and later recordings started in the same minute get a suffix: `2026-11-04 15-01-2`,
`2026-11-04 15-01-3`. The id is always stored in `call.json` (`"id"`), the app writes it as soon as it
creates the folder, and it is authoritative. Parsing the name is needed only for folders without `call.json`: the id is the start of the name
matching `^\d{4}-\d{2}-\d{2} \d{2}-\d{2}(-\d+)?(?= |$)`, for old folders it is the first 16 characters.
The app only creates a new folder (it does not accept an existing one) and, if launch fails, deletes
only its own empty folder. The folder is renamed after a successful transcription; the start of the name (the id)
does not change, so the id is stable (MCP tools look calls up by it).

`call.json`, schema 1:

```json
{
  "schema": 1,
  "id": "2026-11-04 15-01",
  "created_at": "2026-11-04T11:01:13Z",
  "status": "recorded | processing | done | failed",
  "audio": {"mic_start": 3764879.93, "system_start": 3764879.64, "mic_seconds": 1755.6, "system_seconds": 1755.8},
  "profile": "acme", "names": ["Anna"], "topic": "launch", "terms": "",
  "languages": "ru,en", "summary": true,
  "engine": {"version": "aad392548a91a7b4", "model": "turbo"}
}
```

The app creates the file when recording stops (`status: recorded`, `audio`) and adds the answers
from the "What Was the Call About?" window (`profile`, `names`, `topic`, `terms`, `languages`, `summary`).
The engine sets `processing`, then `done` and `engine` (version from `ENGINE_VERSION` next to `server.py`,
otherwise from `.engine-version`). Fields set by command-line arguments are also written by the engine
to `call.json`: those are the values the call was transcribed with. The engine does not overwrite a corrupted `call.json` (exit code 2).
On error the app sets `failed`.
Writes are atomic: a temporary file and a rename.

Projects `profiles/<slug>.json` and the vocabulary `vocab.json` also carry `"schema": 1`. A project name
is `[a-z0-9_-]{1,64}` only.
The engine and MCP modify them (read, modify, write) under `flock` on a sibling file
`<file>.lock` (`profiles/<slug>.json.lock`, `vocab.json.lock`); anything that writes these files takes the same lock.

## 5. Exit codes and output protocol

| Code | Meaning | What the app shows |
|---|---|---|
| 0 | done | open the transcript |
| 2 | no audio on either track / invalid input | "The recording has no sound", check permissions |
| 3 | engine is broken (import, environment) | offer to reinstall the engine |
| 4 | model not downloaded | offer to download the model |
| 5 | ffmpeg could not read the recording | "The recording is damaged" |
| 1 | other error | the log |

Code 2 also covers: missing call folder, corrupted `call.json`, unknown model in `SOZVON_MODEL`.
Code 3 also covers: `ffmpeg` not found in the environment. The transcript is written before the summary: a failure of the summary or
speaker naming does not change exit code 0.

The last output line of `bin/process_call.py`: `RESULT: ok` or `RESULT: error <code> <message>`.
`bin/discover_projects.py` prints intermediate `STATUS: <text>` lines.
Messages are in the `SOZVON_UI_LANG` language.
