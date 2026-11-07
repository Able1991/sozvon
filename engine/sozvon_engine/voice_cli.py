"""bin/voice.py: enroll, list and delete voice prints (docs/CONTRACT.md, "Voice prints").

  voice.py enroll --name NAME [--profile SLUG] [--me] --file AUDIO
  voice.py enroll --name NAME [--profile SLUG] [--me] --call DIR --speaker LABEL
  voice.py list [--profile SLUG]
  voice.py delete --id ID | --all
Last output line: "RESULT: ok ..." or "RESULT: error <code> <message>", exit codes as bin/process_call.py.
"""
import argparse
import json
import sys
import time
import traceback

from . import profiles, voices
from .audio import FfmpegError, FfmpegMissing
from .i18n import t


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


def parse_args(argv=None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Sozvon: voice prints")
    sub = ap.add_subparsers(dest="cmd", required=True)
    en = sub.add_parser("enroll", help="enroll a voice from a recording of one person or a speaker of a call")
    en.add_argument("--name", required=True)
    en.add_argument("--profile", default="")
    en.add_argument("--me", action="store_true", help="the user's own voice")
    en.add_argument("--add", action="store_true", help="with --file: add this sample to the voice print instead of replacing it")
    src = en.add_mutually_exclusive_group(required=True)
    src.add_argument("--file")
    src.add_argument("--call")
    en.add_argument("--speaker", help="the speaker label in transcript.txt (with --call)")
    ls = sub.add_parser("list")
    ls.add_argument("--profile", default=None)
    de = sub.add_parser("delete")
    which = de.add_mutually_exclusive_group(required=True)
    which.add_argument("--id")
    which.add_argument("--all", action="store_true")
    return ap.parse_args(argv)


def finish(code: int, message: str = "") -> int:
    msg = " ".join(str(message).split())
    if code == 0:
        print(f"RESULT: ok {msg}".rstrip(), flush=True)
    else:
        log(msg)
        print(f"RESULT: error {int(code)} {msg}", flush=True)
    return int(code)


def run(args) -> int:
    if args.cmd == "list":
        n = 0
        for rec in voices.load_all():
            if args.profile is not None and rec["profile"] != args.profile:
                continue
            print(json.dumps(voices.summary(rec), ensure_ascii=False), flush=True)
            n += 1
        return finish(0, str(n))
    if args.cmd == "delete":
        if args.id is not None and not voices.ID_RE.match(args.id):
            raise voices.VoiceError(2, t("voice_bad_id", id=args.id))
        return finish(0, str(voices.delete(args.id, everything=args.all)))
    profile = (args.profile or "").strip()
    if profile and not profiles.valid_slug(profile):
        raise voices.VoiceError(2, t("voice_bad_profile", name=profile))
    if args.file:
        rec = voices.enroll_file(args.file, args.name, profile, args.me, add=args.add)
    else:
        if not args.speaker:
            raise voices.VoiceError(2, t("voice_no_speaker", label=""))
        rec = voices.enroll_call(args.call, args.speaker, args.name, profile, args.me)
    log(f"{rec['name']}: {rec['seconds']:.0f} s")
    return finish(0, rec["id"])


def main(argv=None) -> int:
    try:
        args = parse_args(argv)
    except SystemExit as e:  # argparse already printed the usage to stderr
        return 0 if e.code == 0 else finish(2, "invalid arguments (see voice.py --help)")
    try:
        return run(args)
    except voices.VoiceError as e:
        return finish(e.code, e.message)
    except FfmpegError as e:
        return finish(5, t("err_ffmpeg", file=e.file.name, err=e.detail))
    except (ImportError, FfmpegMissing) as e:
        traceback.print_exc()
        return finish(3, t("err_engine", err=e))
    except Exception as e:  # noqa: BLE001
        traceback.print_exc()
        return finish(1, f"{type(e).__name__}: {e}")
