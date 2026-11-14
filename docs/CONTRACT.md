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
| Assistant calls | `<data>/assistant.log`: one line per call of Claude Code, Codex or Cursor CLI (time, command with the request masked as `<request>`, exit code, seconds, the end of stderr on a failure); cut to its newer half past 1 MB; goes into the diagnostics zip | the engine (`llm.py`) |
| Last project discovery reply | `<data>/profiles/.discover-last.txt` (raw assistant text, for debugging; overwritten on every discovery run) | `bin/discover_projects.py` |
| Shared vocabulary | `<data>/vocab.json` | the engine, MCP, the app (a replacement remembered in the Calls window) |
| Call search index | `<data>/index.db` (SQLite FTS5, mode 600) + `index.db.lock`; a cache synced with the calls folder before each search and rebuilt when broken or of another schema version, safe to delete | MCP (`search_calls`) |
| Calls deleted in Sozvon, to delete on the own server | `<data>/server-deleted.json` + `server-deleted.json.lock` (below) | the app adds, `bin/sync_server.py` removes |
| Calls put back in Sozvon, to restore on the own server | `<data>/server-restore.json` + `server-restore.json.lock` (below) | the app adds, `bin/sync_server.py` removes |
| Calls this Mac removed because the server deleted them | `<data>/server-trashed.json` | `bin/sync_server.py` only |
| Project title this Mac last sent to the own server, per call | `<data>/server-titles.json` (below) | `bin/sync_server.py` only |
| sha256 of local tracks, to compare with the own server's audio | `<data>/server-audio.json` (a cache, safe to delete) | `bin/sync_server.py` only |
| Voice prints | `<data>/voices/<id>.json` (mode 600, folder mode 700) + `voices/.lock` (section 6) | `bin/voice.py`, `bin/sync_server.py` |
| Voice prints deleted here, to delete on the own server | `<data>/voices-deleted.json` (section 6) | `bin/voice.py` adds, `bin/sync_server.py` removes |
| Calls (`SOZVON_CALLS_DIR`) | `~/Documents/Calls/<id>[ · project · topic · people]/`, or the folder chosen in the app (defaults key `callsDir`) | the app and the engine |

Engine state markers in `<data>`: `.engine-version` (version of the copied code),
`.venv-lock` (hash of the `uv.lock` the environment was built for), `.installed` (install time),
`.no-diarization` (the speaker separation models failed to install), `.no-echo-model` (the last echo model download failed; `install.py` writes it, the first call that runs without the model reports it in `warnings` and removes it), `.mcp-token` (MCP token, mode 600).

## 2. Environment variables

The app sets them on every engine launch. The engine reads `.env` in the data folder as
defaults; environment variables take precedence over `.env`.

