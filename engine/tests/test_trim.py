"""bin/trim_call.py: cutting a call at its start and end (docs/CONTRACT.md, sections 3 to 5)."""
import json
import subprocess
import sys
import wave
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

from sozvon_engine import audio, calls, trim

SR = 48000
BIN = Path(__file__).resolve().parent.parent / "bin"
CLICK = 12.0  # a click on the call timeline, heard on both tracks


def test_cut_keeps_track_offsets_when_a_track_starts_late():
    meta = {"mic_start": 100.0, "system_start": 103.0, "mic_seconds": 600.0, "system_seconds": 590.0}
    p = trim.plan(meta, start=2.0, end=500.0)
    assert p["mic"] == {"from": 2.0, "to": 500.0, "new_start": 102.0}
    assert p["system"] == {"from": 0.0, "to": 497.0, "new_start": 103.0}


def test_track_entirely_outside_is_dropped():
    meta = {"mic_start": 0.0, "system_start": 400.0, "mic_seconds": 300.0, "system_seconds": 200.0}
    assert set(trim.plan(meta, 310.0, 590.0)) == {"system"}


def test_track_ending_early_keeps_its_end():
    meta = {"mic_start": 0.0, "system_start": 0.0, "mic_seconds": 100.0, "system_seconds": 50.0}
    assert trim.plan(meta, 10.0, 90.0)["system"] == {"from": 10.0, "to": 50.0, "new_start": 10.0}


def test_imported_recording_has_one_track():
    meta = {"system_start": 0, "system_seconds": 60.0}
    assert trim.plan(meta, 5.0, 50.0) == {"system": {"from": 5.0, "to": 50.0, "new_start": 5.0}}


def test_marks_shift_and_drop():
    assert trim.shift_marks([10.0, 60.0, 62.0, 500.0, 501.0], 60.0, 500.0) == [0.0, 440.0]


def test_marks_round_to_a_tenth():
    assert trim.shift_marks([100.04, 200.0], 10.0, 300.0) == [90.0, 190.0]


# Real files: system.m4a 30 s from clock 1000.0, mic.m4a 29 s from clock 1001.0, so the call is 30 s long.

def _track(path: Path, seconds: float, click_at: float, seed: int) -> Path:
    t = np.arange(int(seconds * SR)) / SR
    x = 0.05 * np.sin(2 * np.pi * (220 + 110 * seed) * t)
    i = int(click_at * SR)
    x[i:i + 48] = 0.9
    wav = path.with_suffix(".wav")
    with wave.open(str(wav), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767).astype("<i2").tobytes())
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(wav), "-c:a", "aac", "-b:a", "64k", str(path)],
                   check=True)
    wav.unlink()
    return path


def make_call(tmp_path, **extra) -> Path:
    d = tmp_path / "Calls" / "2026-11-24 09-00"
    d.mkdir(parents=True)
    _track(d / "system.m4a", 30.0, CLICK, 0)
    _track(d / "mic.m4a", 29.0, CLICK - 1.0, 1)
    (d / "listen.m4a").write_bytes(b"listen")
    (d / "mic.clean.m4a").write_bytes(b"clean")
    call = {"schema": 1, "id": "2026-11-24 09-00", "status": "done",
            "audio": {"system_start": 1000.0, "mic_start": 1001.0, "system_seconds": 30.0, "mic_seconds": 29.0},
            "marks": [2.0, 8.0, 19.5, 25.0], "silence": {"head": 5.0, "tail": 10.0}, **extra}
    (d / "call.json").write_text(json.dumps(call))
    return d


def click_time(f: Path) -> float:
    x = audio.decode(f)
    return float(np.argmax(np.abs(x))) / audio.SR


