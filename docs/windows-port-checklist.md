# Windows port checklist

What the Mac version handles and the Windows port has to handle the same way, from `CHANGELOG.md`, `docs/CONTRACT.md` and the engine tests. Stage numbers are from the Windows section of `ROADMAP.md`. Numbers and how to run the engine: `docs/windows-stage-1-report.md`.

Status: **done** (checked on a real Windows machine), **synthetic** (a real run, but only on synthetic audio), **tests** (the engine tests pass on Windows, no real run), **not verified**, **stage 2** or **stage 3**.

## Sound and echo

| Case | Status |
|---|---|
| Headphones and a call with no echo: the neural stage does not run, the file does not change | tests, no real run |
| A very quiet microphone raised by up to 30 dB | tests, no real run |
| A mute microphone, a system track with gaps (`dead_spans`) | tests; a system track with a 68 s gap is synthetic, a mute microphone has no real run |
| Jumps of the echo delay along a call | tests; synthetic (delays 200, 110 and 360 ms in the comparison scene) |
| A neural failure, a damaged or missing model, no network: the classic filter stays, one `echo` warning, `.no-echo-model`, a new download | tests; a real failure of the echo model or of the network was not reproduced |
| NaN at the neural output | tests |
| The neural stage on the CPU and CUDA: speed | synthetic: 120 s scene in 43 s (CPU) and 27 s (CUDA); a synthetic hour in about 8 min (CPU) and 3.4 min (CUDA) |
| Echo removal gives the same sound as the Mac | synthetic: CPU and CUDA the same to 1 LSB, metrics equal to the Mac's (residual -64.73 dBFS, near-end loss -0.00 dB, SI-SDR 10.67 dB). Not compared by ear, not on a real call |

## Life of a call

| Case | Status |
|---|---|
| Raw tracks are never changed | tests |
| `done` is written before `listen.m4a`, leaving during the render does not break the call, the player falls back to the tracks | tests |
| A stop runs the `finally` blocks, `.work` is removed, exit code 143 | done, with CTRL_BREAK |
| A stop from an app with no console: a named event (`SOZVON_STOP_EVENT`) that the app creates and signals; a waiting thread raises the same signal, no polling, no thread without the variable | done, tested with a real process and a real event, exit 143, `.work` removed. The stop still waits until the main thread is back in Python, so it is delayed while native code or `time.sleep` runs |
| One engine per call, the lock goes away with the process | done |
| The engine and its workers end with the app | done (Job Object, parent watchdog) |
| `call.json` is atomic and locked, a corrupted one is not overwritten | tests; replacing a held file waits up to 3 s |
| A note racing a move to the Recycle Bin: on Windows the move is refused while the lock is held, and the note is kept | done, the app must retry the move (stage 2) |
| Renaming a call folder after transcription with files open | the app renames it, stage 2 |

## Voices

| Case | Status |
|---|---|
| Someone next to you, unknown voices that sound alike | tests; speaker separation ran on calls of synthetic voices only |
| People at the microphone stay out of the other side on a new run (`speaker_tracks`) | tests |
| Your own voice is never saved as someone else's, the other side's echo is not a person | tests |
| Voice prints are private to the user: the profile's ACL, chmod does nothing here | done |

## Install and environment

| Case | Status |
|---|---|
| No network, a broken or interrupted download (SHA, a retry), models at a pinned revision | tests; a wrong hash of the GPU download was reproduced, real network loss was not |
| The speaker models archive without symlink rights | done, installed on this machine from `setup.ps1` |
| Two copies of the OpenMP runtime in one process (torch and ctranslate2) | no error in full runs on CPU and GPU; no `KMP_DUPLICATE_LIB_OK` without agreement |
| No administrator rights: everything is in the user's folders | done, `setup.ps1` asks for no elevation and writes only to the data folder and `~\.local\bin` |
| GPU is optional, a missing library falls back to int8 on the CPU with a log line | done |
| Speaker separation, voice prints and the echo model on the GPU, each stage falling back to the CPU | done, on CUDA |
| The GPU build is chosen from a table by the card's generation; only NVIDIA compute capability 6.1 (GTX 1070) ran on a real card | done, the rest of the range is not verified |
| AMD Radeon (ROCm) and RTX 50xx | not verified, no such card here; ROCm is not packaged yet and needs `-Experimental` |
| A failed GPU step leaves the working CPU install | done for a failed download or check; a killed GPU step is repaired by the next run of `setup.ps1`; real network loss and a full disk not reproduced |
| Windows on ARM | refused with a message |
| A failure on the GPU in the middle of a track: the track starts over on the CPU, the GPU is not tried again | done |
| The GPU build of torch is installed by pinned hashes | done |
| No assistant, `SOZVON_LLM=none`, a failed summary and its warning | tests; `SOZVON_LLM=none` in the end-to-end runs |
| Low priority by default, half the logical cores, one limit for every library | done |
| Memory on long calls, speed on CPU and GPU | synthetic: one hour of audio, CPU with GigaAM 70.4 min and 4.36 GB, GPU with Turbo 36.0 min, peak video memory 8.0 of 8 GB with other work on the card |
| Whisper Turbo through faster-whisper, a full end-to-end run | synthetic, 4 of 4 end-to-end tests |
| Whisper Small through faster-whisper, a short phrase after silence | see "Known problems" |

