"""Ranked call search: stemming, FTS queries, phrasings, coverage, incremental index sync."""
import json
import os
import stat
import time

import pytest

from sozvon_engine import search
from sozvon_engine.mcp import tools
from sozvon_engine.textproc import fts_query, stem, words


def make_call(root, folder, transcript="", summary=None, **call):
    d = root / folder
    d.mkdir(parents=True, exist_ok=True)
    (d / "call.json").write_text(json.dumps(call, ensure_ascii=False))
    if transcript:
        (d / "transcript.txt").write_text(transcript)
    if summary is not None:
        (d / "summary.md").write_text(summary)
    return d


@pytest.fixture
def root(tmp_path):
    return tmp_path / "Calls"


def ids(hits):
    return [h.call_id for h in hits]


def test_stemming_matches_russian_inflections():
    assert stem("бюджета") == stem("бюджет") == stem("Бюджетом")
    assert stem("budgets") == stem("budget")
    assert words("Привет, IP 10.0.0.1!") == ["привет", "ip", "10", "0", "0", "1"]


@pytest.mark.parametrize("q, want", [
    ("", ""),
    ('"" \' " ()*', ""),
    ("10.9.8.7", '"10 9 8 7"'),
    ("node-selector", '"node selector"'),
    ('say "hello" AND NOT world', '"say" OR "hello" OR "and" OR "not" OR "world"'),
    ("бюджет бюджета", '"бюджет"'),
])
def test_fts_query_odd_tokens(q, want):
    assert fts_query(q) == want


def test_fts_query_is_valid_fts5(root):
    make_call(root, "2026-01-01 10-00", "[00:01] Я: сервер 10.9.8.7 и node-selector\n", id="2026-01-01 10-00")
    for q in ["10.9.8.7", "node-selector", 'a "b', "NOT", "AND OR", "*", "x:y", "ё"]:
        search.search(q, root=root)  # must not raise an FTS5 syntax error


def test_russian_inflection_found(root):
    make_call(root, "2026-01-01 10-00", "[00:05] Анна: Бюджет согласован\n", id="2026-01-01 10-00")
    hits = search.search("бюджета", root=root)
    assert ids(hits) == ["2026-01-01 10-00"] and hits[0].ts == "00:05" and hits[0].speaker == "Анна"


def test_also_phrasings_improve_recall(root):
    make_call(root, "2026-01-01 10-00", "[00:05] Анна: Смета согласована\n", id="a")
    assert search.search("бюджет", root=root) == []
    assert ids(search.search("бюджет", also=["смета", "budget"], root=root)) == ["a"]


def test_coverage_ranks_lines_with_more_query_words_first(root):
    # BM25 alone puts the short line with the one rare word first; coverage prefers all three words
    lines = (["[00:01] Я: релиз"] + [f"[00:{n + 10}] Я: бюджет маркетинг обсуждали" for n in range(20)]
             + ["[00:50] Я: в этом релизе бюджет на маркетинг вырос, но подробнее потом поговорим с командой"])
    make_call(root, "2026-01-01 10-00", "\n".join(lines) + "\n", id="a")
    assert search.search("бюджет маркетинг релиз", root=root)[0].ts == "00:50"
    con = search.open_index(search.index_path())
    assert search.rank(con, ["бюджет маркетинг релиз"], 3, coverage=0)[0].ts == "00:01"


def test_dedupe_within_a_call(root):
    make_call(root, "2026-01-01 10-00", "[00:01] Я: бюджет готов\n[00:09] Я: Бюджет  готов\n", id="a")
    make_call(root, "2026-01-02 10-00", "[00:01] Я: бюджет готов\n", id="b")
    assert sorted(ids(search.search("бюджет", root=root))) == ["a", "b"]


def test_summary_chunks(root):
    make_call(root, "2026-01-01 10-00", "", summary="## Решения\n- запуск в понедельник\n\n---\n", id="a")
    [h] = search.search("запуск", root=root)
    assert (h.kind, h.speaker, h.text) == ("summary", "Решения", "- запуск в понедельник")


def test_note_chunks(root):
    d = make_call(root, "2026-01-01 10-00", "[00:01] Я: привет\n", id="a",
                  notes=[{"id": "n1", "at": "2026-01-02T08:00:00Z", "text": "Договорились о скидке\nдо пятницы",
                          "source": "codex"}])
    [h] = search.search("скидка", root=root)
    assert (h.kind, h.ts, h.speaker, h.text) == ("note", "2026-01-02", "codex", "Договорились о скидке до пятницы")
    call = json.loads((d / "call.json").read_text())
    call["notes"] = []
    (d / "call.json").write_text(json.dumps(call) + " ")  # call.json changed: reindexed
    assert search.search("скидка", root=root) == []


