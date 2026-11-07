"""Voice prints: storage, enrollment, matching, the pipeline step and sync. The embedding model is faked."""
import json
import os
import stat
import subprocess
from pathlib import Path

import numpy as np
import pytest

from sozvon_engine import audio, diarize, remote, voice_cli, voices
from sozvon_engine.pipeline import run, speakers

SR = 16000


def one_hot(i: int) -> list:
    v = [0.0] * voices.DIM
    v[i % voices.DIM] = 1.0
    return v


def mix(a: int, b: int, w: float) -> np.ndarray:
    """A unit vector at cosine w to one_hot(a), the rest towards one_hot(b)."""
    return voices.unit(np.array(one_hot(a)) * w + np.array(one_hot(b)) * np.sqrt(max(0.0, 1 - w * w)))


def tone(freq: float, seconds: float, amp: float = 0.3) -> np.ndarray:
    t = np.arange(int(seconds * SR)) / SR
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def silence(seconds: float) -> np.ndarray:
    return np.zeros(int(seconds * SR), np.float32)


def write_track(path: Path, x: np.ndarray) -> Path:
    """Real AAC in an .m4a, like the app records."""
    raw = path.with_suffix(".f32")
    raw.write_bytes(x.astype("<f4").tobytes())
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", "1", "-i", str(raw),
                    "-c:a", "aac", "-b:a", "64k", str(path)], check=True)
    raw.unlink()
    return path


def dominant(x: np.ndarray) -> float:
    spec = np.abs(np.fft.rfft(x[: SR * 4]))
    return float(np.argmax(spec) * SR / min(len(x), SR * 4))


@pytest.fixture
def fake_embed(monkeypatch):
    """embed(pieces): a one-hot vector at the dominant frequency / 100 of the speech it is given."""
    seen = []

    def embed(pieces, sr=SR):
        x = np.concatenate(pieces)
        seen.append({"seconds": len(x) / sr, "freq": dominant(x)})
        return np.array(one_hot(int(round(dominant(x) / 100))))
    monkeypatch.setattr(voices, "embed", embed)
    return seen


def result(capsys) -> str:
    return capsys.readouterr().out.strip().splitlines()[-1]


# --- storage and the CLI ---

def test_enroll_from_file(tmp_path, data, fake_embed, capsys):
    f = write_track(tmp_path / "sample.m4a", np.concatenate([tone(300, 6), silence(1), tone(300, 5)]))
    assert voice_cli.main(["enroll", "--name", "  Борис  Иванов ", "--me", "--file", str(f)]) == 0
    line = result(capsys)
    assert line.startswith("RESULT: ok ")
    vid = line.split()[-1]
    rec = json.loads((data / "voices" / f"{vid}.json").read_text())
    assert rec["schema"] == 1 and rec["id"] == vid and len(vid) == 32
    assert rec["name"] == "Борис Иванов" and rec["me"] is True and rec["profile"] == ""
    assert len(rec["embedding"]) == 256 and abs(np.linalg.norm(rec["embedding"]) - 1) < 1e-9
    assert 10 < rec["seconds"] <= 12 and rec["updated_at"].endswith("Z")
    assert stat.S_IMODE(os.stat(data / "voices" / f"{vid}.json").st_mode) == 0o600
    assert abs(fake_embed[0]["freq"] - 300) < 10
    assert not list((data / "voices").glob(".*.tmp"))


def test_enroll_from_file_needs_8_seconds(tmp_path, fake_embed, capsys, monkeypatch):
    f = write_track(tmp_path / "short.m4a", np.concatenate([tone(300, 5), silence(10)]))
    assert voice_cli.main(["enroll", "--name", "Я", "--file", str(f)]) == 2
    assert "слишком мало речи" in result(capsys)
    monkeypatch.setenv("SOZVON_UI_LANG", "en")
    assert voice_cli.main(["enroll", "--name", "Me", "--file", str(f)]) == 2
    assert result(capsys).startswith("RESULT: error 2 not enough speech for a voice print")
    assert voices.load_all() == []


