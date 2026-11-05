"""bin/process_call.py: call.json как источник правды, коды завершения и строка RESULT (на подделках)."""
import json
from pathlib import Path

import pytest

from conftest import fake_model
from sozvon_engine import audio, llm, prompt, whisper
from sozvon_engine.pipeline import run, speakers, tracks, transcribe


def make_call(tmp_path, call=None, tracks_=("mic", "system")) -> Path:
    d = tmp_path / "Calls" / "2026-11-04 15-01"
    d.mkdir(parents=True)
    for key in tracks_:
        (d / f"{key}.m4a").write_bytes(b"\0" * 2048)
    if call is not None:
        (d / "call.json").write_text(json.dumps(call, ensure_ascii=False))
    return d


def result(capsys) -> str:
    return capsys.readouterr().out.strip().splitlines()[-1]


@pytest.fixture
def fakes(monkeypatch, data):
    """Модель «скачана», ffmpeg и Whisper подменены: проверяем только этапы и файлы."""
    fake_model(data)
    monkeypatch.setenv("SOZVON_LLM", "none")
    seen = {}

    def to_wav(src, dst, delay=0.0):
        Path(dst).write_bytes(b"wav")
        return Path(dst)

    def transcribe_tracks(tr, **kw):
        seen.update(kw, tracks=tr)
        return ({"mic": [(0.0, 2.0, "Привет, давай начнём.")],
                 "system": [(3.0, 5.0, "Бюджет согласован.")]}, {"mic": "ru", "system": "ru"})

    monkeypatch.setattr(audio, "to_wav", to_wav)
    monkeypatch.setattr(tracks, "active_seconds", lambda wav: 5.0)
    monkeypatch.setattr(tracks, "dead_spans", lambda wav: [])
    monkeypatch.setattr(whisper, "ensure_backend", lambda: None)
    monkeypatch.setattr(prompt, "count_tokens", lambda text: len(text.split()))
    monkeypatch.setattr(transcribe, "transcribe_tracks", transcribe_tracks)
    return seen


def test_no_audio_is_2(tmp_path, capsys):
    d = make_call(tmp_path, {"schema": 1, "id": "2026-11-04 15-01", "status": "recorded"}, tracks_=())
    assert run.main([str(d)]) == 2
    assert result(capsys).startswith("RESULT: error 2 в записи нет звука")


def test_missing_folder_is_2(tmp_path, capsys):
    assert run.main([str(tmp_path / "nope")]) == 2
    assert result(capsys).startswith("RESULT: error 2 ")


def test_broken_call_json_is_2_and_not_overwritten(tmp_path, capsys):
    d = make_call(tmp_path)
    (d / "call.json").write_text("{broken")
    assert run.main([str(d)]) == 2
    assert (d / "call.json").read_text() == "{broken"


def test_model_missing_is_4(tmp_path, capsys):
    d = make_call(tmp_path, {"id": "2026-11-04 15-01"})
    assert run.main([str(d)]) == 4
    assert result(capsys) == "RESULT: error 4 модель turbo не скачана"


