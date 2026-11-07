"""bin/process_call.py: call.json as the source of truth, exit codes and the RESULT line (with fakes)."""
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
    """Model "downloaded", ffmpeg and Whisper faked: checks only the stages and files."""
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
    assert c["participants"] == ["Анна"]
    assert not list(d.glob("*.wav"))


def test_info_pending_is_ignored(tmp_path, capsys, fakes):
    """The app's "Later" flag (info_pending) means nothing to the engine: the call transcribes as usual."""
    d = make_call(tmp_path, {"schema": 1, "id": "2026-11-04 15-01", "status": "recorded", "info_pending": True,
                             "names": ["Анна"], "languages": "ru"})
    assert run.main([str(d), "--no-diarize", "--no-summary"]) == 0
    assert result(capsys) == "RESULT: ok"
    c = json.loads((d / "call.json").read_text())
    assert c["status"] == "done" and c["info_pending"] is True and c["schema"] == 1


def test_cli_overrides_call_json(tmp_path, capsys, fakes):
    d = make_call(tmp_path, {"id": "2026-11-04 15-01", "names": ["Анна"], "topic": "старая", "languages": "ru"})
    assert run.main([str(d), "--no-diarize", "--names", "Иван, Олег", "--topic", "новая",
                     "--language", "en", "--me", "Олег"]) == 0
    c = json.loads((d / "call.json").read_text())
    # The arguments are written back as typed; "Олег" is the user (--me), never a participant.
    assert c["names"] == ["Иван", "Олег"] and c["participants"] == ["Иван"]
    assert c["topic"] == "новая" and c["languages"] == "en"
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
    # An assistant failure on names does not lose the transcript either: names fall back to order.
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


def test_imported_system_only_call(tmp_path, capsys, fakes, monkeypatch):
    """An imported recording (the Calls window): only system.m4a at offset 0, status recorded."""
    def system_only(tr, **kw):
        fakes.update(kw, tracks=tr)
        return {"system": [(1.0, 4.0, "Бюджет согласован.")]}, {"system": "ru"}
    monkeypatch.setattr(transcribe, "transcribe_tracks", system_only)
    d = make_call(tmp_path, {"schema": 1, "id": "2026-11-04 15-01", "status": "recorded",
                             "audio": {"system_start": 0.0, "system_seconds": 4.0}, "names": ["Анна"]},
                  tracks_=("system",))
    assert tracks.track_files(d).keys() == {"system"}
    assert tracks.delays({"system_start": 0.0}) == {"mic": 0.0, "system": 0.0}
    assert run.main([str(d), "--no-diarize"]) == 0
    assert result(capsys) == "RESULT: ok"
    assert set(fakes["tracks"]) == {"system"}
    assert (d / "transcript.txt").read_text() == "[00:01] Анна: Бюджет согласован.\n"


def test_marks_from_call_json():
    from sozvon_engine.pipeline.run import _marks
    assert _marks([30, 12.5, -1, "x", True]) == [12.5, 30.0]
    assert _marks(None) == []


def test_summary_only_needs_a_transcript(tmp_path, capsys):
    from sozvon_engine.pipeline import run
    d = tmp_path / "2026-11-04 15-01"
    d.mkdir()
    (d / "call.json").write_text('{"schema": 1, "id": "2026-11-04 15-01", "status": "done"}', encoding="utf-8")
    assert run.main([str(d), "--summary-only"]) != 0
    assert "RESULT: error" in capsys.readouterr().out
    assert '"done"' in (d / "call.json").read_text(encoding="utf-8"), "the status is left alone"