def test_bad_arguments(capsys):
    assert voice_cli.main(["enroll", "--name", "x", "--file", "/nope.m4a"]) == 2
    assert result(capsys).startswith("RESULT: error 2 ")
    assert voice_cli.main(["enroll", "--name", "x"]) == 2
    assert result(capsys).startswith("RESULT: error 2 ")
    assert voice_cli.main(["enroll", "--name", "x", "--profile", "Bad Slug", "--file", "/x"]) == 2
    assert voice_cli.main(["delete", "--id", "../etc"]) == 2


def make_call(tmp_path) -> Path:
    """System track: Анна 0-10 s (300 Hz), Олег 10-20 s (600 Hz). Mic: me 20-30 s on the timeline (900 Hz), the
    mic started 1 s after the system track, and a 1200 Hz tone before that would leak in if the offset were ignored."""
    d = tmp_path / "Calls" / "2026-11-04 15-01"
    d.mkdir(parents=True)
    write_track(d / "system.m4a", np.concatenate([tone(300, 10), tone(600, 10), silence(15)]))
    write_track(d / "mic.m4a", np.concatenate([tone(1200, 18), silence(1), tone(900, 10), silence(5)]))
    (d / "call.json").write_text(json.dumps({"schema": 1, "id": "2026-11-04 15-01", "status": "done",
                                             "audio": {"mic_start": 101.0, "system_start": 100.0}}))
    (d / "transcript.txt").write_text("[00:00] Анна: привет\n[00:10] Олег: да\n[00:20] Я: итак\n[00:30] Олег: пока\n",
                                      encoding="utf-8")
    return d


def test_enroll_from_call_picks_paragraphs_and_track(tmp_path, fake_embed, capsys):
    d = make_call(tmp_path)
    assert voice_cli.main(["enroll", "--name", "Анна Петрова", "--profile", "acme", "--call", str(d),
                           "--speaker", "Анна"]) == 0
    assert abs(fake_embed[-1]["freq"] - 300) < 10 and 9 < fake_embed[-1]["seconds"] <= 10.1
    # The user's paragraphs come from the mic, shifted by its offset: only the 900 Hz part.
    assert voice_cli.main(["enroll", "--name", "Борис", "--me", "--call", str(d), "--speaker", "Я"]) == 0
    assert abs(fake_embed[-1]["freq"] - 900) < 10
    # Олег's last paragraph (30-35 s) is silence: only his speech counts.
    assert voice_cli.main(["enroll", "--name", "Олег", "--call", str(d), "--speaker", "Олег"]) == 0
    assert abs(fake_embed[-1]["freq"] - 600) < 10 and fake_embed[-1]["seconds"] <= 10.1
    recs = {r["name"]: r for r in voices.load_all()}
    assert recs["Анна Петрова"]["profile"] == "acme" and recs["Борис"]["me"] and not recs["Олег"]["me"]
    assert voice_cli.main(["enroll", "--name", "Нет", "--call", str(d), "--speaker", "Никто"]) == 2


def test_enroll_from_call_needs_4_seconds(tmp_path, fake_embed, capsys):
    d = make_call(tmp_path)
    (d / "transcript.txt").write_text("[00:00] Анна: привет\n[00:03] Олег: да\n", encoding="utf-8")
    assert voice_cli.main(["enroll", "--name", "Анна", "--call", str(d), "--speaker", "Анна"]) == 2
    assert "слишком мало речи" in result(capsys)


def test_paragraph_spans():
    """Same parser as the app: a paragraph ends where the next starts (the last one: +5 s)."""
    from sozvon_engine.pipeline import render
    paras = render.parse_txt("[00:00] А: x\n[00:00] Б: y\n[00:05] А: z\n")
    assert [(s, e, w) for s, e, _, w in paras] == [(0, 0, "А"), (0, 5, "Б"), (5, 10, "А")]


def test_overlap_rule(tmp_path):
    d = tmp_path / "c"
    d.mkdir()
    (d / "transcript.txt").write_text("[00:00] А: x\n[00:00] Б: y\n[00:05] А: z\n[00:09] Б: w\n", encoding="utf-8")
    clean, _ = voices.call_paragraphs(d, "А")
    assert clean == [(5.0, 9.0)]


