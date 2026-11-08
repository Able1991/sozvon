"""Live voice hints while recording: pieces of the other side's track matched against saved voices."""
import json
import os
import shutil

import numpy as np
import pytest

from sozvon_engine import live_voices, voice_cli, voices
from test_voices import fake_embed, one_hot, silence, tone  # noqa: F401  (fixture)


def write_track(path, x):
    """A piece as the app writes it: 16 kHz mono 32-bit float WAV."""
    data = np.asarray(x, dtype="<f4").tobytes()
    import struct
    hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 3, 1, 16000, 64000, 4, 32)
    path.write_bytes(hdr + b"data" + struct.pack("<I", len(data)) + data)
    return path


@pytest.fixture(autouse=True)
def model_ready(monkeypatch):
    monkeypatch.setattr(voices, "_load", lambda: object())


def store(name, freq, profile="", me=False):
    return voices.store(name, profile, me, np.array(one_hot(int(freq / 100))), 30.0)


def test_who_spoke(tmp_path, fake_embed):  # noqa: F811
    store("Анна Петрова", 300, profile="acme")
    store("Олег", 500)
    store("Я", 700, me=True)
    live = tmp_path / ".live"
    live.mkdir()
    # Anna talks for 14 s, Oleg says one short thing (3 s: below MIN_SECONDS), the user's own voice is never matched.
    write_track(live / "system-0001.wav", np.concatenate([tone(300, 14), silence(1), tone(500, 3), silence(1), tone(700, 10)]))
    (live / "stop").touch()
    assert live_voices.run(live, log=lambda m: None, poll=0.01, parent=os.getppid()) == 0
    out = json.loads((live / "voices.json").read_text())
    assert out["done"] is True and out["pieces"] == 1
    assert [v["name"] for v in out["voices"]] == ["Анна Петрова"]
    assert out["voices"][0]["profile"] == "acme" and out["voices"][0]["seconds"] >= 12
    assert not list(live.glob("system-*.wav")), "a matched piece is deleted at once"


def test_one_voice_saved_under_two_names(tmp_path, fake_embed):  # noqa: F811
    """Two names with nearly the same print (one person named wrongly once): matched, but the name is not trusted."""
    store("Влад", 300, profile="pop")
    twin = voices.unit(np.array(one_hot(3)) * 0.9 + np.array(one_hot(9)) * np.sqrt(1 - 0.81))
    voices.store("Борис", "pop", False, twin, 10.0)
    store("Олег", 500)
    live = tmp_path / ".live"
    live.mkdir()
    write_track(live / "system-0001.wav", tone(300, 14))
    (live / "stop").touch()
    assert live_voices.run(live, log=lambda m: None, poll=0.01, parent=os.getppid()) == 0
    out = json.loads((live / "voices.json").read_text())
    assert [v["name"] for v in out["voices"]] == ["Влад"], "the name with more enrolled speech"
    assert out["voices"][0]["unsure"] is True and out["voices"][0]["profile"] == "pop"


def test_a_clear_voice_is_not_unsure(tmp_path, fake_embed):  # noqa: F811
    store("Анна", 300)
    store("Олег", 500)
    live = tmp_path / ".live"
    live.mkdir()
    write_track(live / "system-0001.wav", tone(300, 14))
    (live / "stop").touch()
    live_voices.run(live, log=lambda m: None, poll=0.01, parent=os.getppid())
    assert json.loads((live / "voices.json").read_text())["voices"][0]["unsure"] is False


def test_no_saved_voices_ends_at_once(tmp_path):
    live = tmp_path / ".live"
    live.mkdir()
    assert live_voices.run(live, log=lambda m: None, poll=0.01, parent=os.getppid()) == 0
    assert json.loads((live / "voices.json").read_text()) == {"voices": [], "pieces": 0, "speech": 0.0, "done": True}


def test_waits_for_pieces_until_stop(tmp_path, fake_embed, monkeypatch):  # noqa: F811
    store("Олег", 500)
    live = tmp_path / ".live"
    live.mkdir()
    calls = {"n": 0}

    def sleep(_):
        # The app adds a piece, then a second one together with the stop file.
        calls["n"] += 1
        if calls["n"] == 1:
            write_track(live / "system-0001.wav", tone(500, 8))
        elif calls["n"] == 2:
            write_track(live / "system-0002.wav", tone(500, 8))
            (live / "stop").touch()
    monkeypatch.setattr(live_voices.time, "sleep", sleep)
    assert live_voices.run(live, log=lambda m: None, poll=0, parent=os.getppid()) == 0
    out = json.loads((live / "voices.json").read_text())
    assert out["pieces"] == 2 and out["voices"][0]["name"] == "Олег" and out["voices"][0]["seconds"] >= 14


def test_model_unavailable_ends_cleanly(tmp_path, monkeypatch):
    store("Олег", 500)
    live = tmp_path / ".live"
    live.mkdir()

    def broken():
        raise voices.VoiceUnavailable("no model")
    monkeypatch.setattr(voices, "_load", broken)
    assert live_voices.run(live, log=lambda m: None, poll=0.01, parent=os.getppid()) == 0
    assert json.loads((live / "voices.json").read_text())["done"] is True


def test_ends_when_the_folder_is_gone(tmp_path, monkeypatch):
    store("Олег", 500)
    live = tmp_path / ".live"
    live.mkdir()
    monkeypatch.setattr(live_voices.time, "sleep", lambda _: shutil.rmtree(live))
    assert live_voices.run(live, log=lambda m: None, poll=0, parent=os.getppid()) == 0


def test_windows():
    sr = 16000
    w = live_voices.windows([np.zeros(sr * 13), np.zeros(sr)])
    assert [len(x) / sr for x in w] == [6.0, 6.0]  # 13 s: two full windows, the 1 s rest and the 1 s piece dropped


def test_cli(tmp_path, capsys):
    live = tmp_path / ".live"
    live.mkdir()
    (live / "stop").touch()
    assert voice_cli.main(["live", "--dir", str(live)]) == 0
    assert capsys.readouterr().out.strip().splitlines()[-1] == "RESULT: ok"
