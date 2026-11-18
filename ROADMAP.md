# Roadmap

What is planned next, roughly in order. Sozvon stays a narrow tool: a feature gets in when it saves real time on every call.

## Windows

Sozvon for Windows 11, built and tested on a real Windows machine.

1. **Engine on Windows, no UI.** The Python engine (transcription, speaker separation, voice prints, summaries, MCP, sync) mostly runs as is. Whisper moves from `mlx-whisper` (Apple only) to faster-whisper (CUDA on NVIDIA, int8 on the CPU); Parakeet and GigaAM already run through ONNX Runtime (CUDA or DirectML). Check speed and memory on real calls.
2. **Minimal app.** Tray icon, the floating capsule, recording the microphone and the system audio on separate tracks (WASAPI loopback), the "A call is on. Record?" prompt (which app holds the microphone), setup, connecting Claude Code, Codex and Cursor. Calls are read through the assistants and plain files, without a Calls window yet.
3. **The rest, if people use it.** The Calls window with the player and edits, updates, code signing (unsigned first, also installable with Scoop or winget).

## Teams (later, if people ask for it)

After the Windows version and a public launch, if people use Sozvon in teams. A first, smaller step: **send each call to the project's Telegram chat** (topic, people, summary and tasks, the transcript as a file), straight from the Mac through the team's own bot, with no server.

The full version: everyone on a team records with their own Sozvon, and the calls of a shared project are readable by the whole team: in the Calls window, on a web site and through the assistants.

- **A team server.** Settings get a Team tab. Create a team, and Sozvon deploys a separate team server to your Cloudflare account, the same way it deploys the own server today. Or join a team with an invite. One person can own a team and be a member of another one; the first version may show one team in the interface.
- **Invites.** The owner creates a one-time invite link for a named person (first and last name), valid for a limited time. Opening it connects that person's Sozvon to the team. The owner can remove a member: access ends at once, the calls they recorded stay with the team.
- **Projects.** Any project can be connected to a team. Calls of connected projects go to the team server; all other calls stay private to each person. A team project (name, topic, people, terms, language) lives on the team server and syncs to every member's Sozvon, so everyone's calls are matched to it and get the same hints. Any member can create and edit team projects, in the Projects window or on the web site.
- **One call, one transcript.** When two members record the same call, the team server merges the recordings into one call: each member's words come from their own microphone, the cleanest track, the other people from the best recording.
- **Read only, plus notes.** Other members can read team calls and add notes, not edit or delete them.
- **Audio, if the owner turns on R2.** Call audio goes to the team server too when the owner enables Cloudflare R2 storage (free up to 10 GB).
- **Voice prints, if the team wants.** A team setting shares voice prints through the team server, so every member's Sozvon recognizes the same voices. Off by default, as voice prints are biometric data.
- **Assistants.** Each member's own server knows their teams and forwards MCP requests to the team server, so the assistant sees team calls next to the person's own, marked with the team.
- **Web site.** The team server has a modern web interface (React, MUI): team calls with search, the transcript and summary, notes; for the owner, members, invites and team settings. Sign in with a passkey: the first visit comes from Sozvon or the invite, after that the site works from a bookmark with Touch ID or Face ID.
- **Several teams.** The Team tab lists the teams you own and the ones you joined; each has its own server and site, and a project's Team field picks one. The own server forwards assistant requests to all of them.
- **Updating the team server.** Only the owner can update it, by signing in to Cloudflare again (Sozvon keeps no long-lived Cloudflare token). A newer Sozvon carries the newer server; the owner sees Update server in the Team tab and on the site. The server reports its version and keeps working with older apps, and a newer app on an older server says that new features arrive when the owner updates.
- **Mac first,** then Windows.

## To think about

- **Projects on two Macs.** A work call can happen on the laptop at home, and today projects stay on the Mac they were made on. Either sync all projects through the own server or offer "add from the cloud" somewhere; it must not make the interface harder.
- **WebRTC AEC3 for echo removal.** A first run on a real 75-minute call: about 5 times faster than the neural stage and no model to download, but noticeably more of the remote voice stays in the microphone. Worth a closer look, by ear and on more calls: as a lighter option, or in place of the classic filter when the model is missing.
