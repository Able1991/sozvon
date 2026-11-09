# Windows stage 1 report

Stage 1 of the Windows port: the engine, no UI. One machine: Windows 11, a 12-thread CPU, NVIDIA GTX 1070 Max-Q with 8 GB. Case by case status: `docs/windows-port-checklist.md`.

**No real call has gone through the Windows engine.** All audio below is SAPI voices or LibriVox readings mixed by script.

## What works

- Install: `setup.ps1` from nothing, in user folders, no elevation, into a path with Cyrillic and a space. A re-run changes nothing. The optional GPU step falls back to the working CPU install.
- Full call: echo removal, Whisper (faster-whisper), GigaAM and Parakeet (ONNX), speaker separation, `listen.m4a`, summary through Claude.
- CUDA on the GTX 1070 for Whisper, speaker separation, voice prints and echo removal, each falling back to the CPU.
- Process control: one engine per call, workers end with the engine (Job Object), the engine ends with its parent.
- Stop: CTRL_BREAK, and a named event for an app with no console (`SOZVON_STOP_EVENT`). Both exit with 143 through the `finally` blocks and remove `.work`.
- MCP server over HTTP: 15 tools; list, get, search and add note answered, a wrong token got 401, the server ended about 2 s after its parent.
- Test suite: 793 passed, 0 failed, 10 skipped, with an installed engine and Turbo, in 6 min. The 10 skips: 7 are POSIX or macOS only behaviour with a Windows counterpart, 1 needs a local echo checkpoint, 1 needs the unpublished ONNX file, 1 needs symlink rights. Run it with a short temp folder: `test_a_long_name_leaves_room_for_the_files_inside` fails when the temp path itself is very long.

## Numbers

Recognition of 482.9 s of synthetic speech (times faster than real time):

| Model | CPU | GPU (CUDA) |
|---|---|---|
| Whisper Turbo | 1.6x, int8, 2.0 GB RAM | 15x, float32, 3.5 GB video memory |
| Whisper Small | 3x to 5x between runs, int8, 0.9 GB | 23x |
| GigaAM | 13x, 0.6 GB | same on ONNX CUDA, no gain |
| Parakeet | 11x, 1.9 GB | 10x on ONNX CUDA, no gain |

A synthetic hour, the whole run:

| | Time | Peak RAM | Video memory |
|---|---|---|---|
| CPU, GigaAM | 70.4 min (speaker separation 53 min, echo 8 min) | 4.36 GB | none |
| GPU, Turbo | 36.0 min (recognition 20 min, echo 3.4 min) | about 4.4 GB | 8.0 of 8 GB, with other work on the card and the CPU |

The two hours differ in model as well as device, and the GPU run shared the card, so its time and peak are not clean. A 6-minute synthetic call with Small took 863 s on the CPU and 134 s on the GPU (201 s with Turbo on the GPU).

Echo removal, on a 120 s synthetic scene with delay jumps: CPU and CUDA give the same result to 1 LSB. Metrics equal the Mac's: residual echo -64.73 dBFS, near-end loss -0.00 dB, SI-SDR 10.67 dB. 43 s on the CPU, 27 s on CUDA. Not yet compared by ear.

Responsiveness with the engine at low priority on 6 threads: timer lateness p99 0.7 ms, disk write p99 about 4 ms (0.7 and 2.3 ms at normal priority). Eco mode and the background class were rejected: worse spikes, and the background class took five times longer.

## Whisper Small and the prompt's words

With `SOZVON_TEST_MODEL=small`, `tests/test_e2e.py` on Windows: CPU (int8) 1 of 4 pass, GPU (float32) 3 of 4, the same in two rounds. Turbo passes 4 of 4. The Mac was not run here.

**The prompt's words.** On one 13 s synthetic system track (6 s of silence, then a phrase), Small on int8 writes "Термины Рекоменда. ..." instead of the phrase. The cause is a chain, deterministic on that audio and independent of the thread count: with `hallucination_silence_threshold` on, the first window ends at 1 s (with it off it does not), and in the next window the greedy decode loops on the silence (compression ratio about 8 at temperatures 0, 0.2 and 0.4), 0.6 fails the log probability, and 0.8 is accepted and is noise built from the prompt.

