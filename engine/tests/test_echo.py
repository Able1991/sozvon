"""Removing the other side's echo from the microphone."""
from sozvon_engine.pipeline import tracks as pc


def test_echo_of_remote_phrase_is_dropped():
    system = [(10.0, 13.0, "Давай обсудим запуск кампании на следующей неделе.")]
    mic = [(10.4, 13.2, "давай обсудим запуск кампании на следующей неделе"),
           (20.0, 21.0, "Да, согласен.")]
    kept, dropped = pc.drop_echo(mic, system)
    assert dropped == 1
    assert kept == [(20.0, 21.0, "Да, согласен.")]


def test_own_speech_overlapping_in_time_is_kept():
    system = [(10.0, 13.0, "Давай обсудим запуск кампании.")]
    mic = [(11.0, 12.0, "Подожди, у меня вопрос по бюджету.")]
    kept, dropped = pc.drop_echo(mic, system)
    assert dropped == 0 and len(kept) == 1


def test_same_phrase_far_in_time_is_kept():
    system = [(10.0, 13.0, "Давай обсудим запуск кампании.")]
    mic = [(100.0, 103.0, "Давай обсудим запуск кампании.")]
    kept, dropped = pc.drop_echo(mic, system)
    assert dropped == 0


def test_norm_ignores_case_and_punctuation():
    assert pc._norm("Привет,  МИР!") == "привет мир"


def test_short_reply_during_the_other_side_is_kept():
    """"Да." while the other side says "когда" nearby: its two letters match, but it is my reply."""
    system = [(10.0, 13.0, "Когда стартуем?")]
    mic = [(13.2, 13.5, "Да."), (11.0, 13.0, "когда стартуем")]
    kept, dropped = pc.drop_echo(mic, system)
    assert kept == [(13.2, 13.5, "Да.")] and dropped == 1
