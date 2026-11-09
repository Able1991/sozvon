"""Commitments and people across calls: what the summaries' action items say, by person."""
import json
from pathlib import Path

import pytest

from sozvon_engine import commitments
from sozvon_engine.mcp import tools

SUMMARY_A = """## Коротко
Обсудили запуск.

## Задачи
- [ ] Олег: прислать договор, пятница
- [x] Анна: согласовать бюджет
- [ ] **Олег Иванов:** проверить оплату
- [ ] Вы: подготовить демо
- [ ] Проверить https://x.y/page
- [ ] Встреча в 10:30 с юристами

## Открытые вопросы
- Олег: это не задача
"""

SUMMARY_B = """## Action Items
- [ ] Oleg: send the invoice
- [ ] Anna, Борис: созвониться с банком
"""


def call(root, folder, summary=None, **fields):
    d = root / folder
    d.mkdir(parents=True)
    (d / "call.json").write_text(json.dumps(fields, ensure_ascii=False), encoding="utf-8")
    if summary is not None:
        (d / "summary.md").write_text(summary, encoding="utf-8")
    return d


@pytest.fixture
def root(tmp_path, profiles):
    (profiles / "acme.json").write_text(json.dumps({"title": "Acme Corp"}))
    r = tmp_path / "Calls"
    call(r, "2026-11-04 15-01", SUMMARY_A, profile="acme", names=["Олег Иванов", "Анна"], topic="запуск")
    call(r, "2026-11-06 10-00", SUMMARY_B, profile="", names=["Олег"], topic="счёт")
    call(r, "2026-11-07 09-00", None, profile="acme", names=["Анна"], topic="без саммари")
    return r


def test_parse_follows_the_app_rules():
    items = commitments.parse(SUMMARY_A)
    assert [(i.owner, i.task, i.done) for i in items] == [
        ("Олег", "прислать договор, пятница", False),
        ("Анна", "согласовать бюджет", True),
        ("Олег Иванов", "проверить оплату", False),
        ("Вы", "подготовить демо", False),
        ("", "Проверить https://x.y/page", False),
        ("", "Встреча в 10:30 с юристами", False),
    ]


FIXTURE = json.loads((Path(__file__).resolve().parents[2] / "Tests" / "Fixtures" / "action_items.json")
                     .read_text(encoding="utf-8"))


@pytest.mark.parametrize("case", FIXTURE["parse"], ids=lambda c: c["note"])
def test_parse_shared_with_the_app(case):
    """The same cases as the app's ActionItems.parse (Tests/Fixtures/action_items.json)."""
    got = [{"owner": i.owner, "task": i.task, "done": i.done} for i in commitments.parse(case["summary"])]
    assert got == case["items"]


@pytest.mark.parametrize("case", FIXTURE["mine"], ids=lambda c: c["note"])
def test_ownership_shared_with_the_app(case):
    """The same cases as the app's ActionItems.isMine: the user's name and the self words."""
    assert [o for o in case["yes"] if not commitments.is_owner_of(o, case["me"], True)] == []
    assert [o for o in case["no"] if commitments.is_owner_of(o, case["me"], True)] == []


def test_person_matches_first_name_and_alphabet():
    assert commitments.same_person("Олег Иванов", "Олег")
    assert commitments.same_person("Oleg", "Олег")
    assert commitments.same_person("Anna, Борис", "Boris")
    assert not commitments.same_person("Олег", "Анна")
    assert not commitments.same_person("", "Олег")


def test_what_did_oleg_promise(root):
    out = tools.get_commitments("Олег").splitlines()
    assert out == ["- 2026-11-06 10-00 · счёт: Oleg: send the invoice",
                   "- 2026-11-04 15-01 · запуск · Acme Corp: Олег: прислать договор, пятница",
                   "- 2026-11-04 15-01 · запуск · Acme Corp: Олег Иванов: проверить оплату"]


def test_done_items_only_on_request(root):
    assert "согласовать бюджет" not in tools.get_commitments("Анна")
    assert "[x] " in tools.get_commitments("Анна", include_done=True)


def test_my_commitments_include_you_words(root, monkeypatch):
    monkeypatch.setenv("SOZVON_ME", "Борис")
    out = tools.get_commitments("Борис")
    assert "подготовить демо" in out and "созвониться с банком" in out


def test_filter_by_project(root):
    out = tools.get_commitments(project="acme")
    assert "прислать договор" in out and "send the invoice" not in out
    assert "Проверить https" in out, "items with no owner are listed when no person is asked for"


def test_nothing_found(root):
    assert tools.get_commitments("Пётр") == "Обещаний не найдено."


def test_person_profile(root):
    out = tools.get_person("Олег")
    assert out.splitlines()[0] == "Олег: 2 звонка, последний 2026-11-06 10-00"
    assert "Проекты: Acme Corp" in out
    assert "Вместе с: Анна" in out
    assert "send the invoice" in out and "прислать договор" in out
    assert "2026-11-04 15-01 · запуск" in out


def test_person_found_by_transcript_when_the_call_lists_nobody(root):
    d = call(root, "2026-11-08 12-00", None, profile="", names=[], topic="без участников")
    (d / "transcript.txt").write_text("[00:01] Boris: Привет\n[00:05] Олег: Да\n[00:09] Собеседник: угу\n", encoding="utf-8")
    out = tools.get_person("Олег")
    assert out.splitlines()[0] == "Олег: 3 звонка, последний 2026-11-08 12-00"


def test_person_unknown(root):
    assert tools.get_person("Пётр") == "Такого человека нет в звонках."


def test_tools_are_registered():
    names = [f.__name__ for f in tools.TOOLS]
    assert "get_commitments" in names and "get_person" in names