def test_merge_weights():
    old = {"embedding": one_hot(0), "seconds": 600.0}
    emb, sec = voices.merge_embeddings(old, one_hot(1), 300.0)
    # Both sides weigh 300 s (old capped), so the result is halfway; seconds add up.
    assert emb[0] == pytest.approx(emb[1]) and emb[0] == pytest.approx(2 ** -0.5)
    assert sec == 900.0
    emb, _ = voices.merge_embeddings({"embedding": one_hot(0), "seconds": 100.0}, one_hot(1), 300.0)
    assert emb[1] / emb[0] == pytest.approx(3.0)
    assert abs(np.linalg.norm(emb) - 1) < 1e-12


def test_store_merges_by_name_and_profile():
    a = voices.store("Анна", "acme", False, one_hot(0), 10)
    b = voices.store("Анна", "acme", False, one_hot(1), 10)
    c = voices.store("Анна", "", False, one_hot(2), 10)
    assert a["id"] == b["id"] != c["id"]
    assert b["embedding"][0] == pytest.approx(b["embedding"][1]) and b["seconds"] == 20
    replaced = voices.store("Анна", "acme", False, one_hot(3), 9, replace=True)
    assert replaced["id"] == a["id"] and replaced["embedding"][3] == 1.0 and replaced["seconds"] == 9
    assert len(voices.load_all()) == 2


def test_me_is_unique():
    a = voices.store("Борис", "", True, one_hot(0), 10)
    b = voices.store("Борис Иванов", "acme", True, one_hot(2), 10, replace=True)
    assert b["id"] == a["id"] and b["name"] == "Борис Иванов" and b["profile"] == ""
    recs = voices.load_all()
    assert [r["id"] for r in recs if r["me"]] == [a["id"]] and len(recs) == 1


def test_me_under_another_persons_name_is_refused():
    """Folding would lose the other person's print (say, synced from another Mac): refused with a way out."""
    me = voices.store("Борис", "", True, one_hot(0), 10)
    other = voices.store("Борис Иванов", "", False, one_hot(1), 10)
    with pytest.raises(voices.VoiceError) as e:
        voices.store("Борис Иванов", "", True, one_hot(2), 10)
    assert e.value.code == 2 and "Настройках" in e.value.message
    recs = {r["id"]: r for r in voices.load_all()}
    assert recs[other["id"]]["embedding"] == other["embedding"] and recs[me["id"]]["name"] == "Борис"
    assert voices.tombstones() == {}
    # The same name in a project is another record: no clash.
    voices.store("Анна", "acme", False, one_hot(3), 10)
    assert voices.store("Анна", "", True, one_hot(4), 10)["id"] == me["id"]


def test_drop_local_keeps_a_record_changed_after_the_tombstone():
    a = voices.store("Анна", "", False, one_hot(0), 10)
    b = voices.store("Олег", "", False, one_hot(1), 10)
    # The sync saw both older than the tombstones; meanwhile "Анна" was enrolled again here.
    voices.save({**a, "updated_at": "2999-01-01T00:00:00Z"})
    assert voices.drop_local({a["id"]: "2026-11-05T10:00:00Z", b["id"]: "2999-06-01T00:00:00Z"}) == 1
    assert [r["name"] for r in voices.load_all()] == ["Анна"]


def test_list_delete_tombstones(capsys, data):
    a = voices.store("Анна", "acme", False, one_hot(0), 10)
    b = voices.store("Олег", "", False, one_hot(1), 10)
    capsys.readouterr()
    assert voice_cli.main(["list"]) == 0
    lines = capsys.readouterr().out.strip().splitlines()
    assert lines[-1] == "RESULT: ok 2"
    rows = [json.loads(x) for x in lines[:-1]]
    assert {r["name"] for r in rows} == {"Анна", "Олег"}
    assert set(rows[0]) == {"id", "name", "profile", "me", "seconds", "updated_at"}
    assert voice_cli.main(["list", "--profile", "acme"]) == 0
    assert [json.loads(x)["name"] for x in capsys.readouterr().out.strip().splitlines()[:-1]] == ["Анна"]
    assert voice_cli.main(["delete", "--id", a["id"]]) == 0
    assert result(capsys) == "RESULT: ok 1"
    assert set(voices.tombstones()) == {a["id"]}
    saved = json.loads((data / "voices-deleted.json").read_text())
    assert saved["schema"] == 1 and saved["voices"][0]["id"] == a["id"]
    assert voice_cli.main(["delete", "--all"]) == 0
    assert result(capsys) == "RESULT: ok 1"
    assert voices.load_all() == [] and set(voices.tombstones()) == {a["id"], b["id"]}


