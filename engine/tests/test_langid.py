"""Language detection among allowed languages and mid-speech language switching (no model)."""
import numpy as np

from sozvon_engine import langid


def test_parse_languages():
    assert langid.parse_languages("ru") == ["ru"]
    assert langid.parse_languages("ru, en,ru") == ["ru", "en"]
    assert langid.parse_languages("auto") is None
    assert langid.parse_languages("") is None
    assert langid.parse_languages("ru,auto") is None


def test_pick_respects_allowed():
    probs = {"uk": 0.5, "ru": 0.3, "en": 0.1, "bg": 0.1}
    assert langid.pick(probs, None)[0] == "uk"
    lang, share = langid.pick(probs, ["ru", "en"])
    assert lang == "ru" and abs(share - 0.75) < 1e-9


def test_pick_when_allowed_missing_from_probs():
    assert langid.pick({"de": 1.0}, ["ru", "en"]) == ("ru", 0.0)


def test_speech_windows_prefers_loud_parts():
    sr = langid.SR
    quiet = np.zeros(60 * sr, np.float32)
    loud = np.full(30 * sr, 0.5, np.float32)
    audio = np.concatenate([quiet, loud, quiet])
    w = langid.speech_windows(audio, n=1)[0]
    assert float(np.mean(w)) == 0.5


def test_detect_track_averages_windows():
    sr = langid.SR
    audio = np.ones(95 * sr, np.float32)
    answers = iter([{"ru": 0.6, "en": 0.4}, {"ru": 0.2, "en": 0.8}, {"ru": 0.3, "en": 0.7}])
    lang, share = langid.detect_track(audio, ["ru", "en"], lambda w: next(answers))
    assert lang == "en" and 0.6 < share < 0.7


def test_relabel_switches_only_confident_foreign_phrases():
    sr = langid.SR
    audio = np.zeros(20 * sr, np.float32)
    segs = [(0.0, 3.0, "привет"), (4.0, 7.0, "how are you"), (8.0, 8.5, "ok"), (10.0, 13.0, "сомнительно")]
    detections = iter([{"ru": 0.9, "en": 0.1}, {"ru": 0.1, "en": 0.9}, {"ru": 0.4, "en": 0.6}])
    calls = []

    def retr(chunk, lang):
        calls.append(lang)
        return "How are you?"

    out, n = langid.relabel(audio, segs, "ru", ["ru", "en"], lambda c: next(detections), retr)
    assert n == 1 and calls == ["en"]
    assert out[1] == (4.0, 7.0, "How are you?")
    assert out[0][2] == "привет" and out[2][2] == "ok" and out[3][2] == "сомнительно"


def test_relabel_noop_for_single_language():
    segs = [(0.0, 3.0, "привет")]
    out, n = langid.relabel(np.zeros(5 * langid.SR, np.float32), segs, "ru", ["ru"],
                            lambda c: 1 / 0, lambda c, l: 1 / 0)
    assert out == segs and n == 0