def test_trim_call_cuts_real_files_and_updates_call_json(tmp_path):
    d = make_call(tmp_path)
    old_meta = calls.read_call(d)["audio"]
    trim.trim_call(d, 5.0, 20.0, now="2026-11-24T10:00:00Z")
    assert abs(audio.duration(d / "mic.m4a") - 15.0) < 0.05
    assert abs(audio.duration(d / "system.m4a") - 15.0) < 0.05
    c = calls.read_call(d)
    assert c["trimmed"] == {"at": "2026-11-24T10:00:00Z", "head": 5.0, "tail": 10.0}
    assert "silence" not in c and not (d / "listen.m4a").exists() and not (d / "mic.clean.m4a").exists()
    assert not (d / ".work").exists()
    expected = trim.plan(old_meta, 5.0, 20.0)
    assert abs(c["audio"]["mic_start"] - expected["mic"]["new_start"]) < 0.01
    assert abs(c["audio"]["system_start"] - expected["system"]["new_start"]) < 0.01
    assert c["audio"]["mic_start"] - c["audio"]["system_start"] == pytest.approx(0.0, abs=0.01)  # mic was 1 s late
    assert c["audio"]["mic_seconds"] == pytest.approx(15.0) and c["audio"]["system_seconds"] == pytest.approx(15.0)
    assert c["marks"] == [3.0, 14.5]
    assert c["status"] == "done"


def test_cut_tracks_stay_aligned_within_10_ms(tmp_path):
    """The click at 12.0 s of the call is at 7.0 s of both cut tracks (both now start at the new t0)."""
    d = make_call(tmp_path)
    assert abs(click_time(d / "system.m4a") - CLICK) < 0.002
    assert abs(click_time(d / "mic.m4a") - (CLICK - 1.0)) < 0.002
    trim.trim_call(d, 5.0, 20.0, now="2026-11-24T10:00:00Z")
    sys_click, mic_click = click_time(d / "system.m4a"), click_time(d / "mic.m4a")
    assert abs(sys_click - 7.0) < 0.01 and abs(mic_click - 7.0) < 0.01
    assert abs(sys_click - mic_click) < 0.01


def test_second_trim_adds_to_the_numbers(tmp_path):
    d = make_call(tmp_path)
    trim.trim_call(d, 5.0, 20.0, now="2026-11-24T10:00:00Z")
    trim.trim_call(d, 1.0, 12.0, now="2026-11-24T11:00:00Z")
    c = calls.read_call(d)
    assert c["trimmed"] == {"at": "2026-11-24T11:00:00Z", "head": 6.0, "tail": 13.0}
    assert abs(audio.duration(d / "system.m4a") - 11.0) < 0.05
    assert c["audio"]["system_start"] == pytest.approx(1006.0) and c["audio"]["mic_start"] == pytest.approx(1006.0)


def test_track_outside_the_range_is_deleted(tmp_path):
    d = make_call(tmp_path)
    c = calls.read_call(d)
    c["audio"].update(mic_seconds=10.0)  # the mic ran from 1 s to 11 s of the call
    calls.write_call(d, c)
    trim.trim_call(d, 15.0, 28.0, now="2026-11-24T10:00:00Z")
    c = calls.read_call(d)
    assert not (d / "mic.m4a").exists()
    assert "mic_start" not in c["audio"] and "mic_seconds" not in c["audio"]
    assert c["audio"]["system_seconds"] == pytest.approx(13.0)


def run_cli(d, *args, capsys=None):
    code = trim.main([str(d), *args])
    out = capsys.readouterr().out.strip().splitlines() if capsys else []
    return SimpleNamespace(code=code, last_line=out[-1] if out else "")


def test_cli_trims(tmp_path, capsys):
    d = make_call(tmp_path)
    r = run_cli(d, "--start", "5", "--end", "20", capsys=capsys)
    assert (r.code, r.last_line) == (0, "RESULT: ok")
    assert calls.read_call(d)["trimmed"]["head"] == 5.0


def test_cli_rejects_short_range(tmp_path, capsys):
    d = make_call(tmp_path)
    before = (d / "mic.m4a").read_bytes()
    r = run_cli(d, "--start", "5", "--end", "12", capsys=capsys)
    assert r.code == 2 and r.last_line.startswith("RESULT: error 2")
    assert (d / "mic.m4a").read_bytes() == before and "trimmed" not in calls.read_call(d)


@pytest.mark.parametrize("start,end", [(-1, 20), (5, 31), (25, 40)])
def test_cli_rejects_a_range_outside_the_call(tmp_path, capsys, start, end):
    d = make_call(tmp_path)
    r = run_cli(d, "--start", str(start), "--end", str(end), capsys=capsys)
    assert r.code == 2 and r.last_line.startswith("RESULT: error 2")


