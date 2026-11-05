"""Merging lines into paragraphs."""
from sozvon_engine.pipeline import render as pc


def test_same_speaker_close_segments_are_glued():
    paras = pc.merge([(0, 2, "Привет.", "Я"), (2.5, 4, "Как дела?", "Я")])
    assert paras == [(0, 4, "Привет. Как дела?", "Я")]


def test_speaker_change_starts_new_paragraph():
    paras = pc.merge([(0, 2, "Привет.", "Я"), (2, 3, "Здравствуй.", "Анна"), (3, 4, "Ну что?", "Я")])
    assert [p[3] for p in paras] == ["Я", "Анна", "Я"]


def test_long_pause_splits():
    paras = pc.merge([(0, 2, "Раз.", "Я"), (60, 62, "Два.", "Я")])
    assert len(paras) == 2


def test_items_are_sorted_by_time():
    paras = pc.merge([(5, 6, "второе", "Анна"), (0, 1, "первое", "Я")])
    assert [p[2] for p in paras] == ["первое", "второе"]


def test_monologue_is_split_by_length():
    # 40 phrases of ~30 characters in a row: without a limit this would be one 1200-character wall of text.
    items = [(i * 2.0, i * 2.0 + 1.5, "Это довольно длинная фраза номер.", "Я") for i in range(40)]
    paras = pc.merge(items)
    assert len(paras) > 1
    assert all(len(p[2]) < 700 + 40 for p in paras)


def test_monologue_is_split_by_duration():
    items = [(i * 10.0, i * 10.0 + 9, "Да.", "Я") for i in range(20)]  # 200 seconds of short phrases
    paras = pc.merge(items)
    assert len(paras) >= 2
    assert all(p[0] - paras[0][0] >= 0 for p in paras)