def test_broken_records_are_ignored(data):
    voices.store("Анна", "", False, one_hot(0), 10)
    (data / "voices" / "junk.json").write_text("{broken")
    (data / "voices" / ("f" * 32 + ".json")).write_text(json.dumps({"id": "f" * 32, "name": "x", "embedding": [1]}))
    assert [r["name"] for r in voices.load_all()] == ["Анна"]


# --- matching ---

def rec(name, vec, me=False, profile=""):
    return {"id": os.urandom(16).hex(), "name": name, "profile": profile, "me": me, "embedding": list(vec),
            "seconds": 30.0, "updated_at": "2026-11-05T10:00:00Z"}


def test_match_threshold_and_margin():
    recs = [rec("Анна", one_hot(0)), rec("Олег", one_hot(1))]
    assert voices.match({"A": mix(0, 5, 0.83)}, recs) == {"A": (recs[0], pytest.approx(0.83))}
    assert voices.match({"A": mix(0, 5, 0.45)}, recs) == {}, "below the threshold"
    # 0.7 to Анна and 0.65 to Олег: too close to tell.
    v = voices.unit(np.array(one_hot(0)) * 0.7 + np.array(one_hot(1)) * 0.65 + np.array(one_hot(9)) * 0.3)
    assert voices.match({"A": v}, recs) == {}


def test_match_never_gives_a_name_twice():
    recs = [rec("Александр Бородин", one_hot(0)), rec("Александр Смирнов", one_hot(1))]
    found = voices.match({"S1": mix(0, 5, 0.7), "S2": mix(0, 6, 0.9)}, recs)
    assert set(found) == {"S2"} and found["S2"][0]["name"] == "Александр Бородин"
    both = voices.match({"S1": mix(0, 5, 0.9), "S2": mix(1, 6, 0.8)}, recs)
    assert {k: r["name"] for k, (r, _) in both.items()} == {"S1": "Александр Бородин", "S2": "Александр Смирнов"}


def test_candidates_by_profile_and_me():
    voices.store("Анна", "acme", False, one_hot(0), 10)
    voices.store("Олег", "other", False, one_hot(1), 10)
    voices.store("Ира", "", False, one_hot(2), 10)
    voices.store("Борис", "", True, one_hot(3), 10)
    assert {r["name"] for r in voices.candidates("acme", False)} == {"Анна", "Ира"}
    assert {r["name"] for r in voices.candidates("acme", True)} == {"Анна", "Ира", "Борис"}
    assert {r["name"] for r in voices.candidates("", False)} == {"Ира"}


def test_clean_spans_cut_overlaps():
    diar = [(0, 5, "A"), (4, 8, "B"), (8, 12, "A")]
    assert voices.clean_spans(diar, "A") == [(0, 4), (8, 12)]
    assert voices.clean_spans(diar, "B") == [(5, 8)]
    assert voices.longest([(0, 50), (60, 100), (100, 101)]) == [(0, 50), (60, 70)]


@pytest.fixture
def fake_track(monkeypatch):
    """speech_of_spans returns pieces whose value is the first span's start; embed maps that to a one-hot."""
    monkeypatch.setattr(voices, "speech_of_spans",
                        lambda path, spans: [np.full(int(SR * sum(e - s for s, e in spans)), spans[0][0], np.float32)])
    monkeypatch.setattr(voices, "embed", lambda pieces, sr=SR: np.array(one_hot(int(pieces[0][0]))))


DIAR = [(0, 5, "SPEAKER_01"), (5, 10, "SPEAKER_00"), (10, 15, "SPEAKER_01")]


