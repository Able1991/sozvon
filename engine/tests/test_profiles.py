"""Проекты, словарь, подсказка Whisper, замены, обучение участникам, атомарная запись."""
import json

import pytest

from sozvon_engine import profiles as profiles_module
from sozvon_engine import prompt, vocab, whisper
from sozvon_engine.mcp import tools


def make(profiles_dir, slug, **kw):
    prof = {"title": slug.title(), "context": "", "people": [], "terms": [], "replacements": [], **kw}
    (profiles_dir / f"{slug}.json").write_text(json.dumps(prof, ensure_ascii=False))
    return prof


def test_list_and_load(profiles):
    make(profiles, "acme", title="Acme Corp")
    (profiles / "Bad Name.json").write_text("{}")
    assert profiles_module.list_all() == {"acme": "Acme Corp"}
    assert profiles_module.load("acme")["title"] == "Acme Corp"
    assert profiles_module.load("nope") == {}
    assert profiles_module.load("") == {}


def test_prompt_contains_project_people_and_keywords(profiles):
    make(profiles, "acme", title="Acme", people=["Анна Петрова"], terms=["Kubernetes"])
    p = prompt.build_prompt({"initial_prompt": "Созвон."}, profiles_module.load("acme"), ["Иван"], "бюджет")
    assert p.startswith("Созвон. Проект: Acme. Участники: Иван.")
    assert p.index("бюджет") < p.index("Анна Петрова") < p.index("Kubernetes")


def test_prompt_labels_follow_call_language():
    p = prompt.build_prompt({}, {"title": "Acme"}, ["Ann"], "budget", lang="en", count=len)
    assert p == "Project: Acme. Participants: Ann. Terms: budget."


def test_prompt_fits_token_budget(profiles):
    terms = [f"Термин{i} длинное-название-{i}" for i in range(200)]
    make(profiles, "big", terms=terms)
    p = prompt.build_prompt({"initial_prompt": "Созвон."}, profiles_module.load("big"))
    assert prompt.count_tokens(p) <= prompt.PROMPT_MAX_TOKENS
    assert "Термин0" in p  # самые важные (первые) влезли


def test_prompt_budget_with_fake_counter():
    p = prompt.build_prompt({"initial_prompt": "База."}, {"terms": ["aa", "bb", "cc"]}, keywords="очень-длинное-слово, kw",
                            max_tokens=30, count=len)
    assert "очень-длинное-слово" not in p and "kw" in p


def test_base_prompt_has_no_terms():
    p = prompt.base_prompt({"initial_prompt": "Созвон."}, {"title": "Acme", "terms": ["Kubernetes"]}, ["Иван"])
    assert "Kubernetes" not in p and "Acme" in p and "Иван" in p


def test_replacements_profile_and_global():
    reps = vocab.all_replacements({"replacements": [["кубер", "Kubernetes"]]},
                                  {"replacements": [["террагрант", "Terragrunt"], ["bad"]]})
    assert whisper.apply_replacements("Кубер и террагрант", reps) == "Kubernetes и Terragrunt"


def test_replacement_is_whole_word():
    assert whisper.apply_replacements("кубернетес", [["кубер", "Kubernetes"]]) == "кубернетес"


def test_learn_people_adds_only_new(profiles):
    prof = make(profiles, "acme", people=["Анна Петрова"])
    added = profiles_module.learn_people("acme", prof, ["Анна", "Иван", "Олег", "иван"], me="Олег")
    saved = json.loads((profiles / "acme.json").read_text())
    assert saved["people"] == ["Анна Петрова", "Иван"] and added == ["Иван"]
    assert saved["schema"] == 1


def test_learn_people_without_profile_does_nothing(profiles):
    profiles_module.learn_people("", {}, ["Иван"], me="Я")
    assert list(profiles.iterdir()) == []


def test_hallucination_detector():
    assert whisper.is_hallucination("ерсти" * 30)
    assert not whisper.is_hallucination("Давай обсудим запуск кампании на следующей неделе.")


def test_profile_names_cannot_escape_folder(profiles, data):
    secret = data / "settings.json"
    secret.write_text('{"keep": true}')
    assert profiles_module.load("../settings") == {}
    with pytest.raises(ValueError):
        profiles_module.save("../settings", {"terms": ["x"]})
    assert secret.read_text() == '{"keep": true}'
    assert tools.add_terms("x", profile="../../.claude/settings").startswith("ОШИБКА")
    assert secret.read_text() == '{"keep": true}'


@pytest.mark.parametrize("slug,ok", [("acme", True), ("a-b_c9", True), ("x" * 64, True), ("x" * 65, False),
                                     ("Acme", False), ("", False), ("../a", False), ("a.b", False), ("а", False)])
def test_slug_rules(slug, ok):
    assert profiles_module.valid_slug(slug) is ok


