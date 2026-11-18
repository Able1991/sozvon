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
| Sleep and wake | the recording stops and is saved before sleep or hibernation, the form waits for the wake (e467da9; checked with the suspend notice posted to a test instance). A real lid close: needs Boris |
| The profile being unloaded | not verified |
| Calls live outside OneDrive by default | done |

## Capture: devices and failures

Checked by tests with fake devices and real ffmpeg, plus a read-only scan of this laptop's outputs. Nothing here changed a Windows setting, so every row that needs a device plugged, pulled or switched is on Boris's manual list.

| Case | How the recorder handles it | Status |
|---|---|---|
| Default microphone or output changed (Sound settings, the volume flyout, an app) | Windows' notice for the default device reopens the stream; the new one runs before the old closes, the overlap is cut, a hole becomes silence | tests; real switch: needs Boris |
| USB headset, USB mic, HDMI or DisplayPort audio plugged in or pulled mid-call | A lost device (`AUDCLNT_E_DEVICE_INVALIDATED`) is reopened on the new default at the next step, the gap becomes silence | tests; real: needs Boris |
| Bluetooth headset: Stereo and Hands-Free are two outputs; a call that opens the mic plays to Hands-Free while the default stays Stereo and goes quiet | The other side is also captured from a second output where a program plays right now (the communications device first), started at its first packet and mixed into `system.m4a` at the stop or recovery on the shared clock (83e07ff). An idle output is never opened, so Sozvon never puts a headset into call mode itself | tests (choice, placement, real ffmpeg mix, crash recovery); real headset in Zoom, Telegram, Teams and a browser call: needs Boris |
| A call app set to its own microphone, not the default (or the default communications mic differs from the default) | The microphone track follows the mic another program captures from right now, read from Windows' sound sessions every 3 s and on any device notice; the default wins when the call uses it too. A call app that stops capturing while muted keeps the track on its mic while it is plugged in | tests (choice, a real read-only scan); real: Zoom or Telegram set to a non-default mic: needs Boris |
| A call app set to its own speaker, not the default | Same second output: any output other than the default with a program's session running | tests; real: needs Boris |
| Headset battery dies, reconnects | Lost device, then the default's notice: reopened both ways | tests; real: needs Boris |
| No output at all, then one comes back | The track retries every second and writes silence; «Их не слышно» after its usual time | tests |
| No microphone at the start, or one held in exclusive mode (`AUDCLNT_E_DEVICE_IN_USE`) | The recording starts anyway; «Тебя не слышно» after 8 s; the track takes a mic as soon as one opens. Only microphone access refused in Windows privacy settings stops the start (83e07ff) | tests; real: needs Boris |
| Endpoint disabled in Sound settings | Lost device, reopened on the new default | by code; real: needs Boris |
| Sample rate, bit depth or channels of a device changed (8-192 kHz, mono arrays, 5.1 and 7.1) | Every stream asks Windows for 48 kHz float with `AUTOCONVERTPCM`, so Windows resamples and downmixes; the files are always 48 kHz and the AAC encoder (ffmpeg, after the call) never sees another rate. The Mac's 16 kHz encoder failure can't happen here | by code + tests of the fixed format; a device at 16 kHz Hands-Free: needs Boris |
| Spatial sound, enhancements, virtual devices (VB-Cable, Voicemeeter, NVIDIA Broadcast, Krisp) | Loopback hears the default output's mix whatever it is; a virtual mic is recorded like any other (raw only if it offers raw) | not verified: needs Boris if he uses one |
| Loopback sends no packets while nothing plays | Silence is written up to 0.25 s behind the clock, packets are placed by their timestamps, drift is taken out one frame at a time | tests (30 min of drift either way in the TrackTimeline tests); a real 1 h call: needs Boris |
| Microphone muted by a key, by the app, by privacy settings mid-recording | Digital silence: capture again after 2 min, then the warning; privacy off: the stream fails, reopen is refused, «Тебя не слышно» after 8 s. Nothing stops | tests; real: needs Boris |
| Audio service restarted (`AUDCLNT_E_SERVICE_NOT_RUNNING`) | Opens retry every second; after ten refusals, or when Windows can't give a device list, the track asks for the devices again (83e07ff) | tests |
| Any other capture error | Costs that stream a second, never the track | tests |
| A track that can't be written (full disk, drive gone, folder removed) | Told at once in a toast and the capsule, the other track goes on; both lost: the recording stops and saves what there is | tests of the rule; a real full disk: not checked |
| Sleep, hibernation, lid close | Saved as a stop before sleep (e467da9) | test instance; real: needs Boris |
| Screen lock | Nothing changes, the recording goes on | by code |
| Fast user switching, RDP | Not handled specially: a stream Windows takes away is reopened when it gives it back | not verified: needs Boris |
| App killed mid-recording | The spooled tracks (and the second output, if it was used) are finished at the next start and the call is queued | tests |
| Two quick start/stop cycles, Start while the previous one is finalizing | Start is ignored until the previous call is saved and its form is up | by code + earlier UIA run |
| Very long recording | The spool has no 4 GB limit (streaming WAV size), about 0.7 GB an hour for the mic and 1.4 GB for the other side | tests of the header; a 2 h run: not checked |

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
- Settings, About: Diagnostics has "Show Logs" only, as the Mac's sheet does: checks.txt (engine, model, disk, MCP server, versions) and the logs, the engine's assistant.log among them, scrubbed by the Mac's rules (profile folder, call titles, tokens, e-mails; process.log and mcp.log filtered closed) in `<data>\Diagnostics`, opened in Explorer. Still missing: the sheet with the checks on screen, the zip ("Save Archive…") and the permission checks.
- Settings, About: updates wait for the owner's decision on Windows releases. Releases hold only the Mac's DMG and the app has no version of its own, so a check against GitHub would compare with the Mac's versions; until then About shows the Mac's version as "сборка Windows, предварительная" with the commit, and no update rows.