- On this one file each of these changes the outcome: float32 on the CPU (still through a retry, at 0.2), only temperature 0, no silence threshold, the VAD filter.
- It did not happen on 30 other cases per compute type: three human readings and two synthetic voices, each after 3, 6 and 9 s of digital silence or -70 dB noise, 0 failures of 30 on int8 and 0 of 30 on float32.
- Prompt words on quiet stretches: 32 runs on the CPU (eight scenes of silence and -60 dB noise around human and synthetic speech, four prompts), no prompt word in any of them. Whisper can still invent a short phrase on silence ("Держи."); that is Small on silence, not the prompt.

Decision: no change in `whisper_ct2.py`. Each setting that fixes this file changes behaviour that was chosen to match the Mac (the retries, the silence skip, no VAD) or costs speed and memory on every call, for a failure seen only on one synthetic track. This does not prove it can never happen on a real call: the human sample is small.

**The language switch test** fails on CPU and GPU: with language `ru`, Small writes the Russian phrase and nothing for the English one after it. Turbo keeps it. Small with `en` hears both phrases, so this is how Small handles the other language, and it was left as is.

## Only on synthetic audio

Speed and memory, echo removal, speaker separation, end-to-end runs, summaries, the MCP server.

## Not verified

RTX 50xx, other NVIDIA generations, AMD; real network loss during a download; a full disk; sleep and wake; unloading of the profile; a real call; Codex and Cursor with the real CLI and their sandboxes.

## Decisions

- Whisper through faster-whisper with every decoding option spelled out as in `mlx_whisper` (greedy, no VAD of its own), a fixed seed for the retries.
- int8 on the CPU, float16 or float32 on the card, chosen once per process; a GPU failure restarts that track on the CPU.
- Half the logical cores and low priority by default, one thread limit for every library.
- Only Claude runs without an explicit choice; project discovery is off on Windows until read-only rules can be expressed there.
- macOS behaviour is unchanged: differences stay behind `platform_support.SYSTEM == "win32"` or in Windows-only modules.

## Open questions

1. `setup.ps1` does not create `vocab.json` from `vocab.default.json`, as the Mac app does at launch, so a Windows install has no base sentence in its prompt. It was left alone: should `setup.ps1` create it, or the app in stage 2?
2. Should Small on the CPU get anything beyond this report? Failures so far are on synthetic audio only.
3. Should the language switch test run for Small on Windows, or only Turbo?
4. The ONNX speaker embeddings take effect once the model file is published in the `models-v1` release.
5. Echo removal has to be judged by ear, and then on a real call.

## How to run

Install, from `engine\`:

```
powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1 [-DataDir <folder>] [-Gpu]
```

A call folder holds `mic.m4a`, `system.m4a` and `meta.json`:

```
<data>\.venv\Scripts\python.exe <data>\bin\process_call.py <call folder> --me <name> --names <names> --topic <topic>
```

`SOZVON_DATA_DIR`, `SOZVON_MODEL` (`turbo`, `small`, `gigaam`, `parakeet`) and `SOZVON_LLM` (`claude`, `none`) choose the rest. The MCP server: `<data>\.venv\Scripts\python.exe server.py --http`, with `SOZVON_MCP_PORT` and `SOZVON_MCP_TOKEN`.

Tests, from `engine\`, with ffmpeg on `PATH`, `PYTHONUTF8=1`, and `SOZVON_TEST_ENGINE=<install>` for the slow ones (`SOZVON_TEST_MODEL=small` for Small):

```
python -m pytest tests -q --basetemp=<short folder>
```

Echo comparison: `engine\tools\echo_compare.py build --download --cache <dir> --out <scene>`, then `run <scene> --out <wav>`, `metrics --scene <scene> <wav>`, `compare --scene <scene> <a> <b>`.