def test_incremental_sync(root, data):
    con = search.open_index(search.index_path())
    a = make_call(root, "2026-01-01 10-00", "[00:01] Я: альфа\n", id="a")
    assert search.sync(con, root) == 1
    assert search.sync(con, root) == 0  # nothing changed
    make_call(root, "2026-01-02 10-00", "[00:01] Я: бета\n", id="b")
    assert search.sync(con, root) == 1
    (a / "transcript.txt").write_text("[00:01] Я: гамма дельта\n")
    assert search.sync(con, root) == 1
    assert search.search("альфа", root=root) == []
    assert ids(search.search("гамма", root=root)) == ["a"]
    for f in (root / "2026-01-02 10-00").iterdir():
        f.unlink()
    (root / "2026-01-02 10-00").rmdir()
    assert search.search("бета", root=root) == []
    assert con.execute("SELECT count(*) FROM chunks").fetchone()[0] == 1
    assert con.execute("SELECT count(*) FROM chunks_fts").fetchone()[0] == 1
    if os.name != "nt":  # chmod sets no permissions on Windows: test_platform_win32.py checks the ACL of the data folder
        assert stat.S_IMODE(os.stat(search.index_path()).st_mode) == 0o600


def test_noop_sync_is_fast(root):
    for n in range(200):
        make_call(root, f"2026-01-01 10-{n:03d}", "[00:01] Я: текст звонка\n" * 50, summary="## Коротко\nок\n",
                  id=f"c{n}")
    con = search.open_index(search.index_path())
    search.sync(con, root)
    start = time.perf_counter()
    assert search.sync(con, root) == 0
    assert time.perf_counter() - start < 0.5


def test_corrupt_index_is_rebuilt(root):
    make_call(root, "2026-01-01 10-00", "[00:01] Я: альфа\n", id="a")
    search.index_path().write_bytes(b"not a database" * 100)
    assert ids(search.search("альфа", root=root)) == ["a"]


def test_other_schema_version_is_rebuilt(root):
    make_call(root, "2026-01-01 10-00", "[00:01] Я: альфа\n", id="a")
    con = search.open_index(search.index_path())
    con.execute("PRAGMA user_version = 999")
    con.execute("CREATE TABLE junk (x)")
    con.commit()
    con.close()
    assert ids(search.search("альфа", root=root)) == ["a"]
    con = search.open_index(search.index_path())
    assert con.execute("SELECT name FROM sqlite_master WHERE name = 'junk'").fetchone() is None


def test_mcp_search_calls_format(root, profiles):
    (profiles / "acme.json").write_text(json.dumps({"title": "Acme Corp"}))
    make_call(root, "2026-11-04 15-01 · Acme", "[00:05] Анна: Бюджет согласован\n" + "[01:00] Я: " + "слово " * 100,
              summary="## Решения\n- бюджет утвердили\n", id="2026-11-04 15-01", profile="acme", topic="запуск")
    make_call(root, "2026-11-05 10-00", "[00:07] Иван: смета готова\n", id="2026-11-05 10-00")
    out = tools.search_calls("бюджета", also=["смета"]).splitlines()
    assert "2026-11-04 15-01: [00:05] Анна: Бюджет согласован (запуск · Acme Corp)" in out
    assert "2026-11-04 15-01: [саммари] Решения: - бюджет утвердили (запуск · Acme Corp)" in out
    assert "2026-11-05 10-00: [00:07] Иван: смета готова" in out
    assert len(tools.search_calls("слово")) < 400  # long utterances are trimmed
    assert tools.search_calls("  ") == "Пустой запрос."
    assert tools.search_calls("несуществующее") == "Ничего не найдено."
    assert len(tools.search_calls("бюджет", limit=1).splitlines()) == 1


def test_mcp_search_calls_falls_back_to_substring(root, monkeypatch):
    make_call(root, "2026-11-04 15-01", "[00:05] Анна: Бюджет согласован\n[00:06] Я: смета\n", id="2026-11-04 15-01")

    def broken(*a, **kw):
        raise search.sqlite3.OperationalError("no such module: fts5")
    monkeypatch.setattr(search, "search", broken)
    assert tools.search_calls("бюджет") == "2026-11-04 15-01: [00:05] Анна: Бюджет согласован"
    assert tools.search_calls("нет", also=["смета"]) == "2026-11-04 15-01: [00:06] Я: смета"
    assert tools.search_calls("бюджета") == "Ничего не найдено."  # substring: no stemming


def test_query_is_bounded():
    from sozvon_engine.textproc import fts_query, MAX_PHRASES
    q = fts_query(" ".join(f"слово{i}" for i in range(3000)))
    assert q.count(" OR ") == MAX_PHRASES - 1


def test_busy_database_is_not_wiped(tmp_path, monkeypatch):
    import sqlite3
    from sozvon_engine import search
    index = tmp_path / "index.db"
    index.write_bytes(b"keep")
    monkeypatch.setattr(search, "open_index", lambda p: (_ for _ in ()).throw(sqlite3.OperationalError("database or disk is full")))
    import pytest
    with pytest.raises(sqlite3.OperationalError):
        search.search("бюджет", root=tmp_path, index=index)
    assert index.read_bytes() == b"keep"
