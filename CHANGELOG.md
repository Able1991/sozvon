# Changelog

## 0.1.5

- **Works on corporate networks.** The install and model downloads trust the certificates in the macOS Keychain, so a company HTTPS certificate no longer stops them with "UnknownIssuer". A package mirror (also the one in `pip.conf`), your own Python, a Hugging Face mirror, a proxy or a certificate file can be set in the engine `.env`. See "Corporate network" in the docs.
- **Select and copy in the summary and the transcript.** Drag across lines, sections or paragraphs, ⌘A selects it all, ⌘C copies plain text: bullets as "• ", tasks as "- [ ] ", transcript lines as "[1:12] Anna: text". Each summary section has its own Copy button. In the transcript a plain click still plays from that paragraph; a drag, a double or a triple click selects.
- **Saved voices check every long line.** When the people on a call have saved voices, each long line of the other side is compared with them and gets the name it clearly sounds like, even where speaker separation put two people under one label.
- **One voice, one label.** A remote voice cut into two parts by speaker separation is put back together, for example when someone in the room is listed among the participants.
- **Find inside a transcript.** ⌘F on the Transcript tab finds words in this call: every match is highlighted, Return and Shift-Return move between them. On the Summary tab, or with ⌥⌘F, it searches across all calls as before.

## 0.1.4