def test_pipeline_names_voices(monkeypatch, fake_track):
    monkeypatch.setattr(speakers.diarize, "available", lambda: True)
    voices.store("Александр Бородин", "acme", False, one_hot(5), 30)
    voices.store("Борис", "", True, one_hot(0), 30)
    logs = []

    def name_voices(track, diar):
        return voices.identify(track, diar, "acme", None, logs.append)
    items = speakers.assign_speakers(
        mic=[(20, 21, "я")], mic_dead=[], system=[(0.5, 4, "а"), (5.5, 9, "б"), (10.5, 14, "в")],
        tracks={"system": "s", "mic": "m"}, me="Я", names=["Анна"], speakers=None, diarize_on=True, single_name=None,
        log=logs.append, run_diarization=lambda p, k: DIAR, name_voices=name_voices)
    # The "me" print is not used with a mic track; Анна (given) goes to the remaining voice.
    assert [w for *_, w in items] == ["Я", "Анна", "Александр Бородин", "Анна"]
    assert "голос: Собеседник 2 → Александр Бородин (1.00)" in logs


def test_single_track_recognizes_me(tmp_path, capsys, monkeypatch, fake_track, data):
    voices.store("Борис", "", True, one_hot(0), 30)
    voices.store("Анна Петрова", "", False, one_hot(5), 30)
    d = _system_only_call(tmp_path, monkeypatch, data)
    assert run.main([str(d)]) == 0
    assert (d / "transcript.txt").read_text() == "[00:00] Я: а\n[00:05] Анна Петрова: б\n[00:10] Я: в\n"


def _system_only_call(tmp_path, monkeypatch, data):
    from conftest import fake_model
    from sozvon_engine import prompt, whisper
    from sozvon_engine.pipeline import tracks, transcribe
    fake_model(data)
    monkeypatch.setenv("SOZVON_LLM", "none")
    monkeypatch.setattr(audio, "to_wav", lambda src, dst, delay=0.0: Path(dst).write_bytes(b"wav") and Path(dst))
    monkeypatch.setattr(tracks, "active_seconds", lambda wav: 5.0)
    monkeypatch.setattr(tracks, "dead_spans", lambda wav: [])
    monkeypatch.setattr(tracks, "boost", lambda wav: 1.0)
    monkeypatch.setattr(whisper, "ensure_backend", lambda: None)
    monkeypatch.setattr(prompt, "count_tokens", lambda text: 1)
    monkeypatch.setattr(transcribe, "transcribe_tracks", lambda tr, **kw: (
        {"system": [(0.5, 4, "а"), (5.5, 9, "б"), (10.5, 14, "в")]}, {"system": "ru"}))
    monkeypatch.setattr(diarize, "available", lambda: True)
    monkeypatch.setattr(diarize, "run", lambda path, num_speakers=None: DIAR)
    d = tmp_path / "Calls" / "2026-11-04 15-01"
    d.mkdir(parents=True)
    (d / "system.m4a").write_bytes(b"\0" * 2048)
    (d / "call.json").write_text(json.dumps({"schema": 1, "id": "2026-11-04 15-01", "status": "recorded",
                                             "audio": {"system_start": 0.0}}))
    return d


def test_pipeline_falls_back_without_embeddings(tmp_path, capsys, monkeypatch, data):
    """No model: the transcript is exactly what it would be without voice prints, and the log says why."""
    voices.store("Анна Петрова", "", False, one_hot(5), 30)
    d = _system_only_call(tmp_path, monkeypatch, data)
    monkeypatch.setattr(voices, "speech_of_spans", lambda path, spans: [np.ones(SR * 5, np.float32)])
    monkeypatch.setattr(voices, "_inference", None)
    monkeypatch.setattr(voices, "available", lambda: False)
    assert run.main([str(d)]) == 0
    assert (d / "transcript.txt").read_text() == ("[00:00] Собеседник 1: а\n[00:05] Собеседник 2: б\n"
                                                  "[00:10] Собеседник 1: в\n")
    assert "образцы голосов не сработали" in capsys.readouterr().err


def test_no_voices_loads_nothing(monkeypatch):
    def boom(*a, **k):
        raise AssertionError("never decodes or loads a model without stored voices")
    monkeypatch.setattr(voices, "speech_of_spans", boom)
    monkeypatch.setattr(voices, "embed", boom)
    assert voices.identify("x", DIAR, "acme", "Я", lambda m: None) == {}


