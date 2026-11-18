# Contributing to Sozvon

Thanks for wanting to help. Sozvon is a small tool on purpose: it records calls, transcribes them on the Mac and hands them to your assistant. Fixes and small features that keep it that way are the easiest to take in.

## Before you start

- **Bugs:** open an issue with the bug form. A diagnostics archive (Settings → About → Diagnostics…) helps most.
- **Ideas and questions:** start a [discussion](https://github.com/Able1991/sozvon/discussions) first, so we agree on the shape before you write code.
- **Security problems:** never in public. See [SECURITY.md](SECURITY.md).

## Privacy comes first

Sozvon handles other people's voices and words. In issues, discussions, pull requests, tests and fixtures:

- Don't attach recordings, transcripts, summaries or voice prints of real calls. Make a short synthetic one instead (`tools/demo_data.py` and the demo calls show how).
- Don't paste real names, company names, emails or tokens. Logs from the diagnostics archive contain no call text, but check before you post them.
- Test data uses fictional people and projects.

## Building and testing

```bash
git clone https://github.com/Able1991/sozvon && cd sozvon
./test.sh              # Python, localization, the own server (with Node.js 22+), Swift
SLOW=1 ./test.sh       # plus end-to-end tests with real Whisper
./build.sh install     # ~/Applications/Sozvon.app
```

Requires Xcode Command Line Tools and [uv](https://docs.astral.sh/uv/); Node.js 22+ for the server. To try a change without touching your own Sozvon, run a copy with its own bundle id and data folders (see `tools/uitest.sh` for how the UI test does it).

Anything that records sound needs a manual check with real hardware: headphones on and off mid-call, Bluetooth, a real call app. Say in the pull request what you tried.

## Pull requests

- One topic per pull request is easier to review; a fix and the tests for it belong together.
- Add a line to the `Unreleased` section of [CHANGELOG.md](CHANGELOG.md) when users will notice the change.
- New user-facing text goes into both languages (`tools/l10n.py check` must pass).
- Code, comments, commit messages and docs are in English; the app itself is in Russian and English.
- CI must be green: tests, the UI click test, the server tests and the security scans.

Pull requests are merged as one squash commit on `main`. Your authorship stays on it.

## License

By contributing you agree that your work is released under the project's [MIT license](LICENSE).
