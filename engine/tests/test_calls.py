"""call.json and call folders (docs/CONTRACT.md, section 4)."""
import json

import pytest

from sozvon_engine import calls, jsonfile


def test_read_missing_gives_skeleton(tmp_path):
    d = tmp_path / "2026-11-04 15-01 · Acme"
    d.mkdir()
    assert calls.read_call(d) == {"schema": 1, "id": "2026-11-04 15-01"}


def test_write_is_atomic_with_schema_first(tmp_path):
    d = tmp_path / "2026-11-04 15-01"
    d.mkdir()
    calls.write_call(d, {"id": "2026-11-04 15-01", "status": "recorded"})
    raw = (d / "call.json").read_text()
    assert list(json.loads(raw)) == ["schema", "id", "status"]
    assert [p.name for p in d.iterdir()] == ["call.json"], "временный файл не остаётся"


def test_update_keeps_app_fields(tmp_path):
    d = tmp_path / "2026-11-04 15-01"
    d.mkdir()
    (d / "call.json").write_text(json.dumps({"schema": 1, "id": "X", "audio": {"mic_start": 1.0}, "names": ["Анна"]}))
    calls.update_call(d, status="done", engine={"version": "v", "model": "turbo"})
    c = json.loads((d / "call.json").read_text())
    assert c["audio"] == {"mic_start": 1.0} and c["names"] == ["Анна"] and c["status"] == "done"
    assert c["engine"] == {"version": "v", "model": "turbo"} and c["id"] == "X"


def test_strict_read_rejects_broken_file(tmp_path):
    d = tmp_path / "c"
    d.mkdir()
    (d / "call.json").write_text("{broken")
    with pytest.raises(jsonfile.JsonFileError):
        calls.read_call(d, strict=True)
    assert calls.read_call(d)["id"] == "c"


def test_id_from_call_json_survives_rename(tmp_path):
    root = tmp_path / "Calls"
    d = root / "2026-11-04 15-01"
    d.mkdir(parents=True)
    calls.write_call(d, {"id": "2026-11-04 15-01"})
    d.rename(root / "2026-11-04 15-01 · Acme · запуск")
    assert calls.find_call("2026-11-04 15-01", root).name == "2026-11-04 15-01 · Acme · запуск"
    # without call.json the id is the first 16 characters of the name
    (root / "2026-11-05 09-30 · Beta").mkdir()
    assert calls.find_call("2026-11-05 09-30", root).name == "2026-11-05 09-30 · Beta"
    assert calls.call_id(root / "2026-11-05 09-30 · Beta") == "2026-11-05 09-30"


@pytest.mark.parametrize("bad", ["", ".", "..", "../x", "../../etc", "a/b", "a\\b", ".hidden", "/etc"])
def test_find_rejects_traversal(tmp_path, bad):
    root = tmp_path / "Calls"
    (root / "2026-11-04 15-01").mkdir(parents=True)
    (tmp_path / "secret").mkdir()
    with pytest.raises(ValueError):
        calls.find_call(bad, root)


def test_symlink_outside_is_ignored(tmp_path):
    root = tmp_path / "Calls"
    root.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    (root / "2026-11-04 15-01").symlink_to(outside)
    with pytest.raises(ValueError):
        calls.find_call("2026-11-04 15-01", root)


def test_list_calls_newest_first_with_duration(tmp_path):
    root = tmp_path / "Calls"
    for name, audio in (("2026-11-03 10-00", None), ("2026-11-04 15-01 · A", {"mic_seconds": 10, "system_seconds": 12.5})):
        d = root / name
        d.mkdir(parents=True)
        if audio:
            calls.write_call(d, {"id": name[:16], "audio": audio, "names": ["Анна"], "topic": "т"})
    (root / ".hidden").mkdir()
    out = calls.list_calls(root)
    assert [c.id for c in out] == ["2026-11-04 15-01", "2026-11-03 10-00"]
    assert out[0].seconds == 12.5 and out[0].people == ["Анна"] and out[0].topic == "т"
    assert out[1].seconds == 0


def test_id_from_name_with_suffix():
    from sozvon_engine.calls import id_from_name
    assert id_from_name("2026-11-04 15-01") == "2026-11-04 15-01"
    assert id_from_name("2026-11-04 15-01-2 · Acme · Анна") == "2026-11-04 15-01-2"
    assert id_from_name("2026-11-04 15-01 · Acme") == "2026-11-04 15-01"


def test_list_calls_people_are_participants_else_typed_names(tmp_path):
    """MCP list_calls and search show the derived participants; an older call without them, the typed names."""
    for cid, c in {"2026-11-04 15-01": {"names": ["Анна"], "participants": ["Анна Петрова", "Влад"]},
                   "2026-11-05 10-00": {"names": ["Олег"]},
                   "2026-11-06 10-00": {"names": "not a list"}}.items():
        d = tmp_path / "Calls" / cid
        d.mkdir(parents=True)
        (d / "call.json").write_text(json.dumps({"schema": 1, "id": cid, **c}, ensure_ascii=False), encoding="utf-8")
    people = {c.id: c.people for c in calls.list_calls(tmp_path / "Calls")}
    assert people == {"2026-11-04 15-01": ["Анна Петрова", "Влад"], "2026-11-05 10-00": ["Олег"],
                      "2026-11-06 10-00": []}
