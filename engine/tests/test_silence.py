"""Whisper writes text on a track with no speech ("Thank you." on a raised room tone): a line goes when the
speech detector (silero) hears no voice under it."""
from pathlib import Path

from sozvon_engine import install, models, vad
from sozvon_engine.pipeline import silence, transcribe


def test_a_line_over_silence_goes():
    pieces = [(10.0, 11.0, "Thank you."), (30.0, 32.0, "Привет, как дела?")]
    kept, dropped = transcribe.drop_unheard(pieces, [(29.5, 33.0)])
    assert kept == [(30.0, 32.0, "Привет, как дела?")] and dropped == 1


def test_a_line_just_beside_a_voice_stays():
    # Word times and the detector's edges disagree by a few tenths of a second: the line is still speech.
    kept, dropped = transcribe.drop_unheard([(5.0, 5.6, "Да.")], [(5.8, 7.0)])
    assert kept == [(5.0, 5.6, "Да.")] and dropped == 0


def test_no_voice_at_all_leaves_nothing():
    pieces = [(t, t + 1.0, "Thank you.") for t in range(0, 600, 30)]
    assert transcribe.drop_unheard(pieces, []) == ([], len(pieces))


class Prompts:
    replacements = []

    @staticmethod
    def build(lang):
        return "", ""


def fake_whisper(monkeypatch, texts):
    from sozvon_engine import whisper
    segs = [{"start": 30.0 * i, "end": 30.0 * i + 1.0, "text": t} for i, t in enumerate(texts)]
    monkeypatch.setattr(whisper, "whisper_with_fallback", lambda *a, **k: (segs, ""))
    monkeypatch.setattr(transcribe.langid, "Detector", lambda path: None)


def test_whisper_lines_without_a_voice_are_dropped(monkeypatch, data):
    fake_whisper(monkeypatch, ["Thank you.", "Привет, как дела?", "Thank you."])
    monkeypatch.setattr(vad, "available", lambda d: True)
    monkeypatch.setattr(vad, "speech_spans", lambda d, wav: [(29.8, 31.5)])
    log = []
    segs, _ = transcribe.transcribe_tracks({"mic": Path("mic.wav")}, data_dir=data, model="turbo",
                                           model_path="m", allowed=["ru"], switch=False, prompts=Prompts,
                                           log=log.append)
    assert segs["mic"] == [(30.0, 31.0, "Привет, как дела?")]
    assert any("2" in line for line in log)


def test_without_the_detector_whisper_lines_stay(monkeypatch, data):
    fake_whisper(monkeypatch, ["Thank you.", "Привет, как дела?"])
    monkeypatch.setattr(vad, "available", lambda d: False)
    segs, _ = transcribe.transcribe_tracks({"mic": Path("mic.wav")}, data_dir=data, model="turbo",
                                           model_path="m", allowed=["ru"], switch=False, prompts=Prompts,
                                           log=lambda s: None)
    assert len(segs["mic"]) == 2


class FakeHub:
    def __init__(self):
        self.repos = []

    def __call__(self, repo, filename, revision, local_dir):
        self.repos.append(repo)
        Path(local_dir, filename).write_text("weights")


def test_whisper_models_get_the_speech_detector_too(tmp_path):
    hub = FakeHub()
    install.ensure_model(tmp_path, "turbo", hub)
    assert hub.repos[-1] == models.VAD["repo"]
    assert vad.available(tmp_path)


def test_head_tail_from_paragraphs():
    paras = [(372.4, 380.0, "Привет", "Anna"), (900.0, 3301.2, "Пока", "Me")]
    assert silence.head_tail(paras, 3600.0) == {"head": 372.4, "tail": 298.8}


def test_no_speech_is_all_head():
    assert silence.head_tail([], 125.0) == {"head": 125.0, "tail": 0.0}


def test_speech_past_the_duration_never_goes_negative():
    assert silence.head_tail([(1.0, 130.0, "x", "A")], 125.0) == {"head": 1.0, "tail": 0.0}


def test_call_duration_counts_each_track_offset():
    meta = {"mic_seconds": 100.0, "system_seconds": 90.0}
    assert silence.call_duration(meta, {"mic": 0.0, "system": 20.0}) == 110.0
    assert silence.call_duration({}, {"mic": 0.0, "system": 0.0}) == 0.0


def test_complete_writes_silence_and_a_later_run_without_it_removes_it(tmp_path, monkeypatch):
    from sozvon_engine import calls, remote
    from sozvon_engine.pipeline import run

    monkeypatch.setattr(remote, "push_after_transcription", lambda d, log: None)
    calls.write_call(tmp_path, {"id": "x", "status": "transcribing"})
    spec = run.CallSpec(dir=tmp_path, id="x", me="Me")
    run.complete(spec, [], {"head": 372.4, "tail": 298.8})
    assert calls.read_call(tmp_path)["silence"] == {"head": 372.4, "tail": 298.8}
    run.complete(spec, [])
    assert "silence" not in calls.read_call(tmp_path)
