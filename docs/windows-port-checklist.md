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
| A stop from an app with no console: a named event (`SOZVON_STOP_EVENT`) that the app creates and signals; a waiting thread raises the same signal, no polling, no thread without the variable | done, tested with a real process and a real event, exit 143, `.work` removed. The stop still waits until the main thread is back in Python, so it is delayed while native code or `time.sleep` runs |
| One engine per call, the lock goes away with the process | done |
| The engine and its workers end with the app | done (Job Object, parent watchdog) |
| `call.json` is atomic and locked, a corrupted one is not overwritten | tests, retries in block 8 |
| A note racing a move to the Recycle Bin: on Windows the move is refused while the lock is held, and the note is kept | done, the app must retry the move (stage 2) |
| Renaming a call folder after transcription with files open | the app renames it, stage 2 |

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
| Two copies of the OpenMP runtime in one process (torch and ctranslate2) | no error in full runs on CPU and GPU; no `KMP_DUPLICATE_LIB_OK` without agreement |
| No administrator rights: everything is in the user's folders | block 7 |
| GPU is optional, a missing library falls back to int8 on the CPU with a log line | done |
| Speaker separation, voice prints and the echo model on the GPU, each stage falling back to the CPU | done, on CUDA |
| The GPU build is chosen from a table by the card's generation; only NVIDIA compute capability 6.1 (GTX 1070) ran on a real card | done, the rest of the range is not verified |
| AMD Radeon (ROCm) and RTX 50xx | not verified, no such card here; ROCm is not packaged yet and needs `-Experimental` |
| A failed GPU step leaves the working CPU install | done for a failed download or check; a killed process, a lost network and a full disk not reproduced yet |
| Windows on ARM | refused with a message |
| A failure on the GPU in the middle of a track: the track starts over on the CPU, the GPU is not tried again | done |
| The GPU build of torch is installed by pinned hashes | done |
| No assistant, `SOZVON_LLM=none`, a failed summary and its warning | block 4 |
| Low priority by default, half the logical cores, one limit for every library | done |
| Memory on long calls, speed on CPU and GPU | block 9 |

## Assistants

| Case | Status |
|---|---|
| The text of a call never passes through `cmd.exe`, only stdin or a file; `--tools ""` arrives as an empty argument | block 4 |
| Programs start by absolute path only, nothing from the current folder | block 4 |
| Finding projects | off on Windows until the read-only rules can be expressed there |
| Codex and Cursor | run only when the user chooses them. Not verified on Windows with the real CLI, their sandboxes were not checked, and the text of the call goes to the chosen assistant. Cursor may have no file sandbox on Windows |

## Windows only

| Case | Status |
|---|---|
| Cyrillic and spaces in paths and user names: one full run | block 9 |
| `?*"<>\|`, reserved and very long names in call folders | done for names from the server; the app must apply the same rule when it names a folder (stage 2) |
| A file held open by an antivirus or a player | done, replacing waits up to 3 s |
| Console code page | done |
| Text mode writes a prompt's line ends as CRLF on stdin (every character intact, harmless for summaries) | known, left as is |
| Sleep and wake, the profile being unloaded | block 9 where possible, otherwise stage 2 |
| Calls live outside OneDrive by default | done |

## To investigate

- Speaker embeddings through ONNX Runtime on the CPU (float only) are in the code, with a fallback to torch; they take effect once the model file is published in the `models-v1` release.
- pyannote computes each chunk three times on the same audio: computing the convolutions once per chunk could save far more.

## Stage 2

- The app's side of the stop: create the event, pass `SOZVON_STOP_EVENT`, signal it, and after a timeout kill through the Job, since the engine reacts only when the main thread is back in Python.
- The app holds the launcher in its own Job and opens engine files with `FileShare.ReadWrite | Delete`.
- The low priority setting comes from the app, as on macOS, and no console window appears for child processes.
- Raw microphone capture without system effects (`AUDCLNT_STREAMOPTIONS_RAW` where the device has it), and a check whether WASAPI loopback comes before the output device's effects: the echo filter needs no system AEC or noise suppression in its way.
- Echo removal was tuned on one 75-minute call on a MacBook: compare with the Mac on a synthetic pair (block 9) and by ear.
- Choosing a calls folder inside OneDrive or another synced folder shows an honest warning.
- A guard against the silent deletion of a folder larger than the Recycle Bin quota, before sync is turned on.
- Recording (WASAPI), the capsule, automatic start and stop, the Calls window.
