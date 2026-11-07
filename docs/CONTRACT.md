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
| Shared vocabulary | `<data>/vocab.json` | the engine, MCP, the app (a replacement remembered in the Calls window) |
| Call search index | `<data>/index.db` (SQLite FTS5, mode 600) + `index.db.lock`; a cache synced with the calls folder before each search and rebuilt when broken or of another schema version, safe to delete | MCP (`search_calls`) |
| Calls deleted in Sozvon, to delete on the own server | `<data>/server-deleted.json` + `server-deleted.json.lock` (below) | the app adds, `bin/sync_server.py` removes |
| Calls put back in Sozvon, to restore on the own server | `<data>/server-restore.json` + `server-restore.json.lock` (below) | the app adds, `bin/sync_server.py` removes |
| Calls this Mac removed because the server deleted them | `<data>/server-trashed.json` | `bin/sync_server.py` only |
| Project title this Mac last sent to the own server, per call | `<data>/server-titles.json` (below) | `bin/sync_server.py` only |
| sha256 of local tracks, to compare with the own server's audio | `<data>/server-audio.json` (a cache, safe to delete) | `bin/sync_server.py` only |
| Voice prints | `<data>/voices/<id>.json` (mode 600, folder mode 700) + `voices/.lock` (section 6) | `bin/voice.py`, `bin/sync_server.py` |
| Voice prints deleted here, to delete on the own server | `<data>/voices-deleted.json` (section 6) | `bin/voice.py` adds, `bin/sync_server.py` removes |
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
| `SOZVON_THREADS` | thread limit on performance cores ("Transcribe at low priority" setting) | the app |
| `SOZVON_MCP_PORT`, `SOZVON_MCP_TOKEN` | port and token of the shared MCP server | the app |
| `SOZVON_PYANNOTE_TAR` | path to the speaker separation model archive in the bundle | the app (for `setup.sh`) |
| `SOZVON_PYANNOTE_URL`, `SOZVON_PYANNOTE_SHA` | alternative URL and SHA-256 of the speaker separation model archive (for development) | nobody by default |
| `SOZVON_AEC` | `0`: skip the echo cancellation of the microphone (the system track is the reference for removing the other side's voices that the mic picked up from the speakers; the original `mic.m4a` is never changed). Manual, for debugging | nobody by default |

`.env` keys (written by the app from its settings, `SOZVON_ENV_VERSION=1`; the app keeps keys it does not manage,
the ones marked "manual" below):

| Key | Values |
|---|---|
| `SOZVON_ME` | how to label the user |
| `SOZVON_LLM` | `claude`, `codex`, `none`, `auto` |
| `SOZVON_SUMMARY_MODEL` | Claude model for summaries, speaker naming and project discovery (default `sonnet`). Manual |
| `SOZVON_LANGUAGE` | call languages: `ru`, `ru,en`, `auto` |
| `SOZVON_LANG_SWITCH` | `1`: detect the language of each phrase |
| `SOZVON_MODEL` | key from `models.json`: `turbo`, `large-v3`, `small`, `gigaam`, `parakeet` |
| `SOZVON_SMART_NAMES` | `0`: do not name speakers through the assistant. Manual. The assistant names speakers only for a call with `summary` on (`call.json`): with it off the text never leaves the Mac, and the typed names go to the voices in order of appearance |
| `SOZVON_CODEX_MODEL` | Codex model (`codex exec -m`); empty: the default model from the Codex settings. Manual |
| `HF_TOKEN` | Hugging Face token: higher download limits when many people download from one address (the speaker separation models ship with the app and need none). Manual |
| `SOZVON_SERVER_URL` | address of the user's own server (`docs/SERVER.md`), `https://` only (`http://` only for `localhost` and `127.0.0.1`, for testing). Empty: no server |
| `SOZVON_SERVER_PASSWORD` | password of the own server, sent as `Authorization: Bearer <password>`; never logged |
| `SOZVON_SYNC_AUDIO` | `1` (default when absent) or `0`: sync call audio (`mic.m4a`, `system.m4a`) with the own server. With `0` sync neither uploads nor downloads audio; the server copy of audio the app removed (`audio_removed_at`) is still deleted |
| `SOZVON_SYNC_VOICES` | `1` (default when absent) or `0`: sync voice prints with the own server. With `0` sync neither uploads nor downloads voice records; deletions made on this Mac are still sent, so a deleted voice is deleted on the server too |

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
   voice sync on: a server tombstone deletes the record here unless the record here changed later; a server record
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

`bin/discover_projects.py` discovers projects. `server.py` runs MCP over stdio, `server.py --http`
runs the shared server on `127.0.0.1:$SOZVON_MCP_PORT` with a bearer token. `models.py <data> <model>` downloads a model.
`install.py <data>` (called by `setup.sh` after `uv sync`) installs the model from `SOZVON_MODEL`,
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
  "info_pending": true,
  "marks": [754.2, 1310.0],
  "audio_removed_at": "2026-12-04T09:00:00Z",
  "audio": {"mic_start": 3764879.93, "system_start": 3764879.64, "mic_seconds": 1755.6, "system_seconds": 1755.8},
  "profile": "acme", "names": ["Anna"], "participants": ["Anna Petrova", "Ivan"], "topic": "launch", "terms": "",
  "languages": "ru,en", "summary": true,
  "engine": {"version": "aad392548a91a7b4", "model": "turbo"},
  "notes": [{"id": "0b7e0c4e-5f1a-4c3a-9d41-5d2f7f1a0a01", "at": "2026-11-05T09:12:44Z",
             "text": "Anna sends the contract on Friday", "source": "claude-code"}],
  "notes_deleted": ["6f3c9a10-2b7d-4e8f-a1c2-3d4e5f607182"]
}
```

The app creates the file when recording stops (`status: recorded`, `audio`) and adds the answers
from the "What Was the Call About?" window (`profile`, `names`, `topic`, `terms`, `languages`, `summary`).
The engine sets `processing`, then `done` and `engine` (version from `ENGINE_VERSION` next to `server.py`,
otherwise from `.engine-version`). Fields set by command-line arguments are also written by the engine
to `call.json`: those are the values the call was transcribed with. The engine does not overwrite a corrupted `call.json` (exit code 2).
On error the app sets `failed`.

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

**Audio removed** (`audio_removed_at`, optional): "Delete audio automatically" in Settings removed `mic.m4a` and
`system.m4a` of this finished call (status `done` with `transcript.txt`, `created_at` older than the chosen 7, 15,
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
(`claude-code`, `codex`, `claude`, `chatgpt`, `app`, another short MCP client name, or `assistant`). At most 200
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
the user has set up an own server; then they sync to the user's own Cloudflare account (their cloud, their
responsibility), never anywhere else, and are never shown to the MCP tools. Deleting a voice deletes it everywhere:
here at once, on the server and on the other Macs at their next sync.

**Record** `<data>/voices/<id>.json`, mode 600, written atomically (temporary file and rename) under `flock` on
`<data>/voices/.lock`; every read-modify-write of the records and of `voices-deleted.json` takes that lock:

```json
{"schema": 1, "id": "<uuid4 hex, 32 lowercase hex characters>", "name": "Александр Бородин",
 "profile": "<project slug or empty>", "me": false, "embedding": [256 floats, L2-normalized],
 "seconds": 42.5, "updated_at": "2026-11-05T10:00:00Z"}
```

`seconds` is the speech behind the voice print (at most 10,000). One record per (`name`, `profile`); at most one
record has `"me": true`, the user's own voice, and its `profile` is `""`. An invalid file is ignored by readers.
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

**When the app enrolls:** the user's own sample in Settings (`--file --me`), and a speaker the user names precisely
in a call (rename or swap in the Calls window, `--call --speaker`).

