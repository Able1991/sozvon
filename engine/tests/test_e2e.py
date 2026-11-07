"""End-to-end test: a synthesized call through real Whisper.

The "Milena" voice (say) plays both me on the microphone and the other side on the
system track; an echo of the other side is mixed into the microphone. Checks the text,
labels, echo removal and files; renaming is not needed (the app does it).
"""
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from conftest import installed_engine

ENGINE = installed_engine()
pytestmark = [pytest.mark.slow,
              pytest.mark.skipif(ENGINE is None, reason="no installed engine with models"),
              pytest.mark.skipif(shutil.which("say") is None, reason="no `say` command")]

BIN = Path(__file__).resolve().parent.parent / "bin"


def tts(text: str, out: Path):
    aiff = out.with_suffix(".aiff")
    subprocess.run(["say", "-v", "Milena", "-o", str(aiff), text], check=True)
    return aiff


def ff(*args):
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-v", "error", *args], check=True)


def make_call(tmp_path):
    me = tts("Привет, давай обсудим запуск кампании на следующей неделе.", tmp_path / "me")
    them = tts("Хорошо, бюджет согласован, стартуем в понедельник.", tmp_path / "them")
    call = tmp_path / "call"
    call.mkdir()
    # system: 6 s of silence, then the other side. mic: me right away, then a quiet echo of the other side.
    ff("-i", str(them), "-af", "adelay=6000:all=1,apad=pad_dur=2", "-ac", "2", "-ar", "48000",
       "-c:a", "aac", str(call / "system.m4a"))
    ff("-i", str(me), "-i", str(them), "-filter_complex",
       "[1]adelay=6000:all=1,volume=0.35[e];[0][e]amix=inputs=2:duration=longest:normalize=0,apad=pad_dur=2",
       "-ac", "1", "-ar", "48000", "-c:a", "aac", str(call / "mic.m4a"))
    (call / "meta.json").write_text(json.dumps({"mic_start": 100.0, "system_start": 100.0}))
    return call


def run(call, *extra):
    # The installed engine's .env may set up the user's own server: a test call must never reach it. A non-empty
    # address wins over .env; nothing listens on this port, so the push after transcription fails at once.
    env = {**os.environ, "SOZVON_DATA_DIR": str(ENGINE), "SOZVON_LLM": "none", "HF_HUB_OFFLINE": "1",
           "SOZVON_UI_LANG": "ru", "SOZVON_SERVER_URL": "http://127.0.0.1:9"}
    env.pop("HF_TOKEN", None)
    py = ENGINE / ".venv/bin/python3"
    r = subprocess.run([str(py), str(BIN / "process_call.py"), str(call),
                        "--me", "Тест", "--names", "Анна", "--topic", "запуск", *extra],
                       env=env, capture_output=True, text=True, timeout=600)
    assert r.returncode == 0, r.stderr[-2000:]
    assert r.stdout.strip().splitlines()[-1] == "RESULT: ok"
    return r


def test_full_call(tmp_path):
    call = make_call(tmp_path)
    run(call, "--no-diarize")

    txt = (call / "transcript.txt").read_text()
    lines = [l for l in txt.splitlines() if l.strip()]
    mine = [l for l in lines if "] Тест:" in l]
    theirs = [l for l in lines if "] Анна:" in l]
    assert mine and theirs, txt
    assert "кампани" in " ".join(mine).lower()
    assert "понедельник" in " ".join(theirs).lower()
    # the other side's echo must not remain in my lines
    assert "понедельник" not in " ".join(mine).lower()

    md = (call / "transcript.md").read_text()
    assert md.startswith("# Звонок") and "запуск" in md.splitlines()[0]
    meta = json.loads((call / "call.json").read_text())
    assert meta["names"] == ["Анна"] and meta["topic"] == "запуск"
    assert meta["status"] == "done" and meta["engine"]["model"] == "turbo"
    assert not (call / "summary.md").exists()
    assert not list(call.glob("*.wav")), "временные wav должны удаляться"


@pytest.mark.skipif(ENGINE is None or not (ENGINE / "hf-cache").is_dir() and not os.environ.get("HF_TOKEN"),
                    reason="no pyannote models")
def test_diarization_without_token(tmp_path):
    """Diarization with the installer's models, without HF_TOKEN and without network."""
    call = make_call(tmp_path)
    r = run(call)
    log = r.stdout + r.stderr
    assert "диаризация: собеседников" in log, log[-2000:]
    txt = (call / "transcript.txt").read_text()
    assert "] Анна:" in txt and "] Тест:" in txt


def tts_voice(text: str, out: Path, voice: str):
    aiff = out.with_suffix(".aiff")
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    return aiff


def test_two_languages_per_track(tmp_path):
    """I speak Russian, the other side English, ru and en allowed: each track in its own language."""
    me = tts("Привет, давай обсудим запуск кампании на следующей неделе.", tmp_path / "me")
    them = tts_voice("Sounds good, the budget is approved, we start on Monday.", tmp_path / "them", "Samantha")
    call = tmp_path / "call"
    call.mkdir()
    ff("-i", str(them), "-af", "adelay=6000:all=1,apad=pad_dur=2", "-ac", "2", "-ar", "48000",
       "-c:a", "aac", str(call / "system.m4a"))
    ff("-i", str(me), "-af", "apad=pad_dur=8", "-ac", "1", "-ar", "48000", "-c:a", "aac", str(call / "mic.m4a"))
    (call / "meta.json").write_text(json.dumps({"mic_start": 100.0, "system_start": 100.0}))
    r = run(call, "--no-diarize", "--language", "ru,en")
    log = r.stdout + r.stderr
    assert "mic: язык ru" in log and "system: язык en" in log, log[-1500:]
    txt = (call / "transcript.txt").read_text()
    theirs = " ".join(l for l in txt.splitlines() if "] Анна:" in l).lower()
    assert "monday" in theirs, txt


def test_language_switch_mid_speech(tmp_path):
    """One person speaks Russian, then English: with --switch the English phrase stays English."""
    ru = tts("Сейчас я расскажу про планы на квартал и про бюджет.", tmp_path / "ru")
    en = tts_voice("And now let me repeat the key points in English for our partners.", tmp_path / "en", "Samantha")
    call = tmp_path / "call"
    call.mkdir()
    ff("-i", str(ru), "-i", str(en), "-filter_complex",
       "[0]apad=pad_dur=2[a];[a][1]concat=n=2:v=0:a=1,apad=pad_dur=2",
       "-ac", "1", "-ar", "48000", "-c:a", "aac", str(call / "mic.m4a"))
    (call / "meta.json").write_text(json.dumps({"mic_start": 100.0}))
    r = run(call, "--no-diarize", "--language", "ru,en", "--switch")
    log = r.stdout + r.stderr
    txt = (call / "transcript.txt").read_text()
    assert "бюджет" in txt.lower(), txt
    assert "partners" in txt.lower() or "english" in txt.lower(), txt + log[-800:]
    assert "фраз на другом языке: " in log
