# Windows port checklist

What the Mac version handles and the Windows port has to handle the same way, from `CHANGELOG.md`, `docs/CONTRACT.md` and the engine tests. Stage numbers are from the Windows section of `ROADMAP.md`.

Status: **done** (checked on Windows), **tests** (the engine tests pass on Windows, no real run yet), **block N** (planned step of stage 1), **stage 2** or **stage 3**.

## Sound and echo

| Case | Status |
|---|---|
| Headphones and a call with no echo: the neural stage does not run, the file does not change | tests, real run in block 9 |
| A very quiet microphone raised by up to 30 dB | tests, real run in block 9 |
| A mute microphone, a system track with gaps (`dead_spans`) | tests, real run in block 9 |
| Jumps of the echo delay along a call | tests |
| A neural failure, a damaged or missing model, no network: the classic filter stays, one `echo` warning, `.no-echo-model`, a new download | tests, real run in block 7 |
| NaN at the neural output | tests |
| The neural stage on the CPU: speed | block 6 |

## Life of a call

| Case | Status |
|---|---|
| Raw tracks are never changed | tests, real run in block 9 |
| `done` is written before `listen.m4a`, leaving during the render does not break the call, the player falls back to the tracks | tests |
| A stop runs the `finally` blocks, `.work` is removed, exit code 143 | done, with CTRL_BREAK |
| One engine per call, the lock goes away with the process | done |
| The engine and its workers end with the app | done (Job Object, parent watchdog) |
| `call.json` is atomic and locked, a corrupted one is not overwritten | tests, retries in block 8 |
| Renaming a call folder after transcription with files open, a note racing a move to the Recycle Bin | block 8 |

## Voices

| Case | Status |
|---|---|
| Someone next to you, unknown voices that sound alike | tests, real run in block 9 |
| People at the microphone stay out of the other side on a new run (`speaker_tracks`) | tests |
| Your own voice is never saved as someone else's, the other side's echo is not a person | tests |
| Voice prints are private to the user: the profile's ACL, chmod does nothing here | done |

## Install and environment

| Case | Status |
|---|---|
| No network, a broken or interrupted download (SHA, a retry), models at a pinned revision | tests, real run in block 7 |
| The speaker models archive without symlink rights | block 7 |
| No administrator rights: everything is in the user's folders | block 7 |
| GPU is optional, a missing library falls back to int8 on the CPU with a log line | blocks 5 to 7 |
| No assistant, `SOZVON_LLM=none`, a failed summary and its warning | block 4 |
| Low priority and `SOZVON_THREADS` | block 4 for the process, block 5 for Whisper |
| Memory on long calls, speed on CPU and GPU | block 9 |

## Assistants

| Case | Status |
|---|---|
| The text of a call never passes through `cmd.exe`, only stdin or a file; `--tools ""` arrives as an empty argument | block 4 |
| Programs start by absolute path only, nothing from the current folder | block 4 |
| Finding projects | off on Windows until the read-only rules can be expressed there |
| Codex and Cursor | unavailable until their sandboxes can be checked on Windows |

## Windows only

| Case | Status |
|---|---|
| Cyrillic and spaces in paths and user names: one full run | block 9 |
| `?*"<>\|`, reserved and very long names in call folders | block 8 |
| A file held open by an antivirus or a player | block 8 |
| Console code page | block 4 |
| Sleep and wake, the profile being unloaded | block 9 where possible, otherwise stage 2 |
| Calls live outside OneDrive by default | done |

## Stage 2

- A stop path that works for an app with no console (a named event or `.work/stop`, a timeout, killing through the Job). CTRL_BREAK needs a shared console, and a stop is delayed while native code or `time.sleep` runs.
- The app holds the launcher in its own Job and opens engine files with `FileShare.ReadWrite | Delete`.
- The low priority setting comes from the app, as on macOS, and no console window appears for child processes.
- Choosing a calls folder inside OneDrive or another synced folder shows an honest warning.
- A guard against the silent deletion of a folder larger than the Recycle Bin quota, before sync is turned on.
- Recording (WASAPI), the capsule, automatic start and stop, the Calls window.