def test_unknown_model_is_2(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("SOZVON_MODEL", "medium")
    d = make_call(tmp_path, {"id": "2026-11-04 15-01"})
    assert run.main([str(d)]) == 2


def test_ffmpeg_failure_is_5(tmp_path, capsys, monkeypatch, data):
    fake_model(data)
    d = make_call(tmp_path, {"id": "2026-11-04 15-01"})

    def broken(src, dst, delay=0.0):
        raise audio.FfmpegError(src, "Invalid data found when processing input\nsecond line")
    monkeypatch.setattr(audio, "to_wav", broken)
    assert run.main([str(d)]) == 5
    line = result(capsys)
    assert line.startswith("RESULT: error 5 ffmpeg не смог прочитать mic.m4a") and "\n" not in line
    assert not list(d.glob("*.wav"))


def test_ffmpeg_missing_is_3(tmp_path, capsys, monkeypatch, data):
    fake_model(data)
    d = make_call(tmp_path, {"id": "2026-11-04 15-01"})
    monkeypatch.setattr(audio, "subprocess", type("S", (), {"run": staticmethod(
        lambda *a, **k: (_ for _ in ()).throw(FileNotFoundError("ffmpeg")))}))
    assert run.main([str(d)]) == 3


def test_silent_tracks_are_2(tmp_path, capsys, fakes, monkeypatch):
    monkeypatch.setattr(tracks, "active_seconds", lambda wav: 0.2)
    d = make_call(tmp_path, {"id": "2026-11-04 15-01"})
    assert run.main([str(d)]) == 2
    assert not list(d.glob("*.wav"))


def test_import_error_is_3(tmp_path, capsys, fakes, monkeypatch):
    def broken():
        raise ImportError("No module named 'mlx'")
    monkeypatch.setattr(whisper, "ensure_backend", broken)
    d = make_call(tmp_path, {"id": "2026-11-04 15-01"})
    assert run.main([str(d)]) == 3
    assert result(capsys).startswith("RESULT: error 3 движок повреждён")


def test_folder_is_enough(tmp_path, capsys, fakes, profiles):
    (profiles / "acme.json").write_text(json.dumps({"title": "Acme", "people": ["Анна Петрова"]}, ensure_ascii=False))
    d = make_call(tmp_path, {"schema": 1, "id": "2026-11-04 15-01", "status": "recorded",
                             "audio": {"mic_start": 10.0, "system_start": 10.5}, "profile": "acme",
                             "names": ["Анна"], "topic": "запуск", "terms": "HPA", "languages": "ru,en",
                             "summary": True})
    assert run.main([str(d), "--no-diarize"]) == 0
    assert result(capsys) == "RESULT: ok"
    assert fakes["allowed"] == ["ru", "en"] and fakes["model"] == "turbo"
    p, _ = fakes["prompts"].build("ru")
    assert "Проект: Acme" in p and "Участники: Анна" in p and "запуск" in p and "HPA" in p
    txt = (d / "transcript.txt").read_text()
    assert txt == "[00:00] Я: Привет, давай начнём.\n[00:03] Анна: Бюджет согласован.\n"
    md = (d / "transcript.md").read_text()
    assert md.startswith("# Звонок 2026-11-04 15-01 · Acme · запуск")
    c = json.loads((d / "call.json").read_text())
    assert c["status"] == "done" and c["engine"]["model"] == "turbo" and c["engine"]["version"]
    assert c["audio"] == {"mic_start": 10.0, "system_start": 10.5} and c["names"] == ["Анна"]
    assert not list(d.glob("*.wav"))


def test_cli_overrides_call_json(tmp_path, capsys, fakes):
    d = make_call(tmp_path, {"id": "2026-11-04 15-01", "names": ["Анна"], "topic": "старая", "languages": "ru"})
    assert run.main([str(d), "--no-diarize", "--names", "Иван, Олег", "--topic", "новая",
                     "--language", "en", "--me", "Олег"]) == 0
    c = json.loads((d / "call.json").read_text())
    assert c["names"] == ["Иван", "Олег"] and c["topic"] == "новая" and c["languages"] == "en"
    assert fakes["allowed"] == ["en"]
    assert "] Олег:" in (d / "transcript.txt").read_text()


def test_summary_failure_keeps_transcript(tmp_path, capsys, fakes, monkeypatch):
    monkeypatch.setattr(llm, "backend", lambda settings=None: ("claude", "/bin/claude"))

    def boom(*a, **kw):
        raise TimeoutError("claude timed out")
    monkeypatch.setattr(llm, "run", boom)
    d = make_call(tmp_path, {"id": "2026-11-04 15-01", "names": ["Анна"]})
    assert run.main([str(d), "--no-diarize"]) == 0
    assert (d / "transcript.txt").exists() and not (d / "summary.md").exists()
    # Сбой помощника на именах тоже не теряет расшифровку: имена по порядку.
    assert "] Анна:" in (d / "transcript.txt").read_text()
    assert json.loads((d / "call.json").read_text())["status"] == "done"


def test_summary_written(tmp_path, capsys, fakes, monkeypatch):
    monkeypatch.setattr(llm, "backend", lambda settings=None: ("claude", "/bin/claude"))
    monkeypatch.setattr(llm, "run", lambda prompt, cwd, **kw: (
        ('{"Собеседник": "Анна"}' if "JSON" in prompt else "## Коротко\nДоговорились."), "claude", ""))
    d = make_call(tmp_path, {"id": "2026-11-04 15-01", "summary": True})
    assert run.main([str(d), "--no-diarize"]) == 0
    assert (d / "summary.md").read_text() == "## Коротко\nДоговорились.\n"
    assert "## Расшифровка" in (d / "transcript.md").read_text()


def test_summary_off_in_call_json(tmp_path, capsys, fakes, monkeypatch):
    called = []
    monkeypatch.setattr(llm, "backend", lambda settings=None: ("claude", "/bin/claude"))
    monkeypatch.setattr(llm, "run", lambda *a, **kw: called.append(1) or (None, "claude", "x"))
    d = make_call(tmp_path, {"id": "2026-11-04 15-01", "summary": False})
    assert run.main([str(d), "--no-diarize"]) == 0
    assert called == [] and not (d / "summary.md").exists()


def test_system_labels_use_voice_order_not_label_text():
    diar = [(0, 2, "SPEAKER_07"), (2, 4, "SPEAKER_00"), (4, 6, "SPEAKER_07")]
    segs = [(0.1, 1.9, "а"), (2.1, 3.9, "б"), (4.1, 5.0, "в"), (10, 11, "г")]
    labeled, n = speakers.label_system(segs, diar, ["Анна"])
    assert n == 2
    assert [w for *_, w in labeled] == ["Анна", "Собеседник 2", "Анна", "Собеседник"]


def test_diarization_failure_keeps_text(monkeypatch):
    monkeypatch.setattr(speakers.diarize, "available", lambda: True)
    logs = []

    def boom(path, k=None):
        raise RuntimeError("no mps")
    items = speakers.assign_speakers(mic=[(0, 1, "я")], mic_dead=[], system=[(2, 3, "они")], tracks={"system": "s"},
                                     me="Я", names=[], speakers=None, diarize_on=True, single_name=None,
                                     log=logs.append, run_diarization=boom)
    assert [w for *_, w in items] == ["Я", "Собеседник"] and "диаризация не удалась" in logs[0]


def test_mic_fallback_finds_my_voice(monkeypatch):
    monkeypatch.setattr(speakers.diarize, "available", lambda: True)
    diar = [(0, 10, "A"), (10, 20, "B"), (20, 30, "A"), (30, 40, "C")]
    mic_dead = [(11, 19, "чужое"), (21, 29, "моё"), (31, 39, "третье")]
    ref = [(1, 9, "я до пропуска")]
    items = speakers.assign_speakers(mic=ref, mic_dead=mic_dead, system=[], tracks={"mic": "m"}, me="Я",
                                     names=["Анна"], speakers=2, diarize_on=True, single_name=None,
                                     log=lambda m: None, run_diarization=lambda p, k: diar)
    assert [w for *_, w in items] == ["Я", "Анна", "Я", "Собеседник 2"]


def test_bin_script_runs_standalone(tmp_path):
    import subprocess
    import sys
    engine = Path(__file__).resolve().parent.parent
    r = subprocess.run([sys.executable, str(engine / "bin" / "process_call.py"), str(tmp_path / "nope")],
                       capture_output=True, text=True, timeout=120,
                       env={"PATH": "/usr/bin:/bin", "SOZVON_DATA_DIR": str(tmp_path), "SOZVON_UI_LANG": "en",
                            "HOME": str(tmp_path)})
    assert r.returncode == 2, r.stderr
    assert r.stdout.strip().splitlines()[-1].startswith("RESULT: error 2 call folder not found")