def test_cli_missing_folder_is_2(tmp_path, capsys):
    r = run_cli(tmp_path / "nope", "--start", "0", "--end", "20", capsys=capsys)
    assert r.code == 2 and r.last_line.startswith("RESULT: error 2")


def test_cli_broken_call_json_is_2_and_not_overwritten(tmp_path, capsys):
    d = make_call(tmp_path)
    (d / "call.json").write_text("{broken")
    r = run_cli(d, "--start", "5", "--end", "20", capsys=capsys)
    assert r.code == 2 and (d / "call.json").read_text() == "{broken"


def test_failed_ffmpeg_leaves_folder_unchanged(tmp_path, monkeypatch, capsys):
    d = make_call(tmp_path)
    before = {f.name: f.read_bytes() for f in d.iterdir() if f.is_file()}
    real = audio._run
    n = {"calls": 0}

    def flaky(args, src):
        if "-ss" in args:
            n["calls"] += 1
            if n["calls"] == 2:  # the first track is cut, the second fails
                raise audio.FfmpegError(src, "Invalid data found when processing input")
        return real(args, src)

    monkeypatch.setattr(audio, "_run", flaky)
    r = run_cli(d, "--start", "5", "--end", "20", capsys=capsys)
    assert r.code == 5 and r.last_line.startswith("RESULT: error 5")
    assert n["calls"] == 2
    assert {f.name: f.read_bytes() for f in d.iterdir() if f.is_file()} == before
    assert not (d / ".work").exists()


def test_bin_script_reports_a_missing_folder(tmp_path):
    r = subprocess.run([sys.executable, str(BIN / "trim_call.py"), str(tmp_path / "nope"), "--start", "0", "--end", "20"],
                       capture_output=True, text=True)
    assert r.returncode == 2 and r.stdout.strip().splitlines()[-1].startswith("RESULT: error 2")


def test_sigterm_during_the_commit_waits_for_call_json(tmp_path, monkeypatch):
    """The app quitting mid-commit must not leave cut tracks under the old call.json (a later trim would cut twice)."""
    import os
    import signal
    from sozvon_engine.pipeline import guard
    d = make_call(tmp_path)
    old = signal.getsignal(signal.SIGTERM)
    guard.exit_on_sigterm()
    real = os.replace
    seen = []

    def replace(src, dst):
        seen.append(guard._commit.locked())  # the parent watcher waits for this lock before it exits
        os.kill(os.getpid(), signal.SIGTERM)
        real(src, dst)
    monkeypatch.setattr(trim.os, "replace", replace)
    try:
        with pytest.raises(SystemExit) as e:
            trim.trim_call(d, 3.0, 27.0, now="2026-11-24T10:00:00Z")
    finally:
        signal.signal(signal.SIGTERM, old)
    assert e.value.code == 143
    assert seen and all(seen)
    c = json.loads((d / "call.json").read_text())
    assert c["trimmed"]["at"] == "2026-11-24T10:00:00Z", "call.json written before the exit"
    assert not guard._commit.locked() and not (d / ".work").exists()


def test_sigterm_outside_the_commit_still_stops_at_once():
    import signal
    from sozvon_engine.pipeline import guard
    old = signal.getsignal(signal.SIGTERM)
    guard.exit_on_sigterm()
    try:
        with guard.committing():
            pass
        handler = signal.getsignal(signal.SIGTERM)
        with pytest.raises(SystemExit):
            handler(signal.SIGTERM, None)
    finally:
        signal.signal(signal.SIGTERM, old)


def test_parent_watcher_waits_for_the_commit(monkeypatch):
    import threading
    import time as _time
    from sozvon_engine import platform_support
    from sozvon_engine.pipeline import guard
    parents = iter([500, 500])
    monkeypatch.setattr(platform_support, "parent_pid", lambda: next(parents, 1))  # then the app is gone
    monkeypatch.setattr(platform_support, "kill_own_process_group", lambda: None)
    exited = threading.Event()
    monkeypatch.setattr(guard.os, "_exit", lambda code: exited.set())
    with guard._commit:
        guard.watch_parent(interval=0.01)
        _time.sleep(0.2)
        assert not exited.is_set(), "the commit is still going"
    assert exited.wait(2)
    guard._commit.release()  # the watcher keeps it until the process ends; this test's process goes on
