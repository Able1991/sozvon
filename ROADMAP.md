# Roadmap

What is planned next, roughly in order. Sozvon stays a narrow tool: a feature gets in when it saves real time on every call.

## Next

- **Own server settings survive a reinstall.** The server address and password live in the engine's `.env` today, so a clean reinstall forgets them while the Cloudflare sign-in (in the Keychain) stays: Settings says "connected" but Sync is gone. Keep the address and password in the Keychain too, and offer Restore when Cloudflare is connected but the address is missing.
- **Commitments and people in MCP.** Ask an assistant "what did Oleg promise me" across all calls: action items per person and a short profile of a person, tied to voice prints so the names are right.
- **Small things that remove friction.** Install with Homebrew. Demo calls at first launch, to try an assistant before the first recording. A watched iCloud folder for voice memos from the phone. A short reminder to tell the other side the call is being recorded.

## Windows

Sozvon for Windows 11, built and tested on a real Windows machine.

1. **Engine on Windows, no UI.** The Python engine (transcription, speaker separation, voice prints, summaries, MCP, sync) mostly runs as is. Whisper moves from `mlx-whisper` (Apple only) to faster-whisper (CUDA on NVIDIA, int8 on the CPU); Parakeet and GigaAM already run through ONNX Runtime (CUDA or DirectML). Check speed and memory on real calls.
2. **Minimal app.** Tray icon, the floating capsule, recording the microphone and the system audio on separate tracks (WASAPI loopback), the "A call is on. Record?" prompt (which app holds the microphone), setup, connecting Claude Code, Codex and Cursor. Calls are read through the assistants and plain files, without a Calls window yet.
3. **The rest, if people use it.** The Calls window with the player and edits, updates, code signing (unsigned first, also installable with Scoop or winget).