def test_llm_skips_names_given_by_voice(monkeypatch, fake_track, tmp_path):
    from sozvon_engine import llm
    from sozvon_engine.pipeline import names
    seen = {}

    def fake(prompt, cwd, **kw):
        seen["p"] = prompt
        return '{"Собеседник 1": "Александр Бородин"}', "claude", ""
    monkeypatch.setattr(llm, "run", fake)
    paras = [(0, 1, "a", "Собеседник 1"), (1, 2, "b", "Александр Бородин")]
    out = names.resolve_names(paras, ["Мария"], [], "Я", tmp_path, taken={"Александр Бородин"})
    assert [w for *_, w in out] == ["Собеседник 1", "Александр Бородин"]


# --- sync ---

from test_remote import fake, root  # noqa: E402,F401  the fake own server


def server_rec(name, vec, at="2026-11-05T10:00:00Z", **kw):
    r = rec(name, vec, **kw)
    r["updated_at"] = at
    return r


def test_sync_voices_both_ways(fake, root, data):
    fake.version = "0.4.0"
    mine = voices.store("Анна", "acme", False, one_hot(0), 10)
    theirs = server_rec("Олег", one_hot(1))
    fake.voices[theirs["id"]] = theirs
    lines = []
    assert tuple(remote.sync(root=root, status=lines.append)) == (0, 0, 0, 0, 0)
    assert fake.voices[mine["id"]]["embedding"] == mine["embedding"] and "schema" not in fake.voices[mine["id"]]
    got = {r["name"]: r for r in voices.load_all()}
    assert got["Олег"]["id"] == theirs["id"] and got["Олег"]["embedding"] == theirs["embedding"]
    assert "Образцы голосов: отправлено 1, скачано 1, удалено 0" in lines
    # A second sync changes nothing.
    puts = len([r for r in fake.requests if r[0] == "PUT"])
    lines.clear()
    remote.sync(root=root, status=lines.append)
    assert len([r for r in fake.requests if r[0] == "PUT"]) == puts and not any("голос" in x for x in lines)


def test_sync_never_overwrites_a_newer_local_voice(fake, root):
    fake.version = "0.4.0"
    mine = voices.store("Анна", "", False, one_hot(0), 10)
    fake.voices[mine["id"]] = {**mine, "embedding": one_hot(7), "updated_at": "2020-01-01T00:00:00Z"}
    del fake.voices[mine["id"]]["schema"]
    remote.sync(root=root)
    assert voices.load_all()[0]["embedding"] == mine["embedding"]
    assert fake.voices[mine["id"]]["embedding"] == mine["embedding"], "the newer local one goes up"
    # A newer server copy comes down.
    fake.voices[mine["id"]] = {**fake.voices[mine["id"]], "embedding": one_hot(8), "updated_at": "2999-01-01T00:00:00Z"}
    remote.sync(root=root)
    assert voices.load_all()[0]["embedding"] == one_hot(8)


def test_sync_deletions_both_ways(fake, root):
    fake.version = "0.4.0"
    a = voices.store("Анна", "", False, one_hot(0), 10)
    remote.sync(root=root)
    assert a["id"] in fake.voices
    voices.delete(a["id"])
    gone = server_rec("Олег", one_hot(1))
    voices.accept_remote({**gone, "schema": 1})
    fake.voices[gone["id"]] = {"id": gone["id"], "deleted": True, "updated_at": "2026-11-06T00:00:00.000Z"}
    lines = []
    remote.sync(root=root, status=lines.append)
    assert fake.voices[a["id"]]["deleted"] is True and voices.tombstones() == {}
    assert voices.load_all() == [], "the server tombstone deletes the voice here"
    assert "Образцы голосов: отправлено 0, скачано 0, удалено 2" in lines


def test_sync_folds_a_duplicate_from_another_mac(fake, root):
    fake.version = "0.4.0"
    mine = voices.store("Анна", "acme", False, one_hot(0), 10)
    dup = server_rec("Анна", one_hot(1), profile="acme")
    fake.voices[dup["id"]] = dup
    remote.sync(root=root)
    recs = voices.load_all()
    assert [r["id"] for r in recs] == [mine["id"]] and recs[0]["seconds"] == 40
    assert fake.voices[dup["id"]]["deleted"] is True and fake.voices[mine["id"]]["seconds"] == 40


