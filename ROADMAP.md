# Roadmap

What is planned next, roughly in order. Sozvon stays a narrow tool: a feature gets in when it saves real time on every call.

## To think about

- **Projects on two Macs.** A work call can happen on the laptop at home, and today projects stay on the Mac they were made on. Either sync all projects through the own server or offer "add from the cloud" somewhere; it must not make the interface harder.
- **A shared call base for a team.** Today every user's own server is personal: one Cloudflare account, one person's calls. A team version on the company's own server would be a separate product decision.
- **WebRTC AEC3 for echo removal.** A first run on a real 75-minute call: about 5 times faster than the neural stage and no model to download, but noticeably more of the remote voice stays in the microphone. Worth a closer look, by ear and on more calls: as a lighter option, or in place of the classic filter when the model is missing.

## Windows

Sozvon for Windows 11, built and tested on a real Windows machine.

1. **Engine on Windows, no UI.** The Python engine (transcription, speaker separation, voice prints, summaries, MCP, sync) mostly runs as is. Whisper moves from `mlx-whisper` (Apple only) to faster-whisper (CUDA on NVIDIA, int8 on the CPU); Parakeet and GigaAM already run through ONNX Runtime (CUDA or DirectML). Check speed and memory on real calls. Calls live in `%USERPROFILE%\Sozvon Calls` by default, outside OneDrive and other cloud folders: Known Folder Move can put Documents in OneDrive, and recordings must not reach a cloud without the user choosing that.
2. **Minimal app.** Tray icon, the floating capsule, recording the microphone and the system audio on separate tracks (WASAPI loopback), the "A call is on. Record?" prompt (which app holds the microphone), setup, connecting Claude Code, Codex and Cursor. Choosing a calls folder inside OneDrive or another synced folder shows an honest warning. Calls are read through the assistants and plain files, without a Calls window yet.
3. **The rest, if people use it.** The Calls window with the player and edits, updates, code signing (unsigned first, also installable with Scoop or winget).