| Variable | Value | Set by |
|---|---|---|
| `SOZVON_DATA_DIR` | engine data folder | the app |
| `SOZVON_CALLS_DIR` | calls folder | the app |
| `SOZVON_UI_LANG` | `ru` or `en`: language of engine messages and transcript files | the app |
| `SOZVON_THREADS` | thread limit on performance cores ("Transcribe at low priority" setting) | the app |
| `SOZVON_MCP_PORT`, `SOZVON_MCP_TOKEN` | port and token of the shared MCP server | the app |
| `SOZVON_PYANNOTE_TAR` | path to the speaker separation model archive in the bundle | the app (for `setup.sh`) |
| `SOZVON_PYANNOTE_URL`, `SOZVON_PYANNOTE_SHA` | alternative URL and SHA-256 of the speaker separation model archive (for development) | nobody by default |
| `SOZVON_AEC` | `0`: skip the echo cancellation of the microphone (the system track is the reference for removing the other side's voices that the mic picked up from the speakers; the original `mic.m4a` is never changed). Manual, for debugging | nobody by default |
| `SOZVON_NEURAL_AEC` | `0`: skip the neural echo suppressor that runs next to the classic canceller (`sozvon_engine/aec_neural.py`, LocalVQE v1.2, Apache-2.0, weights in `models.json` key `aec`; it hears the raised mic, not the classic output); the classic output is used. It is also skipped when the weights are missing or corrupt, or on any error, with one line in `process.log` and a `warnings` entry for failures. Manual, for debugging | nobody by default |

`.env` keys (written by the app from its settings, `SOZVON_ENV_VERSION=1`; the app keeps keys it does not manage,
the ones marked "manual" below):

| Key | Values |
|---|---|
| `SOZVON_ME` | how to label the user |
| `SOZVON_LLM` | `claude`, `codex`, `cursor`, `none`, `auto` (the first installed of `claude`, `codex`, `cursor-agent`) |
| `SOZVON_SUMMARY_MODEL` | Claude model for summaries, speaker naming and project discovery (default `sonnet`). Manual |
| `SOZVON_SUMMARY_LANGUAGE` | Language of the summary: `ru`, `en`, `uk`, `de`, `es`; `auto` or absent: the conversation's |
| `SOZVON_LANGUAGE` | call languages: `ru`, `ru,en`, `auto` |
| `SOZVON_LANG_SWITCH` | `1`: detect the language of each phrase |
| `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`, `HF_ENDPOINT`, `UV_DEFAULT_INDEX`, `PIP_INDEX_URL`, `UV_PYTHON`, `UV_PYTHON_INSTALL_MIRROR`, `SOZVON_SYSTEM_CERTS` | corporate network, see the docs section "Corporate network". Only these keys are taken from `.env` by `setup.sh` and exported by `runtime.prepare()`; the environment wins. By default `setup.sh` runs uv with `UV_SYSTEM_CERTS=1` and the engine injects `truststore` (macOS Keychain); a certificate file or `SOZVON_SYSTEM_CERTS=0` turns that off in the engine. With a package index (also `index-url` from `pip.conf`) `setup.sh` installs the locked versions from `uv export` with hashes instead of `uv sync --frozen`. Manual |
| `SOZVON_MODEL` | key from `models.json`: `turbo`, `large-v3`, `small`, `gigaam`, `parakeet` |
| `SOZVON_MODEL_RU` | optional model for Russian tracks: `gigaam` or `parakeet`, used only when `SOZVON_MODEL` is a Whisper model (it detects each track's language; Russian tracks go to this one). Empty: everything on `SOZVON_MODEL` |
| `SOZVON_SMART_NAMES` | `0`: do not name speakers through the assistant. Manual. The assistant names speakers only for a call with `summary` on (`call.json`): with it off the text never leaves the Mac, and the typed names go to the voices in order of appearance |
| `SOZVON_CODEX_MODEL` | Codex model (`codex exec -m`); empty: the default model from the Codex settings. Manual |
| `SOZVON_DISCOVER_ASK` | `1`: project discovery with Claude may also list and message the open Claude Code sessions (`ListAgents`, `SendMessage`). Off by default: what discovery reads in `~/.claude` holds text from other people, and those tools reach sessions that may be allowed more. Manual |
| `SOZVON_CURSOR_MODEL` | Cursor model (`cursor-agent --model`); empty: the default model from the Cursor settings. Manual |
| `HF_TOKEN` | Hugging Face token: higher download limits when many people download from one address (the speaker separation models ship with the app and need none). Manual |
| `SOZVON_SERVER_URL` | address of the user's own server (`docs/SERVER.md`), `https://` only (`http://` only for `localhost` and `127.0.0.1`, for testing). Empty: no server |
| `SOZVON_SERVER_PASSWORD` | password of the own server, sent as `Authorization: Bearer <password>`; never logged |
| `SOZVON_SYNC_AUDIO` | `1` (default when absent) or `0`: sync call audio (`mic.m4a`, `system.m4a`) with the own server. With `0` sync neither uploads nor downloads audio; the server copy of audio the app removed (`audio_removed_at`) is still deleted |
| `SOZVON_SYNC_VOICES` | `1` or `0` (default when absent: voice prints are biometric data, so sending them is opt-in): sync voice prints with the own server. The app writes `1` only with an own server set up and the toggle turned on. With `0` sync neither uploads nor downloads voice records; deletions made on this Mac are still sent, so a deleted voice is deleted on the server too |

## 3. Command line

`bin/process_call.py <call folder>` transcribes a call. Everything about the call comes from `call.json`;
the arguments below only override its fields (for manual runs and tests):
`--profile`, `--names`, `--topic`, `--terms`, `--language`, `--speakers`, `--switch`,
`--no-diarize`, `--no-summary`, `--me`.

**How many voices to expect.** Without `--speakers` (or `speakers` in `call.json`), diarization is told the larger of
the typed `names` (without the user and generic labels) and the voices of the call's current `transcript.txt` (a
transcription again): each distinct label that names a person or is a numbered generic label (`Собеседник 2`,
`Speaker 3`). The plain `Собеседник`/`Speaker` (a run without diarization, or a phrase no voice matched), the user
and `<me> + собеседники` / `<me> + others` are not counted; when nothing is left the count is open.

`bin/sync_server.py` syncs the calls folder with the own server ([SERVER.md](SERVER.md), "Sync protocol"), in this order:

1. **Deletions.** It deletes on the server only the calls listed in `<data>/server-deleted.json`, then drops them
   from the list; an id whose folder is back with its `call.json` (restored from the Trash) is dropped without deleting. A server call
   is never deleted just because it has no folder here.
2. **Restores.** Calls listed in `<data>/server-restore.json` (put back in Sozvon) are sent with `"restore": true`,
   which clears the server's call tombstone, then dropped from the list; an id with no folder here is dropped,
   one that is not finished yet waits for the next sync.
3. **Calls deleted on another Mac.** A call in the server's `deleted` list is never uploaded. Its
   folder here is moved to the macOS Trash (`NSFileManager.trashItem`, so Put Back works; a plain move to
   `~/.Trash` if that fails), except while it is `recorded` or `processing`, has no `call.json` yet, or has a `call.json` without a status
   and without `transcript.txt` (the next sync). The ids this Mac removed for a tombstone (deleted here or moved to the Trash by sync) are kept in
   `<data>/server-trashed.json`; such a folder that shows up again was put back from the Finder Trash: it stays
   on this Mac only, with one `STATUS:` line per id.
4. **Downloads.** A server call with no folder here and not in that list is downloaded: a folder with the server's
   folder name (control and separator characters, Unicode Cc, Cs, Zl and Zp, and leading dots dropped, `/`, `\` and
   `:` turned into `-`; it must start with the id, otherwise the id alone; never replacing an existing folder),
   `call.json` with the whitelisted fields below (a `status` set to `done`), `transcript.txt`, `transcript.md` rendered
   from it, `summary.md` if any, and the notes. No audio: the app shows such a call without "Transcribe Again".
   This is how a fresh install restores everything. The folder is assembled under a hidden `.restore-*` name
   and renamed into place.
5. **Notes.** Notes the server has and the call lacks are added to `call.json`, server tombstones remove notes
   here, local notes the server lacks are sent, local tombstones are sent as note deletions. Both sides keep the newest 200 notes per call by (`at`, `id`).
6. **Uploads.** Finished calls (`status: done` with `transcript.txt`) whose content hash differs from the
   server's are sent. The payload's `call` is a whitelist of `call.json`: `schema`, `id`, `created_at`, `status`,
   `profile`, `names`, `participants`, `topic`, `languages`, `summary`, plus `audio: {mic_seconds, system_seconds}`; never `terms`,
   `engine`, `info_pending`, track start times or notes. The hash covers `{call, transcript, summary}`, without the
   folder name and without notes: neither a note nor a folder rename resends the whole call. The payload also
   carries `project_title`, the title from `profiles/<slug>.json` when this Mac has the project; it is outside the
   hash. A call is resent for its title only when this Mac's non-empty title changed since it last sent one
   (`<data>/server-titles.json`), or the first time, when it differs from the one the server lists.
   A downloaded call uses that title in its `transcript.md` when this Mac lacks the project. After the update
   to this hash every call is uploaded once more.

7. **Audio** (after the text). Removal is a fact on the server: `DELETE /api/calls/{id}/audio`
   deletes the call's audio there and marks the call (`audio_removed_at`, listed by `GET /api/calls` and
   `GET /api/calls/{id}/audio`); chunk uploads and commits for a marked call answer `410`. For each call the server
   has: one it marks removed is left alone, nothing is uploaded or downloaded and the tracks on this Mac stay (its own
   retention setting decides). A call with `audio_removed_at` here (the app removed its tracks after N days) and no
   mark on the server never uploads or downloads audio, and sync sends the `DELETE` once (also when the server holds
   no audio for it, so no other Mac uploads its copy later). Otherwise, with `SOZVON_SYNC_AUDIO` on: a finished
   call's `mic.m4a` and `system.m4a` whose sha256 differs from the one the server lists are uploaded in chunks of
   1,900,000 bytes (read one chunk at a time, never the whole file), then committed with the track's start offset
   (`"start"`: `audio.mic_start` / `audio.system_start` minus the smaller of the two, in seconds, so 0 for the
   earlier track; left out when unknown); an interrupted upload resumes from the chunks the server already staged.
   A call with no local tracks whose audio the server has (a call restored on a new Mac) gets its tracks downloaded
   chunk by chunk into a hidden `.download-*.m4a` in its folder (leftovers older than 15 minutes from an
   interrupted download are removed first), checked against the size and sha256, and renamed to `mic.m4a` /
   `system.m4a`; `audio.mic_seconds` / `audio.system_seconds` are added to `call.json` when missing, and
   `audio.mic_start` / `audio.system_start` (the server's offsets) when `call.json` has no start times at all
   (absolute host times are meaningless on another Mac; offsets are what the engine and the player use). The text
   hash never includes them. A call whose
   audio request fails counts in `failed`, like its text, and the rest goes on. A `507` (the server's audio storage
   is full) stops audio uploads for this sync with one line `STATUS: Бесплатное место для аудио на своём сервере
   закончилось: ...`; downloads and text are not affected. The counts are a `STATUS: Аудио: ...` line, only when
   something changed. Local track hashes are cached in `<data>/server-audio.json` by call id, track, size and mtime.
8. **Voice prints** (after the calls; section 6). Deletions made here (`<data>/voices-deleted.json`)
   are sent as `DELETE /api/voices/{id}` and dropped from the list, always, even with `SOZVON_SYNC_VOICES=0`. With
   voice sync on (`SOZVON_SYNC_VOICES=1`, off by default): a server tombstone deletes the record here unless the record here changed later; a server record
   missing here, or newer than the one here (by `updated_at`), is downloaded, never over a newer local one; a record
   the server lacks, or holds older with another content hash, is uploaded. When the server answers that upload with
   `409` (another Mac changed the same record after this one, with another print), the two prints are merged (as in
   section 6, the server's name and flags, a time newer than both), stored here and sent once more. A server
   tombstone is checked again under the voices lock before the record here is deleted. When a downloaded record has the same
   (`name`, `profile`) as another record here, or both are `"me": true`, it is merged into the one here (weighted as
   in section 6) and its id is deleted on the server, so every Mac ends up with one record. The counts are a
   `STATUS: Образцы голосов: отправлено N, скачано N, удалено N` line, only when something changed; a failure is a
   `STATUS:` line too. Neither changes the `RESULT` line or the exit code.

A failed request for one call (`413`, `5xx`, a timeout) does not stop the sync: a line `STATUS: Не получилось с
<id>: <reason>. Повторю при следующей синхронизации`, the call counts as failed, and the rest goes on. A wrong
password, or 3 calls in a row with no answer at all, stops the sync.

A missing calls folder (unmounted, moved) stops the sync before anything happens. Only the whitelisted `call.json` fields,
`transcript.txt`, `summary.md`, the notes and the project title are sent, plus, with `SOZVON_SYNC_AUDIO` on,
the tracks (step 7). After a successful transcription
`bin/process_call.py` also sends that call's text (never its tracks); a failure there is only a warning in the log (for a call deleted on
another Mac, `410`, the log says it stays on this Mac only). The app then starts a full sync in the background, which
uploads the tracks (resumable).

`<data>/server-deleted.json`, written by the app when the user moves a call to the Trash while a server is set up,
and changed by anyone only under `flock` on `server-deleted.json.lock`:

```json
{"schema": 1, "calls": [{"id": "2026-11-04 15-01", "at": "2026-11-05T10:00:00Z"}]}
```

Undo (the call is put back from the Trash) removes its id and, while a server is set up, adds it to
`<data>/server-restore.json` in the same format and under `server-restore.json.lock`:

```json
{"schema": 1, "calls": [{"id": "2026-11-04 15-01", "at": "2026-11-05T10:01:00Z"}]}
```

`<data>/server-trashed.json` (the engine's own, same shape, entries may carry `"kept": true` once the
put-back call was logged) is not read by the app. Neither is `<data>/server-titles.json`, the project title this
Mac last sent per call (ids of calls no longer here are dropped):

```json
{"schema": 1, "titles": {"2026-11-04 15-01": "Acme Corp"}}
```

`bin/voice.py` enrolls, lists and deletes voice prints (section 6).

`bin/check_assistant.py claude|codex|cursor` sends a one-word request through the very command a summary uses.

`bin/discover_projects.py` discovers projects. `server.py` runs MCP over stdio, `server.py --http`
runs the shared server on `127.0.0.1:$SOZVON_MCP_PORT` with a bearer token. `models.py <data> <model>` downloads a model.
`install.py <data>` (called by `setup.sh` after `uv sync`) installs the model from `SOZVON_MODEL` (and `SOZVON_MODEL_RU` when it applies),
the speaker separation models and the `.venv-lock`, `.installed`, `.no-diarization` markers; progress lines
start with `==> `.

## 4. Call folder

```
2026-11-04 15-01 · Acme · launch · Anna/
  mic.m4a, system.m4a     tracks (AAC); an imported recording has system.m4a only
  call.json               metadata (below), the source of truth
  meta.json               old calls: track offsets (no longer written by the app, read by the engine if call.json has no audio)
  transcript.md / .txt    transcript
  summary.md              summary (if any)
  process.log             transcription log
  mic.clean.m4a           the microphone raised and freed of echo (classic canceller; while the far end plays and for its echo tail, the neural suppressor's output instead), if that helped (kept)
  listen.m4a              the levelled listening file, made by the engine at the end of a run (below); never read by transcription, diarization or voice prints, not synced
  .work/                  the engine's working files while it runs (wavs, echo cancellation temp); never read or synced
```

`.work` is removed by the engine when a run ends, fails or gets SIGTERM (the handler exits through the `finally`
blocks, exit code 143); a run also clears a stale one before it starts. A hard kill (the engine's own watchdog when the
app dies, `SIGKILL`) leaves it, so the app removes `.work` from every call folder at launch, except the calls in the
restored queue and calls with `status: processing`. The Calls list, the folder size and the sync ignore it.

**listen.m4a** (optional) is the call as the player hears it: one AAC mono track at 48 kHz, about 72 kbit/s (30 to 36 MB per hour),
aligned to the call's start, as long as the call. Each track is levelled on its own (the gain from the 16 kHz working wav,
applied to the full band of the original track at its offset, with the boost its working wav got; a mic whose echo was removed
on this run exists only as the cleaned 16 kHz working wav, which is resampled up), the tracks are added, a limiter holds the sum
at -1.5 dBFS before encoding (AAC can go slightly over it). A very quiet track is raised first, by up to 30 dB as in its working
wav, so it can end up more than the 6 dB levelling limit above the recording. The engine writes the file last, after the transcript and
summary and after `status: done`, which takes about 2 minutes per hour of call, atomically (a temp file in `.work` renamed into
place), removing an old one first; Transcribe Again makes a new one. The call is complete without it: a failed render or a quit
during it leaves `status: done`. A failure only leaves no file and a log line, with no warning: the player then plays `mic.clean.m4a` or `mic.m4a` and `system.m4a` as before, so older calls are
unchanged. The player prefers it (one track at offset 0) and falls back to the tracks when it is missing, tiny or unreadable.

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
  "info_pending": true,
  "marks": [754.2, 1310.0],
  "audio_removed_at": "2026-12-04T09:00:00Z",
  "audio": {"mic_start": 3764879.93, "system_start": 3764879.64, "mic_seconds": 1755.6, "system_seconds": 1755.8},
  "profile": "acme", "names": ["Anna"], "participants": ["Anna Petrova", "Ivan"], "topic": "launch", "terms": "",
  "languages": "ru,en", "summary": true, "model": "large-v3",
  "engine": {"version": "aad392548a91a7b4", "model": "turbo", "ru_model": "gigaam"},
  "warnings": [{"step": "summary", "error": "claude: rate limit"}],
  "demo": true,
  "queued_at": "2026-11-05T09:12:44.250Z", "queued_summary_only": true, "retries": 1,
  "notes": [{"id": "0b7e0c4e-5f1a-4c3a-9d41-5d2f7f1a0a01", "at": "2026-11-05T09:12:44Z",
             "text": "Anna sends the contract on Friday", "source": "claude-code"}],
  "notes_deleted": ["6f3c9a10-2b7d-4e8f-a1c2-3d4e5f607182"]
}
```

The app creates the file when recording stops (`status: recorded`, `audio`) and adds the answers
from the "What Was the Call About?" window (`profile`, `names`, `topic`, `terms`, `languages`, `summary`, `model`).
`model` is a model chosen for this call by hand: it is used as is, without the Russian model; absent or unknown means
auto (`SOZVON_MODEL` with `SOZVON_MODEL_RU`). Without `languages` the call takes its project's `languages`
(`profiles/<slug>.json`, same format), then `SOZVON_LANGUAGE`; the app fills the call's languages from the project when
the project is picked. `engine.ru_model` is set when Russian tracks went to the Russian model.
The engine sets `processing`, then `done` and `engine` (version from `ENGINE_VERSION` next to `server.py`,
otherwise from `.engine-version`). Fields set by command-line arguments are also written by the engine
to `call.json`: those are the values the call was transcribed with. The engine does not overwrite a corrupted `call.json` (exit code 2).
On error the app sets `failed`.

**Queue.** At most one engine run (transcription or `--summary-only`) goes on at a time; the rest wait first in, first
out, and none starts while a recording is starting, running or being saved, while its live voice match finishes, while a
call app holds the microphone, or during an engine update. Local only, all optional, schema stays 1, sync does not send
them. `queued_at` (ISO 8601, milliseconds written, plain seconds accepted) is set while a call waits and removed when it
starts or is taken out of the queue; `queued_summary_only: true` marks a waiting summary run. At launch the calls with
`queued_at` go back in the queue in that order. A call found with `status: processing` was interrupted by a crash: it
goes first, as `recorded` with `retries` raised by one, at most `retries: 1`; found again with `retries: 1`, it is set to
`failed`. A run that ended by itself or a new request from the user removes `retries`. Quitting the app from the app
sets the running call to `failed` as before and leaves the waiting ones queued. So that recovery can never put two engines
on one folder, `process_call.py` holds an exclusive `flock` on the call folder for the whole run (a second run waits for it,
and the lock goes away with the process however it ends), and exits with its workers within two seconds of its parent going away.

**Warnings.** `warnings` (optional, schema stays 1) lists the steps that failed on the engine's last run although the
call is `done`: `[{"step": "summary" | "names" | "echo", "error": "<one line, no transcript text>"}]`. `summary` is a failed
summary (full run or `--summary-only`), `names` a failed speaker naming by the assistant (the names fall back to the
order of appearance), `echo` the neural echo suppressor not delivering: a failure, a damaged model file, or (reported
once) a model whose download failed; the classic output is used and the app shows nothing for this step. A summary turned off or no assistant set up is not a warning. The engine writes the field under
the call lock at the end of a run that had failures, and removes it at the end of a run (full or `--summary-only`) that
had none; a `--summary-only` run that fails writes its warning too. The app, on finishing a call with a `summary`
warning, notifies "Готово, но саммари не получилось" with a button that runs the Update Summary path again, and the
Calls row shows a mark. Local only: sync does not send the field.

**Demo calls.** `demo: true` (optional, schema stays 1) marks the fictional calls Settings > Assistants > Demo Calls
adds: text only, no audio, no project and no voice print. The app's "Remove" moves only calls with this exact value to
the Trash; the Calls list shows a "Демо" mark. MCP lists and searches them like any call. Sync skips them entirely
(no upload of the call, its notes or audio, no deletion, no overwrite from the server), so the field is not in
`CALL_FIELDS` and no real call's hash changes.

**Project title of a restored call.** Projects are per Mac. A call restored from the own server whose project this
Mac doesn't have gets `project_title` (optional, schema stays 1): the title the server sent. The app shows it
instead of the slug and offers it in the Calls window's project filter. Local only: it is not among the fields
sync sends.

**Participants.** `names` holds only what the user typed (the people on the call besides the user): the app writes
it from the "What Was the Call About?" window (and a speaker rename or swap changes a typed name), nothing derives
it, and the engine reads it as certain (the voices' names, "definitely on the call" for the assistant).
`participants` (optional, schema stays 1) is the derived list, never read back as typed: the engine writes it with
`done` from the transcript it wrote, and after `--summary-only` from `transcript.txt`; the app recomputes it after a
user edit of the transcript (rename, swap, merge, a line given to someone else), never on simply opening a call. It
is every speaker label that names a person (a voice print, the assistant, a typed name), in the order they first
speak, then the typed names that never spoke, in their order, so a person left without lines after an edit is gone. Each name once, ignoring
case. Never the user (`SOZVON_ME` or `--me`, also `Я`/`Me`) and never a generic label: `Собеседник`, `Speaker`,
`Спикер` with an optional number, `?` or `N`, and `<me> + собеседники` / `<me> + others` (the app's
`Voices.isGenericLabel` is the same rule). A typed single first name that is the first word of exactly one speaking
name (`Anna` and `Anna Petrova`) is that person and is not listed twice. The engine's `names.participants` and the
app's `CallParticipants.derived` are the one rule, tested against the same cases (`Tests/Fixtures/participants.json`).
The summary prompt ("Other participants"), the Calls window (header, list, search), the folder name, MCP
`list_calls`, sync and the own server use `participants`, falling back to `names` for a call without it (the
Calls window then derives the list in memory from the transcript it shows, without writing `call.json`).

Writes are atomic: a temporary file and a rename. Every read-modify-write of `call.json`, by the app and by
the engine, runs under `flock` on the sibling `call.json.lock` (the same convention as below).

**Waiting for a description** (`info_pending`, optional, schema stays 1): `true` when the user chose "Later" in
the "What Was the Call About?" window (after a recording or an import); the field is absent otherwise (never `false`).
The app sets it on "Later" (or when that window is closed), writing the answers typed so far, and removes it when the call is sent to transcription or the user chooses
"Don't Transcribe". A call is waiting only while `info_pending` is `true` and `status` is `recorded`, so a call
transcribed another way (MCP) is not waiting even if the flag stayed. The engine and sync ignore the field and
keep it as is.

**Important marks** (`marks`, optional, schema stays 1): moments the user marked "important" during the recording
(the star on the panel, the menu or ⌃⌥I), in seconds on the transcript timeline (from the earlier track's start,
the same t0 as `tracks.delays`), sorted, at least 5 s apart. The app writes them when the recording stops. The engine
ends each paragraph spoken at a mark (or, in a pause, the last one before it) with ` ⭐` in `transcript.md` only
(`transcript.txt` and the `[MM:SS] Name: text` format stay as they are), shows those lines with a leading ⭐ to the
summary assistant and adds a "Key Moments" section to the summary. Sync does not send the field.

**Audio removed** (`audio_removed_at`, optional): "Delete audio automatically" in Settings removed `mic.m4a`,
`system.m4a` (and `mic.clean.m4a`, `listen.m4a`) of this finished call (status `done` with `transcript.txt`, `created_at` older than the chosen 7, 15,
30 or 60 days; never a call being recorded, queued or transcribed). Transcript, summary and notes stay; the call
has no player and no "Transcribe Again". The app checks a minute after launch and every 6 hours, and asks before
removing anything right after the setting changes.

**Imported recordings.** "Import Recording…" in the Calls window (or a file dropped on the list) creates a new
folder like a recording does, with the id from the minute of the recording date written in the file's metadata (a plausible creation date),
otherwise the file's creation date, otherwise its modification date, and `created_at` at that date. `webm`, `ogg`,
`opus`, `oga` and `mkv` are refused with a hint to convert to m4a, mp3 or wav. The audio is converted to AAC in a hidden `.import-<uuid>.m4a` in that folder
and renamed to `system.m4a` when complete, so the engine never sees half a track. Then `call.json` gets
`status: recorded` and `audio: {"system_start": 0, "system_seconds": <duration>}` with no `mic_*` keys, and the
usual answers. The engine treats it as a call with one track (the system track, every voice separated by
diarization). If the conversion fails, the app removes the partial track and the folder, unless something else is in it.

**Transcript edits.** The app may rewrite `transcript.md` and `transcript.txt` of a call that is not being
recorded, imported or transcribed: renaming a speaker (every `Name:` label, the participant list in the
`transcript.md` header, a typed name in `names` in `call.json` under its lock, then `participants` recomputed),
giving one line to another speaker (then `participants` recomputed) or replacing a word or phrase in one line. Each
file is written atomically; `summary.md` is not regenerated. The new contents change the sync hash, so the call is
sent to the own server again. The engine treats an edited transcript like its own (a new transcription overwrites
the edits).

**Notes** (optional, schema stays 1): comments on the call, oldest first. `id` is a UUID (1 to 64 letters, digits
or dashes), `at` the UTC time in ISO 8601, `text` 1 to 4000 characters (code points), `source` who added it
(`claude-code`, `codex`, `cursor`, `claude`, `chatgpt`, `app`, another short MCP client name, or `assistant`). At most 200
notes per call. Notes are append-only: nobody edits one. Added by the MCP tool `add_note`, by the Calls window and
by sync (notes from the own server). `add_note` and the engine's note writes fail on a call that is gone (moved to the Trash meanwhile) and never
recreate its folder. The app or the MCP tool `delete_note` deletes a note: it leaves the list and its id goes to
`notes_deleted`, a tombstone that sync sends to the server and that keeps any copy from bringing the note back.
Invalid entries are ignored by readers and dropped on the next write.

Projects `profiles/<slug>.json` and the vocabulary `vocab.json` also carry `"schema": 1`. A project name
is `[a-z0-9_-]{1,64}` only.
The engine and MCP modify them (read, modify, write) under `flock` on a sibling file
`<file>.lock` (`profiles/<slug>.json.lock`, `vocab.json.lock`); anything that writes these files takes the same lock.
The app does too when "Fix Word…" in the Calls window is remembered: it sets one `["wrong", "right"]` pair in
`replacements` of the call's project (only an existing `profiles/<slug>.json`) or, for a call without a project, of
`vocab.json` (created with `"schema": 1` if missing), with the engine's rule: an entry with the same left side,
ignoring case, gets the new right side, later duplicates are dropped, otherwise the pair is appended.

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
`bin/voice.py` uses the same codes: 2 invalid input or not enough speech, 3 engine broken, 4 the voice print model is
missing, 5 ffmpeg could not read the audio, 1 other.
Code 3 also covers: `ffmpeg` not found in the environment. The transcript is written before the summary: a failure of the summary or
speaker naming does not change exit code 0.

The last output line of `bin/process_call.py`: `RESULT: ok` or `RESULT: error <code> <message>`.
`bin/discover_projects.py` prints intermediate `STATUS: <text>` lines.
`bin/check_assistant.py` ends with `RESULT: ok <answer>` or `RESULT: error <message>`; exit 0 when the assistant
answered, 1 when it did not (the message is its error: not installed, not logged in, no sandbox...), 2 for a wrong argument.
`bin/sync_server.py` prints `STATUS: <text>` lines and ends with `RESULT: ok <sent> <deleted> <downloaded> <trashed> <failed>`
(calls sent or with notes sent, calls deleted on the server, calls downloaded, calls moved to the Trash because
they were deleted on another Mac, calls a request failed for; the app also accepts the older lines with 2 to 4
numbers and shows "Не отправились: N" when `failed` is above 0) or `RESULT: error <code> <message>`; exit codes:
0 done, 1 done but some calls failed (`failed` above 0), 2 no server configured, invalid address,
password not accepted or no calls folder, 1 other error (network, server). No retries: the next sync catches up.
Messages are in the `SOZVON_UI_LANG` language.

## 6. Voice prints

A voice print lets the engine name a voice it has heard before, instead of guessing from the conversation (two
people called Alexander are no longer confused). **Voice prints are biometric data.** They stay on this Mac unless
the user has set up an own server and turned on Send voice prints (`SOZVON_SYNC_VOICES=1`, off by default); then they sync to the user's own Cloudflare account (their cloud, their
responsibility), never anywhere else, and are never shown to the MCP tools. Deleting a voice deletes it everywhere:
here at once, on the server and on the other Macs at their next sync.

**Record** `<data>/voices/<id>.json`, mode 600, written atomically (temporary file and rename) under `flock` on
`<data>/voices/.lock`; every read-modify-write of the records and of `voices-deleted.json` takes that lock:

```json
{"schema": 1, "id": "<uuid4 hex, 32 lowercase hex characters>", "name": "Александр Бородин",
 "profile": "<project slug or empty>", "me": false, "embedding": [256 floats, L2-normalized],
 "seconds": 42.5, "updated_at": "2026-11-05T10:00:00Z", "model": "wespeaker-voxceleb-resnet34-LM/256"}
```

`model` (optional) names the embedding model and its size; new records get it, and a record without it is of
`wespeaker-voxceleb-resnet34-LM/256`. Vectors of different models are not comparable, so matching (the call
pipeline and live voices), enrollment and every merge (weighted averages, sync conflicts, folding a server
record) use only records of the current model. Records of another model stay untouched on disk, are skipped, and
the log says so once per run; they can still be listed and deleted, and the user's name in one of them still
counts for recognizing the user's label. At a sync conflict between models the record here is kept. Records of
another model are not sent to the own server (it stores no `model`), and `model` is not part of the sync
content hash, so the hash of existing records is unchanged. Readers ignore fields they don't know.

`seconds` is the speech behind the voice print (at most 10,000). Per model, one record per (`name`, `profile`) and at most one
record with `"me": true`, the user's own voice, whose `profile` is `""`; records of different models do not
count against each other, so a name (and a `"me"`) can appear once for each model. An invalid file is ignored by readers.
The embedding is `pyannote/wespeaker-voxceleb-resnet34-LM` (in `<data>/hf-cache`, loaded offline on the CPU,
once per process) over clean speech: energy-based speech detection, the longest pieces first, at most 60 s,
in windows of at most 10 s averaged by length.

`<data>/voices-deleted.json`, ids deleted here that the server may still hold (removed once sync deleted them there):

```json
{"schema": 1, "voices": [{"id": "<voice id>", "at": "2026-11-05T10:00:00Z"}]}
```

**Command line** `bin/voice.py` (log on stderr, last stdout line `RESULT: ok ...` or `RESULT: error <code> <message>`,
messages in the `SOZVON_UI_LANG` language):

- `voice.py enroll --name NAME [--profile SLUG] [--me] [--add] --file AUDIO`: a recording of one person (the user's sample
  in Settings). At least 8 s of speech, otherwise error 2 ("not enough speech for a voice print: 5.0 s, at least
  8 s needed"; the seconds are rounded down). A new recording **replaces** the voice print of that record; with
  `--add` it is merged in instead (one more sample, for example in another language), weighted as below. With `--me` it is the user's own record
  (profile `""`): an existing `"me"` record is updated and renamed to NAME. When another person's record of
  (NAME, `""`) exists, the enrollment is refused with error 2 and a hint to change the name in Settings (folding it
  would lose that person's voice print).
- `voice.py enroll --name NAME [--profile SLUG] [--me] --call DIR --speaker LABEL`: a speaker of a call. The
  paragraphs of `transcript.txt` labeled LABEL (`[MM:SS] Label: text`, a paragraph ends where the next starts, the
  last one 5 s later), except those that overlap another speaker's paragraph; audio from `mic.m4a` when LABEL is
  the user (`SOZVON_ME`, or the default label `Я`/`Me` when it is empty, or `me`) and the call has a mic track,
  otherwise from `system.m4a`; times shifted by the track's offset from `call.json` `audio` (as `tracks.delays`).
  A call with `speaker_tracks` (see below) decides by it for anyone but the user: `"mic"` reads `mic.clean.m4a` when it
  exists (at offset 0) or else `mic.m4a`, `"system"` reads `system.m4a`, and a label that is `"both"` or is not listed
  is refused with error 2 rather than risk a voice print of someone else's voice.
  Only those pieces are decoded. The longest clean pieces up to 60 s, at least 4 s of speech, otherwise error 2.
  The result is **merged** into the existing record of (NAME, SLUG): the average of both embeddings weighted by
  their seconds (each side capped at 300 s), re-normalized; `seconds` adds up.
- Both print `RESULT: ok <id>` (the record's id, the same id when merged).
- `voice.py list [--profile SLUG]`: one JSON object per line, `{"id", "name", "profile", "me", "seconds",
  "updated_at"}` (never the embedding), sorted by name, then `RESULT: ok <count>`. `--profile ""` lists the
  records without a project.
- `voice.py delete --id ID` / `voice.py delete --all`: deletes locally and records tombstones in
  `voices-deleted.json`, then `RESULT: ok <number deleted>`.

**Matching** (`bin/process_call.py`, after diarization of the system track): for every remote voice cluster,
the embedding of its longest clean turns (cut where another voice overlaps, at most 60 s, at least 2 s of speech)
is compared with the records of the call's project, the records without a project and, on a single-track recording
(an import: no mic track), the `"me"` record, labeled with `SOZVON_ME`. A cluster gets a stored name when the cosine
is at least 0.5 and at least 0.1 above its second best name; the best pairs win first, so no two clusters get the
same name. The log says `голос: Собеседник 2 → Александр Бородин (0.83)`. Names given by voice are final: the
names from `call.json` and the assistant only name the remaining voices, and never reuse a name given by voice.
With no stored records nothing is loaded. If embeddings fail (no model, no pyannote) the log says so and the
transcript is exactly what it would be without voice prints.

**The microphone** is normally the user, every line of it. It is split only when speaker separation is available,
the call is not a reflection, the current-model `"me"` record exists, system audio had no gaps (those calls keep their
own microphone separation) and the microphone has at least 15 s of speech. Then the track is diarized once and each
cluster is compared with the `"me"` record (cosine at least 0.5); a cluster that matches is the user. No `"me"` record,
or no cluster matching it: every line stays the user's and the log says so. Another cluster is a separate person only
with at least 15 s of speech, and only if its voice matches no voice of the system track (cosine at least 0.5): that
one is the other side leaking from the speakers. A separate person gets a stored name by the matching rule above
(project and no-project records), or else a generic label numbered after the system track's voices (`Собеседник 3`),
which the assistant can name from the conversation like any other voice. Any failure here is logged and the
microphone stays the user's.

**`speaker_tracks`** (`call.json`, optional, schema stays 1): `{label: "mic" | "system" | "both"}`, one entry per
transcript label, written with `done` only when the microphone holds someone besides the user (a transcription that
finds nobody removes an old one; a call without it enrolls as before). The transcript does not say which track a
paragraph came from, and enrollment needs that. Local only: not among the fields sync sends, not in the content hash.
The app keeps it right on an edit (`TranscriptEdit`): a rename moves the entry, a swap swaps the two, a rename or a
line given to someone who already speaks makes them `"both"` when the tracks differ, and a label with no known track
stays without an entry.

**When the app enrolls:** the user's own sample in Settings (`--file --me`), and a speaker the user names precisely
in a call (rename or swap in the Calls window, `--call --speaker`).


### Live voices

While a call is recorded, and only when a voice print of someone other than the user exists, the app also cuts
the other side's track into one minute pieces, `<call>/.live/system-0001.wav`, `system-0002.wav`, ... (16 kHz mono
32-bit float WAV, written under a temporary name and renamed when complete), and starts
`bin/voice.py live --dir <call>/.live` at utility priority. The engine matches every speech window of every piece
(6 s, at least 1.5 s of speech) against all voice prints except the user's own, with a cosine of at least 0.6 and the
usual margin, deletes the piece, and after every piece writes `<call>/.live/voices.json`:

```json
{"voices": [{"name": "Анна Петрова", "profile": "acme", "seconds": 312.0, "score": 0.81, "unsure": false}], "pieces": 14, "speech": 640.5, "done": false}
```

Only names with at least 6 s of matched speech are listed, longest first. `unsure`: two names have nearly the same
print (cosine of at least 0.75, one voice saved under two names), so the one with more enrolled speech stands in; such
an entry may give the project but neither joins the participants nor makes the guess sure. When the recording stops the app writes
the last piece and an empty `<call>/.live/stop`; the engine finishes the pieces left, writes `"done": true` and exits
(it also exits when the app or the folder is gone). The app waits up to 15 s, reads the list, deletes `<call>/.live/`
and uses the names together with the meeting in the calendar for "What was the call about?" (`CallGuess`): the heard
names join the participants, and the project most of their speech belongs to becomes the call's project when the user
typed nothing and the calendar gave none. The last used project the form starts with counts as nothing typed.
When a project and participants are known and backed by the user, by a meeting going on when the recording started or
by a voice heard for at least 30 s, and the calendar and the voices do not disagree, the form goes ahead by itself
after 10 s; editing it or pressing Wait stops the countdown.

Nothing from `.live` is kept or sent anywhere: a folder left by a crash or a quit is removed at the next launch, and
on quit at once. The transcription names the voices on its own as before.

### Reflections

`"kind": "reflection"` in `call.json` marks the user alone, thinking out loud: a recording marked so in "What was the
call about?" (it starts chosen when no call app held the microphone, the other side's track stayed silent and no
meeting was going on) and every recording from the phone folder. The engine does no speaker separation and names no
voices, labels all speech as the user and writes a summary with the sections Main Point, Analysis, Action Items and
Open Questions (in Russian: Главное, Анализ, Задачи, Открытые вопросы). A call has no `kind` at all, so its `call.json`
and sync hash do not change. `kind` is not synced to the own server yet: on another Mac a reflection looks like a call.