## Assistants

| Case | Status |
|---|---|
| The text of a call never passes through `cmd.exe`, only stdin or a file; `--tools ""` arrives as an empty argument | tests |
| Programs start by absolute path only, nothing from the current folder | tests |
| A real summary through Claude | synthetic: `summary.md` written for a synthetic call |
| The MCP server over HTTP with a token | synthetic: 15 tools, list, get, search and add note answer, a wrong token gets 401, the server ends with its parent in about 2 s |
| Finding projects | off on Windows until the read-only rules can be expressed there |
| Codex and Cursor | run only when the user chooses them. Not verified on Windows with the real CLI, their sandboxes were not checked, and the text of the call goes to the chosen assistant. Cursor may have no file sandbox on Windows |

## Windows only

| Case | Status |
|---|---|
| Cyrillic and spaces in paths and user names: one full run | done (data folder with Cyrillic and a space) |
| `?*"<>\|`, reserved and very long names in call folders | done for names from the server; the app must apply the same rule when it names a folder (stage 2) |
| A file held open by an antivirus or a player | done, replacing waits up to 3 s |
| Console code page | done |
| Text mode writes a prompt's line ends as CRLF on stdin (every character intact, harmless for summaries) | known, left as is |
| Sleep and wake, the profile being unloaded | not verified, stage 2 |
| Calls live outside OneDrive by default | done |

## Known problems

- Whisper Small on the CPU (int8), one 13 s synthetic track: speech is lost to garbled text made of the prompt's words. Deterministic on that file, not reproduced on 30 other cases. Details in the report.
- Whisper Small with a Russian language setting drops a following English phrase (language switch test), on CPU and CUDA. Turbo keeps it.
- Whisper can invent a short phrase on silence before the first speech ("Держи."), mostly with Small.
- `setup.ps1` does not create `vocab.json` from `vocab.default.json`, which the Mac app does, so a Windows install has no base sentence in its prompt until the app does this (stage 2) or `setup.ps1` does.

## Only checked on synthetic audio

Speed and memory, echo removal, speaker separation, full runs, summaries and the MCP server: SAPI voices and LibriVox readings mixed by script. No real call has gone through the Windows engine.

## Not checked at all

RTX 50xx and every NVIDIA generation other than the GTX 1070; AMD; real network loss during a download; a full disk; sleep and wake; unloading of the profile; a real call; Windows on a clean user account; Codex and Cursor with the real CLI.

## To investigate

- Speaker embeddings through ONNX Runtime on the CPU (float only) are in the code, with a fallback to torch; they take effect once the model file is published in the `models-v1` release.
- pyannote computes each chunk three times on the same audio: computing the convolutions once per chunk could save far more.

## Stage 2

- The app's side of the stop: create the event, pass `SOZVON_STOP_EVENT`, signal it, and after a timeout kill through the Job, since the engine reacts only when the main thread is back in Python.
- The app holds the launcher in its own Job and opens engine files with `FileShare.ReadWrite | Delete`.
- The low priority setting comes from the app, as on macOS, and no console window appears for child processes.
- Raw microphone capture without system effects (`AUDCLNT_STREAMOPTIONS_RAW` where the device has it), and a check whether WASAPI loopback comes before the output device's effects: the echo filter needs no system AEC or noise suppression in its way.
- Echo removal was tuned on one 75-minute call on a MacBook: check by ear on Windows, and on a real call.
- Choosing a calls folder inside OneDrive or another synced folder shows an honest warning.
- A guard against the silent deletion of a folder larger than the Recycle Bin quota, before sync is turned on.
- Recording (WASAPI), the capsule, automatic start and stop, the Calls window.
- Settings, About: Diagnostics has "Show Logs" only, as the Mac's sheet does: checks.txt (engine, model, disk, MCP server, versions) and the logs scrubbed by the Mac's rules (profile folder, call titles, tokens, e-mails; process.log and mcp.log filtered closed) in `<data>\Diagnostics`, opened in Explorer. Still missing: the sheet with the checks on screen, the zip ("Save Archive…") and the permission checks.
- Settings, About: updates wait for the owner's decision on Windows releases. Releases hold only the Mac's DMG and the app has no version of its own, so a check against GitHub would compare with the Mac's versions; until then About shows the Mac's version as "сборка Windows, предварительная" with the commit, and no update rows.
