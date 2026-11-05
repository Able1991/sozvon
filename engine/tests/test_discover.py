"""Parsing the project discovery response and writing profiles."""
import json

from sozvon_engine import discover as dp


def test_parse_plain_array():
    assert dp.parse_items('[{"slug": "a"}]') == [{"slug": "a"}]


def test_parse_with_text_around_and_brackets_after():
    text = 'Вот проекты:\n[{"slug": "a", "terms": ["x"]}]\n\nПримечание: [см. выше] и ещё [1].'
    assert dp.parse_items(text) == [{"slug": "a", "terms": ["x"]}]


def test_parse_skips_non_project_arrays():
    text = 'Смотрел папки [1, 2, 3], итог: [{"slug": "b"}]'
    assert dp.parse_items(text) == [{"slug": "b"}]


def test_parse_nothing():
    assert dp.parse_items("ничего не нашёл") is None
    assert dp.parse_items("[]") is None


def test_apply_creates_and_merges(tmp_path):
    (tmp_path / "acme.json").write_text(json.dumps(
        {"title": "Acme", "people": ["Анна"], "terms": ["HPA"], "replacements": [["a", "b"]]}, ensure_ascii=False))
    created, updated = dp.apply_projects([
        {"slug": "acme", "title": "Другое имя", "people": ["Анна", "Иван"], "terms": ["HPA", "k8s"]},
        {"slug": "Новый Проект!", "title": "Только кириллица"},
        {"slug": "beta", "title": "Beta", "people": ["Олег"], "terms": [f"t{i}" for i in range(40)]},
        "мусор",
    ], tmp_path)
    assert created == ["Beta"] and updated == ["Acme"]
    acme = json.loads((tmp_path / "acme.json").read_text())
    assert acme["title"] == "Acme"  # the name is not overwritten
    assert acme["people"] == ["Анна", "Иван"] and acme["terms"] == ["HPA", "k8s"]
    assert acme["replacements"] == [["a", "b"]]
    beta = json.loads((tmp_path / "beta.json").read_text())
    assert len(beta["terms"]) == 25


def test_apply_unchanged_is_not_reported(tmp_path):
    (tmp_path / "acme.json").write_text(json.dumps({"title": "Acme", "people": ["Анна"], "terms": []}))
    created, updated = dp.apply_projects([{"slug": "acme", "people": ["Анна"]}], tmp_path)
    assert created == [] and updated == []


def test_describe_steps(monkeypatch):
    monkeypatch.setenv("SOZVON_UI_LANG", "ru")
    st = {"asked": 0, "read": 0}
    assert dp.describe("ListAgents", {}, st) == "Смотрю открытые сессии"
    assert dp.describe("SendMessage", {"to": "uds:/tmp/cc-socks/123.sock"}, st) == "Спрашиваю сессию «123» (1)"
    assert dp.describe("SendMessage", {"to": "acme [ab12]"}, st) == "Спрашиваю сессию «acme» (2)"
    r = dp.describe("Read", {"file_path": "/Users/x/.claude/projects/-Users-x-Workspace-acme/memory/a.md"}, st)
    assert r == "Читаю заметки: acme (1)"
    assert dp.describe("Grep", {}, st) == "Ищу по истории проектов"
    monkeypatch.setenv("SOZVON_UI_LANG", "en")
    assert dp.describe("ListAgents", {}, st) == "Looking at open sessions"


def test_apply_matches_existing_project_by_title(tmp_path):
    (tmp_path / "acme.json").write_text(json.dumps(
        {"title": "Acme Group (Акме)", "people": ["Алексей"], "terms": []}, ensure_ascii=False))
    created, updated = dp.apply_projects([
        {"slug": "akme", "title": "Акме (Acme Group)", "people": ["Евгений"], "terms": ["HPA"]},
    ], tmp_path)
    assert created == [] and updated == ["Acme Group (Акме)"]
    assert sorted(p.name for p in tmp_path.glob("*.json")) == ["acme.json"]
    d = json.loads((tmp_path / "acme.json").read_text())
    assert d["people"] == ["Алексей", "Евгений"] and d["terms"] == ["HPA"]


def test_apply_adds_replacements(tmp_path):
    created, _ = dp.apply_projects([{"slug": "acme", "title": "Acme",
                                     "replacements": [["акме", "Acme"], ["bad"], ["", "x"]]}], tmp_path)
    d = json.loads((tmp_path / "acme.json").read_text())
    assert d["replacements"] == [["акме", "Acme"]]
    dp.apply_projects([{"slug": "acme", "title": "Acme", "replacements": [["АКМЕ", "Acme"], ["эй пи ай", "API"]]}], tmp_path)
    d = json.loads((tmp_path / "acme.json").read_text())
    assert d["replacements"] == [["акме", "Acme"], ["эй пи ай", "API"]]
