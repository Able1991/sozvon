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


def test_words_without_times_fall_back_to_the_segment():
    """A first or last word without a time used to raise KeyError: the segment's own bounds instead."""
    seg = {"start": 2.0, "end": 4.0, "text": " Да, конечно.", "words": [{"word": " Да,"}, {"word": " конечно.", "start": 2.5}]}
    assert whisper.clean_segments([seg], []) == [(2.0, 4.0, "Да, конечно.")]


def test_replacement_with_backslash_is_literal():
    assert whisper.apply_replacements("путь", [["путь", r"C:\new"]]) == r"C:\new"


def test_segments_split_by_sentence_and_pause():
    """One Whisper segment with the end of one phrase and the start of the next person's: split by the words'
    sentence ends and pauses, so diarization can label each piece; noise pieces go."""
    w = lambda s, e, word: {"start": s, "end": e, "word": word}  # noqa: E731
    seg = {"start": 6.0, "end": 18.0, "text": " Стартуем утром. Меня зовут Анна да",
           "words": [w(6.1, 6.8, " Стартуем"), w(6.9, 7.5, " утром."), w(13.0, 13.4, " Меня"),
                     w(13.5, 13.9, " зовут"), w(14.0, 14.5, " Анна"), w(16.0, 16.3, " да")]}
    assert whisper.clean_segments([seg], []) == [(6.1, 7.5, "Стартуем утром."), (13.0, 14.5, "Меня зовут Анна"),
                                                 (16.0, 16.3, "да")]
    tag = {"start": 0, "end": 3, "text": " Музыка. Добрый день.",
           "words": [w(0.0, 0.5, " Музыка."), w(1.0, 1.5, " Добрый"), w(1.6, 2.0, " день.")]}
    assert whisper.clean_segments([tag], []) == [(1.0, 2.0, "Добрый день.")]
