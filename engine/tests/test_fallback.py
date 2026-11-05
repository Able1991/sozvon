"""Whisper fallback retry and the shared segment filter."""
from sozvon_engine import whisper


class FakeWhisper:
    def __init__(self, answers):
        self.answers = answers
        self.prompts = []

    def __call__(self, audio, path_or_hf_repo, language, initial_prompt=None, **kw):
        self.prompts.append(initial_prompt)
        return {"segments": [{"text": t} for t in self.answers[len(self.prompts) - 1]]}


def test_garbage_with_long_prompt_triggers_retry(monkeypatch):
    garbage = "ru, c'f-5,2,0,6," + "0," * 150  # as in a real failure with a 196-token prompt
    fake = FakeWhisper([[garbage], ["Привет, пока."]])
    monkeypatch.setattr(whisper, "_transcribe", fake)
    segs, used = whisper.whisper_with_fallback("a.wav", "repo", "ru", "длинная подсказка", "короткая")
    assert used == "короткая"
    assert fake.prompts == ["длинная подсказка", "короткая"]
    assert segs[0]["text"] == "Привет, пока."


def test_normal_result_no_retry(monkeypatch):
    fake = FakeWhisper([["Нормальный текст звонка."]])
    monkeypatch.setattr(whisper, "_transcribe", fake)
    segs, used = whisper.whisper_with_fallback("a.wav", "repo", "ru", "подсказка", "короткая")
    assert used == "подсказка" and len(fake.prompts) == 1


def test_no_retry_when_prompts_equal(monkeypatch):
    fake = FakeWhisper([["ерсти" * 30]])
    monkeypatch.setattr(whisper, "_transcribe", fake)
    _, used = whisper.whisper_with_fallback("a.wav", "repo", "ru", "та же", "та же")
    assert len(fake.prompts) == 1


def test_clean_segments_filters_noise_and_uses_word_bounds():
    segs = [
        {"start": 0.0, "end": 5.0, "text": " Кубер упал ", "words": [{"start": 0.4, "end": 1.0}, {"start": 1.1, "end": 1.6}]},
        {"start": 5.0, "end": 6.0, "text": "Продолжение следует..."},
        {"start": 6.0, "end": 7.0, "text": "ерсти" * 30},
        {"start": 7.0, "end": 8.0, "text": "  "},
        {"start": 8.0, "end": 9.0, "text": "Что-то", "no_speech_prob": 0.9, "avg_logprob": -1.5},
        {"start": 9.0, "end": 10.0, "text": "Да."},
    ]
    out = whisper.clean_segments(segs, [["кубер", "Kubernetes"]])
    assert out == [(0.4, 1.6, "Kubernetes упал"), (9.0, 10.0, "Да.")]


def test_replacement_with_backslash_is_literal():
    assert whisper.apply_replacements("путь", [["путь", r"C:\new"]]) == r"C:\new"