- **Ask your assistant about people.** Two new MCP tools: `get_commitments` ("what did Oleg promise me", from the summaries across calls) and `get_person` (how many calls, the last one, projects, who else was there, open commitments).
- **Your own name is never saved as someone else's voice,** even when the name in Settings is empty or spelled in another alphabet.
- **Recordings from your phone.** Choose a folder (iCloud Drive or any other); audio saved there from Voice Memos is imported and transcribed by itself, and the file moves to Imported. On iPhone, the [Think Out Loud shortcut](https://www.icloud.com/shortcuts/eca8c5ccf15d474db3490d66f4dadaf0) records in one tap and saves to a folder named Sozvon in iCloud Drive.
- **Consent reminder.** Optional: a note on the capsule at the start of a recording to tell the others.
- **Reflections.** Press the capsule and think out loud. At the end choose Reflections: one speaker, no call summary but the main point, an analysis, what to do and your open questions. They live in the Calls list with a mark and their own filter, can belong to a project, and assistants can search them. Recordings from the phone folder are reflections too. On a second Mac and through your own server's connectors a reflection looks like a regular call.
- **Diagnostics for support.** Settings > About > Diagnostics… checks Python, the model, ffmpeg, speaker models, permissions, the MCP server, free space and versions. Save Archive… writes a zip with the checks and the logs, without transcripts, summaries, audio, passwords, voices or participant names.
- **No silent data loss after a recording.** If the status or your answers can't be saved (full disk, folder gone), a notification says so and the recording stays intact.
- **One transcription at a time.** Several Transcribe Again or imports now wait their turn ("Queued" in the Calls list, removable from the queue) instead of running together. The queue survives a restart, and a transcription interrupted by a crash is tried once more.
- **No leftover files after stopping a transcription.** The temporary audio of a transcription lives in a hidden `.work` folder and is removed when it ends, is stopped or the app restarts, instead of staying in the call folder.
- **Someone next to you is no longer labeled as you.** If you saved your voice, a person speaking at your microphone for at least 15 seconds gets their own label or their saved name. Unknown voices that sound alike, usually people far from the microphone, share one label instead of a new one for every fragment.
- **Honest status when the summary fails.** If the assistant could not write the summary, the notification says "Done, but the summary failed" with the reason and an Update Summary button, and the call in the list gets a "No summary" mark.
- **Demo calls to try.** Settings > Assistants > Demo Calls > Add puts a few fictional calls with a transcript and summary (no audio) into the calls folder, so you can ask your assistant about them before your first recording. Remove moves only those to the Trash. They are marked Demo in the list and never go to your own server.
- **Install with Homebrew:** `brew install --cask able1991/sozvon/sozvon`.
- **Calmer to listen to.** The player plays a levelled copy of the call (`listen.m4a`, about 33 MB per hour): loud stretches are pulled down firmly, quiet speech raised by at most 6 dB, pauses stay about as quiet as they were (about 1 dB up on the 2 minutes we measured, from the smoothing at their edges), and a limiter holds the peaks. A very quiet track is raised first, so it can end up more than 6 dB above the recording. Each side is levelled on its own and keeps its full bandwidth, except your microphone on a call where echo was removed, which is the cleaned 16 kHz signal. Writing the copy takes about 2 minutes per hour of call, after the call is already done; quitting meanwhile just leaves it to play the original tracks. Calls transcribed before this update play as they did until they are transcribed again. Transcription, speaker separation and voice prints don't hear it.
- **Much cleaner sound without headphones.** Echo removal now follows the delay as it changes during a call and removes what a filter cannot with a small on-device neural model (11 MB, downloaded once, optional, about 2 extra minutes per hour of call). While the other side is silent, your voice and people next to you are left exactly as they are; while the other side talks, nearby voices are kept, but a voice much quieter than the speakers can come out quieter.

## 0.1.3

- **Record calls automatically, if you want.** Settings > General > When a Call Starts: Ask (as before), Record Automatically or Do Nothing. Record Automatically shows "Call in Zoom · recording in 10 s" on the panel with Record Now and Don't Record, then starts by itself.
- **Stop when the call ends.** Optional: once no call app has held the microphone for 30 seconds, the recording stops by itself and goes to transcription. The panel counts down with Continue, which keeps this recording going until you stop it. Short gaps while a call app reconnects don't count, the other side still being heard keeps the recording going (some apps let go of the microphone on mute), and a recording without a call app never stops by itself.
- **Countdowns are always on screen,** even with the floating panel turned off.
- **Who was on the call, known by the end of it.** If you have saved voices of other people, Sozvon compares the other side's speech with them during the call, at low priority and on your Mac only. "What was the call about?" opens with the project and participants from Calendar and the voices.
- **Goes ahead by itself when it's clear.** When the project and participants are known for sure, the form transcribes after 10 seconds; change anything or press Wait to stop it. Off switch in Settings > General > After the Call.

## 0.1.2

- **Updates install themselves.** Once a day Sozvon checks for a new version, downloads it in the background and installs it when nothing is going on: no recording, no transcription, no call and no open window. The restart takes a couple of seconds, then a notification links to what's new. Every update is checked against the developer's signature and the Sozvon key (Sparkle). Turn off Update Automatically to only get a menu item and install it yourself. This is the last version you install by hand.
- **About tab in Settings** with the version, the update switch, Check for Updates, release notes and links to the website, the docs and the source code. Updates moved there from General.

## 0.1.1

- **Cursor as a third assistant.** Summaries and Find Projects work through `cursor-agent`, and Settings > Assistants connects Cursor to the local MCP server (`~/.cursor/mcp.json`, your other servers and comments are kept).
- **Calls from another Mac** show their project's title instead of its internal name and can be filtered by it in Calls, even when this Mac has no such project.

## 0.1.0

The first public release. Sozvon records calls on your Mac, transcribes them locally on Apple silicon and keeps everything on your Mac: speakers, summaries, search, notes. Assistants reach your calls through MCP, and an optional server in your own Cloudflare account brings them to Claude and ChatGPT on the phone.

### Recording

- **Any call app, FaceTime too.** One button on a floating panel above every window (even full-screen Zoom) or in the menu bar. The other side is recorded through a Core Audio process tap and your microphone on its own track: Zoom, Google Meet, FaceTime, Telegram, TrueConf or anything else, no virtual audio drivers, no bots in the call. The tap follows a change of the output device (headphones, a new FaceTime call), and ScreenCaptureKit takes over if the tap can't run. Microphone arrays (the MacBook Pro mic) are recorded as clean mono.
- **Both voices on the panel.** While recording, the panel shows your voice in blue and the other side in coral, running toward each other, so you see at a glance that both are heard. The panel can be dragged anywhere.
- **Call prompt.** When Zoom, Telegram, a browser or another call app holds the microphone for 5 seconds, the panel (or a notification) asks "A call is on in Zoom. Record?". Sozvon never records by itself; Not Now keeps it quiet until the call ends. Only which app uses the mic is read, never the audio.
- **Important moments.** A star on the panel, in the menu or ⌃⌥I anywhere marks the moment. The paragraph gets a star in the transcript and the summary gets a Key Moments section.
- **Never a silent recording.** Sozvon warns at once when your mic gives nothing, when the system input volume is below 50% (browser calls often lower it) and when your voice has been barely audible for three minutes. When the other side is not heard, it quietly captures their audio again, and warns only if that did not help (later if they were heard before and are probably just listening). A missing System Audio Recording permission is explained when the recording starts. Warn About Silence turns the notifications off.
- **Stays out of the call.** While a call app holds the microphone, the chimes stay silent and transcription of earlier calls waits until the recording stops.

### Transcription

- **Local and private.** Speech recognition and speaker separation run on the Mac. Models: Whisper Turbo (default), Whisper Large v3, Whisper Small, GigaAM v3 for Russian and Parakeet v3 for 25 European languages. Several languages per call, optionally switching mid-sentence, and a low priority mode that yields to other apps.
- **Clean sound.** Without headphones the mic hears the other side from the speakers: Sozvon removes that echo from your track, with the other side's track as the reference, and raises a very quiet mic. The player plays the cleaned track; the original stays for transcribing again.
- **Clean text.** Whisper's subtitle habits on pauses and noise ("[music]", "(laughter)", "Subtitles by…") never reach the transcript.
- **Speakers and names.** Your voice and the other side are kept apart by track, remote speakers are separated by voice (pyannote) and the assistant names people from the conversation.
- **Voice prints.** Record a 20-second sample of your voice in Settings (simple texts in each call language). Name a speaker once, or confirm a transcript with Remember Voices, and later calls of the project name those voices by themselves, so two people with the same first name are told apart. Participants with a saved voice get a green check; names whose voice is not confirmed yet stand out in coral. Settings lists every voice print with a delete button for each.
- **Summaries** in the language of the call: overview, decisions, action items with owners, open questions. Through Claude Code or Codex on your own subscription, or Local Only with nothing sent anywhere.

### Calls

- **Calls window.** Calls by day with a project filter, a live Recording Now row and a Needs Description badge; search across dates, topics, projects, people, summaries and transcripts; the summary and notes in sections; transcribe again, with a clear state and the processing log when a transcription fails; move to Trash with undo.
- **Participants found for you.** Everyone the transcript names (a recognized voice, a name from the conversation, a rename) joins the call's participants, in the order they first speak, next to the names you typed. The list follows the transcript (someone left without lines after an edit leaves it), and found names are never taken as typed when the call is transcribed again.
- **Player.** Both tracks mixed in sync under the transcript: click a line to play from there, the current line follows the sound, back and forward 15 s, 1x, 1.5x and 2x.
- **Fix the transcript.** Rename a speaker with suggestions from the call and the project, for the whole transcript or one line; Swap two mixed-up people or Merge two. Fix a misheard word and remember it as an auto-replacement for the project. Update Summary rewrites only the summary after an edit.
- **From Calendar.** After a recording, the topic, the participants and the project come from the meeting in Calendar at that time. Only empty fields are filled, and Later puts the description off with a gentle reminder.
- **Notes.** Add a note to a call, or let an assistant add one with `add_note`. Notes show who added them and when, and search finds them. Delete one with the ⋯ button (⌘Z brings it back), or ask an assistant (`delete_note`).
- **Import recordings.** Drop an audio or video file onto the Calls list: m4a, mp3, wav, aac, flac, mp4 and mov.
- **To Reminders.** Action items from the summary (yours checked) and notes go to Apple Reminders, with due dates only for clearly named days.
- **Projects.** People, terms and fixes for mishearings per client, used as hints for recognition. Find Projects suggests projects from your Claude Code or Codex sessions.
- **Delete audio automatically** after a week, 15, 30 or 60 days. Only the sound of finished calls goes, on your own server too; the transcript, summary and notes stay.

### Assistants and your own server

- **MCP for Claude Code and Codex.** One local MCP server with a token: `list_calls`, `get_call`, ranked `search_calls` (any word form, alternative phrasings), `add_note`, `delete_note`, `transcribe` and project tools. Connect with one click in Settings.
- **Your own cloud server (optional).** Connect Cloudflare sets up a server in your own free Cloudflare account, so Claude and ChatGPT connectors can read, search and add notes to your calls from your phone or the web while the Mac is off. Text always goes up; call audio and voice prints too, unless you turn them off (both on by default). Connectors only ever get text. We host nothing and never see your data.
- **Sync across Macs.** A new Mac connected to the same server downloads your calls with their audio, notes and voice prints. Only calls you delete in Sozvon are deleted on the server.

### Everywhere

- **Privacy.** No telemetry and no servers of our own. Everything that can go online is listed in the README.
- **Quality.** Signed and notarized by Apple. Every commit runs the engine, app and server tests, clicks through every screen of the app on a clean Mac, and is checked by Gitleaks, Semgrep and CodeQL.
- **Native on macOS 26.** System sidebar, Liquid Glass toolbar and player, Settings with toolbar tabs and grouped forms like System Settings, data entry sheets laid out like Mail, an Apple style setup assistant, SF Symbols throughout.
- Russian and English interface, light and dark mode.