def test_save_is_atomic_and_has_schema(profiles, monkeypatch):
    profiles_module.save("acme", {"title": "Acme", "terms": ["a"]})
    raw = (profiles / "acme.json").read_text()
    assert json.loads(raw) == {"schema": 1, "title": "Acme", "terms": ["a"]}
    assert raw.startswith('{\n  "schema": 1')

    # Сбой посреди записи не портит старый файл и не оставляет временных.
    import os
    real = os.replace
    monkeypatch.setattr(os, "replace", lambda *a: (_ for _ in ()).throw(OSError("disk full")))
    with pytest.raises(OSError):
        profiles_module.save("acme", {"title": "Сломано"})
    monkeypatch.setattr(os, "replace", real)
    assert json.loads((profiles / "acme.json").read_text())["title"] == "Acme"
    assert sorted(p.name for p in profiles.iterdir()) == ["acme.json"]


def test_vocab_save_has_schema_and_merge_rules(data):
    vocab.save({"initial_prompt": "x", "terms": ["HPA"]})
    assert json.loads((data / "vocab.json").read_text())["schema"] == 1
    terms, added = vocab.merge_terms(["HPA"], ["hpa", "k8s", "K8S", " "])
    assert terms == ["HPA", "k8s"] and added == ["k8s"]
    terms, _ = vocab.merge_terms(["HPA"], ["new"], front=True)
    assert terms == ["new", "HPA"]
    reps, old = vocab.set_replacement([["Кубер", "K"], ["x", "y"]], "кубер", "Kubernetes")
    assert reps == [["кубер", "Kubernetes"], ["x", "y"]] and old == "K"
    reps, removed = vocab.remove_replacement(reps, "X")
    assert reps == [["кубер", "Kubernetes"]] and removed


def test_mcp_vocab_tools(data, profiles):
    assert tools.add_replacement("кубер", "Kubernetes").startswith("Добавлено")
    assert "было 'Kubernetes'" in tools.add_replacement("Кубер", "K8s")
    assert tools.add_terms("HPA, HPA, k8s") == "Добавлено в общие термины: HPA, k8s."
    assert tools.add_terms("hpa") == "Все термины уже есть."
    assert "'Кубер' -> 'K8s'" in tools.show_vocab()
    assert tools.remove_replacement("кубер").startswith("Удалено")
    make(profiles, "acme", terms=["old"])
    assert tools.add_terms("new", profile="acme") == "Добавлено в профиль acme: new."
    assert json.loads((profiles / "acme.json").read_text())["terms"] == ["new", "old"]
    assert tools.add_replacement("а", "б", profile="nope").startswith("ОШИБКА")
    assert "acme" in tools.list_profiles()


def _slow_reads(monkeypatch):
    """Чтение JSON с паузой: без блокировки параллельные правки гарантированно теряются."""
    import time

    from sozvon_engine import jsonfile
    real = jsonfile.read

    def slow(*a, **kw):
        out = real(*a, **kw)
        time.sleep(0.01)
        return out
    monkeypatch.setattr(jsonfile, "read", slow)


def test_parallel_edits_in_threads_are_not_lost(profiles, data, monkeypatch):
    import threading
    make(profiles, "acme")
    _slow_reads(monkeypatch)
    jobs = []
    for i in range(12):
        jobs += [lambda i=i: tools.add_terms(f"term{i}", profile="acme"),
                 lambda i=i: tools.add_terms(f"shared{i}"),
                 lambda i=i: tools.add_replacement(f"wrong{i}", f"right{i}"),
                 lambda i=i: profiles_module.learn_people("acme", {"people": []}, [f"Человек{i}"], me="Я")]
    threads = [threading.Thread(target=j) for j in jobs]
    for th in threads:
        th.start()
    for th in threads:
        th.join()
    prof = profiles_module.load("acme")
    assert sorted(prof["terms"]) == sorted(f"term{i}" for i in range(12))
    assert sorted(prof["people"]) == sorted(f"Человек{i}" for i in range(12))
    v = vocab.load()
    assert sorted(v["terms"]) == sorted(f"shared{i}" for i in range(12))
    assert sorted(p[0] for p in v["replacements"]) == sorted(f"wrong{i}" for i in range(12))
    assert not list(profiles.glob("*.tmp")) and not list(data.glob("*.tmp"))


def test_parallel_edits_in_processes_are_not_lost(profiles, data):
    import subprocess
    import sys
    from pathlib import Path
    make(profiles, "acme")
    engine = Path(__file__).resolve().parent.parent
    code = ("import sys; sys.path.insert(0, sys.argv[1]); from sozvon_engine.mcp import tools\n"
            "for i in range(15):\n"
            "    tools.add_terms(f'p{sys.argv[2]}t{i}', profile='acme'); tools.add_terms(f'p{sys.argv[2]}s{i}')")
    env = {"PATH": "/usr/bin:/bin", "SOZVON_DATA_DIR": str(data), "SOZVON_UI_LANG": "en", "HOME": str(data)}
    procs = [subprocess.Popen([sys.executable, "-c", code, str(engine), str(n)], env=env) for n in range(4)]
    assert all(p.wait(timeout=120) == 0 for p in procs)
    want_p = {f"p{n}t{i}" for n in range(4) for i in range(15)}
    want_s = {f"p{n}s{i}" for n in range(4) for i in range(15)}
    assert set(profiles_module.load("acme")["terms"]) == want_p
    assert set(vocab.load()["terms"]) == want_s