def test_sync_merges_a_concurrent_enrollment_of_the_same_voice(fake, root, monkeypatch):
    """Two Macs enrolled the same record at once: the later PUT gets 409 and the stored print, merges, sends once."""
    fake.version = "0.4.0"
    mine = voices.store("Анна", "", False, one_hot(0), 10)
    real = remote._request
    raced = []

    def racing(srv, method, path, *a, **k):
        if method == "PUT" and path.startswith("/api/voices/") and not raced:
            raced.append(1)  # the other Mac's PUT lands between this Mac's listing and its PUT
            fake.voices[mine["id"]] = {**{k2: v for k2, v in mine.items() if k2 != "schema"},
                                       "name": "Анна Петрова", "embedding": one_hot(1), "seconds": 10,
                                       "updated_at": "2999-01-01T00:00:00Z"}
        return real(srv, method, path, *a, **k)
    monkeypatch.setattr(remote, "_request", racing)
    lines = []
    remote.sync(root=root, status=lines.append)
    stored = fake.voices[mine["id"]]
    assert stored["embedding"][0] == pytest.approx(stored["embedding"][1]) == pytest.approx(2 ** -0.5)
    assert stored["seconds"] == 20 and stored["name"] == "Анна Петрова"
    assert stored["updated_at"] > "2999-01-01T00:00:00Z"
    (here,) = voices.load_all()
    assert here["embedding"] == stored["embedding"] and here["updated_at"] == stored["updated_at"]
    assert "Образцы голосов: отправлено 1, скачано 0, удалено 0" in lines
    puts = [r for r in fake.requests if r[0] == "PUT" and r[1].startswith("/api/voices/")]
    assert len(puts) == 2, "one retry, no loop"


def test_sync_voices_switch_off(fake, root, monkeypatch):
    fake.version = "0.4.0"
    monkeypatch.setenv("SOZVON_SYNC_VOICES", "0")
    a = voices.store("Анна", "", False, one_hot(0), 10)
    b = voices.store("Олег", "", False, one_hot(1), 10)
    fake.voices[b["id"]] = {k: v for k, v in b.items() if k != "schema"}
    theirs = server_rec("Ира", one_hot(2))
    fake.voices[theirs["id"]] = theirs
    voices.delete(b["id"])
    remote.sync(root=root)
    assert a["id"] not in fake.voices, "nothing goes up"
    assert [r["name"] for r in voices.load_all()] == ["Анна"], "nothing comes down"
    assert fake.voices[b["id"]]["deleted"] is True, "a deletion still reaches the server"


def test_sync_voices_needs_server_040(fake, root):
    fake.version = "0.3.3"
    voices.store("Анна", "", False, one_hot(0), 10)
    remote.sync(root=root)
    assert fake.voices == {} and not any(p.startswith("/api/voices") for _, p, *_ in fake.requests)


def test_sync_voice_failure_keeps_result(fake, root, monkeypatch):
    fake.version = "0.4.0"
    voices.store("Анна", "", False, one_hot(0), 10)
    real = remote._request

    def flaky(srv, method, path, *a, **k):
        if path.startswith("/api/voices/"):
            raise remote.RemoteError(1, "сервер ответил кодом 500")
        return real(srv, method, path, *a, **k)
    monkeypatch.setattr(remote, "_request", flaky)
    lines = []
    assert tuple(remote.sync(root=root, status=lines.append)) == (0, 0, 0, 0, 0)
    assert any(x.startswith("Образцы голосов не синхронизировались") for x in lines)


def test_sync_voices_key(tmp_path):
    from sozvon_engine import config
    assert config.load(tmp_path / "none", environ={}).sync_voices is True
    assert config.load(tmp_path / "none", environ={"SOZVON_SYNC_VOICES": "0"}).sync_voices is False
    env = tmp_path / ".env"
    env.write_text("SOZVON_SYNC_VOICES=1\n")
    assert config.load(env, environ={}).sync_voices is True