def test_participants_in_call_json_follow_the_transcript(tmp_path, capsys, fakes, monkeypatch):
    """Recognized names go to call.json "participants" in the order they first speak; typed names that never
    spoke stay; generic labels and the user never do. The summary prompt gets the same participants. "names"
    stays what the user typed: found names are never fed back as typed on the next transcription."""
    def two_voices(tr, **kw):
        return ({"mic": [(0.0, 2.0, "Влад, Аня, привет.")],
                 "system": [(3.0, 5.0, "Привет, Борис."), (6.0, 8.0, "Привет."), (9.0, 10.0, "Угу.")]},
                {"mic": "ru", "system": "ru"})
    monkeypatch.setattr(transcribe, "transcribe_tracks", two_voices)
    monkeypatch.setattr(speakers.diarize, "available", lambda: True)
    monkeypatch.setattr(speakers.diarize, "run", lambda path, k=None: [
        (3.0, 5.0, "A"), (6.0, 8.0, "B"), (9.0, 10.0, "C")])
    monkeypatch.setattr(run.voices, "identify", lambda *a, **kw: {"B": ("Влад", 0.9)})
    monkeypatch.setattr(llm, "backend", lambda settings=None: ("claude", "/bin/claude"))
    prompts_seen = []

    def assistant(prompt, cwd, **kw):
        prompts_seen.append(prompt)
        return ('{"Собеседник 1": "Анна Петрова", "Собеседник 3": null}' if "JSON" in prompt
                else "## Коротко\nОк."), "claude", ""
    monkeypatch.setattr(llm, "run", assistant)
    monkeypatch.setenv("SOZVON_ME", "Борис")
    d = make_call(tmp_path, {"id": "2026-11-04 15-01", "names": ["Олег", "Анна", "Борис"]})
    assert run.main([str(d)]) == 0
    txt = (d / "transcript.txt").read_text()
    assert "] Анна Петрова: Привет, Борис." in txt and "] Влад: Привет." in txt and "] Собеседник 3: Угу." in txt
    c = json.loads((d / "call.json").read_text())
    # Speaking order first ("Анна" folds into "Анна Петрова"), then "Олег" who never spoke; no "Борис".
    assert c["participants"] == ["Анна Петрова", "Влад", "Олег"]
    assert c["names"] == ["Олег", "Анна", "Борис"], "the typed names are left as typed"
    assert "Другие участники: Анна Петрова, Влад, Олег." in prompts_seen[-1]
    # Transcribing again: the assistant is told only the typed names are certain, not its own earlier guesses.
    prompts_seen.clear()
    assert run.main([str(d)]) == 0
    asked = next(p for p in prompts_seen if "JSON" in p)
    assert "Точно были на звонке: Олег, Анна." in asked and "Анна Петрова" not in asked.split("Расшифровка:")[0]


def test_summary_only_writes_participants_from_the_edited_transcript(tmp_path, capsys, monkeypatch):
    monkeypatch.setattr(llm, "backend", lambda settings=None: ("claude", "/bin/claude"))
    seen = []
    monkeypatch.setattr(llm, "run", lambda prompt, cwd, **kw: (seen.append(prompt) or "## Коротко\nОк.", "claude", ""))
    d = make_call(tmp_path, {"schema": 1, "id": "2026-11-04 15-01", "status": "done", "names": ["Павел"]})
    (d / "transcript.txt").write_text("[00:00] Я: Привет.\n[00:03] Собеседник 2: Привет.\n[00:05] Ира: Да.\n",
                                      encoding="utf-8")
    assert run.main([str(d), "--summary-only"]) == 0
    c = json.loads((d / "call.json").read_text())
    assert c["participants"] == ["Ира", "Павел"] and c["names"] == ["Павел"]
    assert "Другие участники: Ира, Павел." in seen[0]
    assert (d / "transcript.txt").read_text().startswith("[00:00] Я: Привет."), "the edited text stays"


def test_typed_own_name_never_labels_a_remote_voice(tmp_path, capsys, fakes, monkeypatch):
    """The user typed their own name among the participants: the other side is not labeled with it."""
    monkeypatch.setenv("SOZVON_ME", "Борис")
    d = make_call(tmp_path, {"id": "2026-11-04 15-01", "names": ["Борис"]})
    assert run.main([str(d), "--no-diarize"]) == 0
    assert (d / "transcript.txt").read_text() == "[00:00] Борис: Привет, давай начнём.\n[00:03] Собеседник: Бюджет согласован.\n"
    c = json.loads((d / "call.json").read_text())
    assert c["names"] == ["Борис"] and c["participants"] == []


def test_project_people_with_my_full_name_are_not_candidates(tmp_path, capsys, fakes, monkeypatch, profiles):
    (profiles / "acme.json").write_text(json.dumps({"title": "Acme", "people": ["Борис Иванов", "Анна"]},
                                                   ensure_ascii=False))
    monkeypatch.setenv("SOZVON_ME", "Борис Иванов")
    monkeypatch.setattr(llm, "backend", lambda settings=None: ("claude", "/bin/claude"))
    seen = []
    monkeypatch.setattr(llm, "run", lambda prompt, cwd, **kw: (seen.append(prompt) or '{"Собеседник": "Анна"}',
                                                               "claude", ""))
    d = make_call(tmp_path, {"id": "2026-11-04 15-01", "profile": "acme"})
    assert run.main([str(d), "--no-diarize"]) == 0
    assert "Возможные участники: Анна." in seen[0] and "JSON" in seen[0]


def test_phrase_tail_just_after_a_turn_keeps_its_voice():
    """Whisper's word times put "утром." just after the diarization turn ends: it is that voice, not a new
    unnamed speaker; a phrase far from every turn stays unknown."""
    diar = [(6.0, 11.8, "A"), (13.0, 17.0, "B")]
    segs = [(6.1, 11.7, "Бюджет согласован, стартуем в понедельник"), (11.9, 12.4, "утром."),
            (13.1, 16.9, "Меня зовут Анна"), (30.0, 31.0, "алло")]
    labeled, n = speakers.label_system(segs, diar, [])
    assert n == 2
    assert [w for *_, w in labeled] == ["Собеседник 1", "Собеседник 1", "Собеседник 2", "Собеседник"]


def test_transcribing_again_expects_every_voice_of_the_last_transcript(tmp_path, capsys, fakes, monkeypatch):
    """call.json names list only the named people: a call with "Влад" and an unnamed "Собеседник 2" is
    diarized again for two voices, not one (which would put both under Влад)."""
    seen = {}
    monkeypatch.setattr(speakers.diarize, "available", lambda: True)
    monkeypatch.setattr(speakers.diarize, "run", lambda path, k=None: seen.setdefault("k", k) and [(3.0, 5.0, "A")])
    monkeypatch.setattr(run.voices, "identify", lambda *a, **kw: {})
    d = make_call(tmp_path, {"id": "2026-11-04 15-01", "status": "done", "names": ["Влад"]})
    (d / "transcript.txt").write_text("[00:00] Я: Привет.\n[00:03] Влад: Да.\n[00:05] Собеседник 2: Ага.\n"
                                      "[00:07] Я + собеседники: шум\n", encoding="utf-8")
    assert run.main([str(d)]) == 0
    assert seen["k"] == 2


@pytest.mark.parametrize("txt,names,k", [
    # A first run without diarization: one plain label for everyone else. Not one voice: let diarization count.
    ("[00:00] Я: Привет.\n[00:03] Собеседник: Да.\n", [], None),
    # A stray plain label next to numbered ones is no extra voice.
    ("[00:00] Собеседник 1: Да.\n[00:03] Собеседник 2: Нет.\n[00:05] Собеседник: Ага.\n", [], 2),
    # The user is never counted, in any case; nor "<me> + others".
    ("[00:00] я: Да.\n[00:03] me + OTHERS: шум\n[00:05] Анна: Ага.\n", [], 1),
    # Typed names count when more of them were typed than voices were heard.
    ("[00:00] Собеседник: Да.\n", ["Анна", "Олег", "Я"], 2),
])
def test_voices_heard_counts_only_labels_that_stand_for_a_voice(tmp_path, capsys, fakes, monkeypatch, txt, names, k):
    seen = {}
    monkeypatch.setattr(speakers.diarize, "available", lambda: True)
    monkeypatch.setattr(speakers.diarize, "run", lambda path, k=None: seen.setdefault("k", k) and [(3.0, 5.0, "A")])
    monkeypatch.setattr(run.voices, "identify", lambda *a, **kw: {})
    d = make_call(tmp_path, {"id": "2026-11-04 15-01", "status": "done", "names": names})
    (d / "transcript.txt").write_text(txt, encoding="utf-8")
    assert run._voices_heard(d, "Я") == (0 if names else k or 0)
    assert run.main([str(d)]) == 0
    assert seen["k"] == k


def test_summary_only_with_auto_languages(tmp_path, capsys, monkeypatch):
    """languages "auto" (no fixed language) used to crash --summary-only with a TypeError."""
    monkeypatch.setattr(llm, "backend", lambda settings=None: ("claude", "/bin/claude"))
    monkeypatch.setattr(llm, "run", lambda prompt, cwd, **kw: ("## Summary\nOk.", "claude", ""))
    d = make_call(tmp_path, {"schema": 1, "id": "2026-11-04 15-01", "status": "done", "languages": "auto"})
    (d / "transcript.txt").write_text("[00:00] Я: Hi.\n[00:03] Ann: Hello.\n", encoding="utf-8")
    assert run.main([str(d), "--summary-only"]) == 0
    assert (d / "summary.md").read_text() == "## Summary\nOk.\n"


def test_summary_off_keeps_the_text_on_the_mac(tmp_path, capsys, fakes, monkeypatch):
    """The summary unchecked ("the text goes to Anthropic"): speaker naming does not send the transcript to
    the assistant either; the typed names go to the voices in order."""
    called = []
    monkeypatch.setattr(llm, "backend", lambda settings=None: ("claude", "/bin/claude"))
    monkeypatch.setattr(llm, "run", lambda *a, **kw: called.append(1) or ('{"Собеседник": "Олег"}', "claude", ""))
    d = make_call(tmp_path, {"id": "2026-11-04 15-01", "names": ["Анна", "Олег"], "summary": False})
    assert run.main([str(d), "--no-diarize"]) == 0
    assert called == []
    assert "] Собеседник: Бюджет согласован." in (d / "transcript.txt").read_text()
    assert json.loads((d / "call.json").read_text())["participants"] == ["Анна", "Олег"]


def test_a_name_taken_by_a_voice_print_is_not_given_again_ignoring_case():
    diar = [(0, 2, "A"), (2, 4, "B")]
    segs = [(0.1, 1.9, "а"), (2.1, 3.9, "б")]
    labeled, _ = speakers.label_system(segs, diar, ["влад", "Анна"], known={"B": "Влад"})
    assert [w for *_, w in labeled] == ["Анна", "Влад"]
