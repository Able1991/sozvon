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
    if os.name != "nt":  # chmod sets no permissions on Windows: test_platform_win32.py checks the ACL of the data folder
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


def test_my_name_from_my_voice_print_is_me(monkeypatch):
    """The name in Settings can be empty or spelled differently: my own voice print knows it too."""
    voices.store("Boris", "", True, np.array(one_hot(1)), 20.0)
    assert voices.is_me_label("Boris")
    assert voices.is_me_label("Борис"), "the same name in Cyrillic"
    assert not voices.is_me_label("Влад")


def test_same_name():
    assert voices.same_name("Борис", "boris")
    assert voices.same_name(" Maria ", "мариа")
    assert not voices.same_name("Борис", "Влад")
    assert not voices.same_name("", "")


def test_my_label_is_never_saved_as_someone_elses_voice(tmp_path, fake_embed, capsys):
    voices.store("Boris", "", True, np.array(one_hot(1)), 20.0)
    d = tmp_path / "call"
    d.mkdir()
    (d / "call.json").write_text("{}")
    write_track(d / "system.m4a", tone(300, 20))
    (d / "transcript.txt").write_text("[00:00] Boris: привет\n[00:10] Влад: да\n", encoding="utf-8")
    assert voice_cli.main(["enroll", "--name", "Boris", "--call", str(d), "--speaker", "Boris"]) == 2
    assert "RESULT: error 2" in result(capsys)
    assert len(voices.load_all()) == 1, "nothing saved"
    # The user's own sample still works through --me.
    assert voices.is_me_label("Boris")


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


# --- enrolling someone from the track their lines came from ---

def mic_person_call(tmp_path, tracks_field) -> Path:
    """Timeline: Анна on the system track 0-10 s (300 Hz), 20-35 s the system track is Олег (600 Hz) while the
    person at the mic speaks (900 Hz). The mic started 1 s after the system track."""
    d = make_call(tmp_path)
    write_track(d / "system.m4a", np.concatenate([tone(300, 10), silence(10), tone(600, 15)]))
    call = {"schema": 1, "id": "2026-11-04 15-01", "status": "done", "audio": {"mic_start": 101.0, "system_start": 100.0}}
    if tracks_field is not None:
        call["speaker_tracks"] = tracks_field
    (d / "call.json").write_text(json.dumps(call))
    (d / "transcript.txt").write_text("[00:00] Анна: привет\n[00:20] Вера: я рядом\n[00:30] Олег: пока\n", encoding="utf-8")
    return d


FIELD = {"Я": "mic", "Вера": "mic", "Анна": "system", "Олег": "system"}


def test_enroll_reads_the_mic_for_a_person_found_on_it(tmp_path, fake_embed, capsys):
    d = mic_person_call(tmp_path, FIELD)
    assert voice_cli.main(["enroll", "--name", "Вера", "--call", str(d), "--speaker", "Вера"]) == 0
    assert abs(fake_embed[-1]["freq"] - 900) < 10


def test_enroll_still_reads_the_system_track_for_a_remote_speaker(tmp_path, fake_embed, capsys):
    d = mic_person_call(tmp_path, FIELD)
    assert voice_cli.main(["enroll", "--name", "Анна", "--call", str(d), "--speaker", "Анна"]) == 0
    assert abs(fake_embed[-1]["freq"] - 300) < 10


def test_enroll_prefers_the_echo_free_mic_for_a_person_found_on_it(tmp_path, fake_embed, capsys):
    """mic.clean.m4a is aligned to the call's start, so it is read without the mic's offset."""
    d = mic_person_call(tmp_path, FIELD)
    write_track(d / "mic.clean.m4a", np.concatenate([tone(1500, 20), tone(1800, 10), silence(5)]))
    assert voice_cli.main(["enroll", "--name", "Вера", "--call", str(d), "--speaker", "Вера"]) == 0
    assert abs(fake_embed[-1]["freq"] - 1800) < 10


@pytest.mark.parametrize("field", [{**FIELD, "Вера": "both"}, {k: v for k, v in FIELD.items() if k != "Вера"},
                                   {**FIELD, "Вера": "elsewhere"}, ["Вера"]])
def test_enroll_refuses_a_person_whose_track_is_not_certain(tmp_path, fake_embed, capsys, field):
    d = mic_person_call(tmp_path, field)
    assert voice_cli.main(["enroll", "--name", "Вера", "--call", str(d), "--speaker", "Вера"]) == 2
    assert "Вера" in result(capsys)
    assert voices.load_all() == []


def test_enroll_refuses_a_mic_person_when_the_mic_is_gone(tmp_path, fake_embed, capsys):
    d = mic_person_call(tmp_path, FIELD)
    (d / "mic.m4a").unlink()
    assert voice_cli.main(["enroll", "--name", "Вера", "--call", str(d), "--speaker", "Вера"]) == 2
    assert voices.load_all() == []


def test_enroll_without_the_field_reads_the_system_track_as_before(tmp_path, fake_embed, capsys):
    d = mic_person_call(tmp_path, None)
    assert voice_cli.main(["enroll", "--name", "Вера", "--call", str(d), "--speaker", "Вера"]) == 0
    assert abs(fake_embed[-1]["freq"] - 600) < 10


def test_speaker_tracks_are_not_synced():
    assert "speaker_tracks" not in remote.call_fields({"schema": 1, "speaker_tracks": FIELD})


# --- a second person at the microphone ---

SYSTEM_SEGS = [(51, 54, "а"), (56, 59, "б")]
SYSTEM_DIAR = [(50, 55, "SPEAKER_00"), (55, 60, "SPEAKER_01")]
MIC_SEGS = [(1, 9, "я"), (21, 39, "гость")]
MIC_DIAR = [(0, 10, "A"), (20, 40, "B")]  # fake_track: the print of a cluster is one_hot(its first second)


def assign_mic(monkeypatch, mic=MIC_SEGS, mic_diar=MIC_DIAR, system=SYSTEM_SEGS, system_diar=SYSTEM_DIAR,
               profile="acme", fail_mic=False, diarize_on=True, mic_dead=()):
    monkeypatch.setattr(speakers.diarize, "available", lambda: True)
    logs, runs, embedded = [], [], {}

    def run_diarization(path, k=None):
        runs.append(path)
        if path == "m" and fail_mic:
            raise RuntimeError("no mps")
        return {"m": mic_diar, "s": system_diar}[path]

    def name_voices(track, diar):
        return voices.identify(track, diar, profile, None, logs.append, embedded)

    def mic_people(diarize_mic, sys_diar):
        return voices.mic_people("m", diarize_mic, "s", sys_diar, profile, logs.append, embedded)
    items = speakers.assign_speakers(
        mic=list(mic), mic_dead=list(mic_dead), system=list(system), tracks={"mic": "m", "system": "s"}, me="Я",
        names=[], speakers=None, diarize_on=diarize_on, single_name=None, log=logs.append,
        run_diarization=run_diarization, name_voices=name_voices, mic_people=mic_people)
    return [w for *_, w in items], logs, runs


def test_second_person_is_numbered_after_the_system_voices(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(0), 30)
    who, logs, runs = assign_mic(monkeypatch)
    assert who == ["Я", "Собеседник 3", "Собеседник 1", "Собеседник 2"]
    assert any("Собеседник 3" in m for m in logs)
    assert sorted(runs) == ["m", "s"]  # each track is diarized once


def test_second_person_with_one_system_voice_never_collides(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(0), 30)
    who, _, _ = assign_mic(monkeypatch, system=[(51, 54, "а")], system_diar=[(50, 55, "SPEAKER_00")])
    assert who == ["Я", "Собеседник 2", "Собеседник"]


def test_second_person_is_named_by_a_voice_print(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(0), 30)
    voices.store("Анна Петрова", "acme", False, one_hot(20), 30)
    who, _, _ = assign_mic(monkeypatch)
    assert who[:2] == ["Я", "Анна Петрова"]


def test_second_person_is_named_by_a_print_without_project(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(0), 30)
    voices.store("Анна Петрова", "", False, one_hot(20), 30)
    assert assign_mic(monkeypatch)[0][:2] == ["Я", "Анна Петрова"]


def test_print_of_another_project_does_not_name_a_second_person(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(0), 30)
    voices.store("Анна Петрова", "other", False, one_hot(20), 30)
    assert assign_mic(monkeypatch)[0][:2] == ["Я", "Собеседник 3"]


def test_the_user_split_into_two_clusters_stays_the_user(monkeypatch, fake_track):
    voices.store("Борис", "", True, voices.unit(np.array(one_hot(0)) + np.array(one_hot(30))), 30)
    who, _, _ = assign_mic(monkeypatch, mic=[(1, 19, "я"), (31, 49, "снова я")], mic_diar=[(0, 20, "A"), (30, 50, "B")])
    assert who[:2] == ["Я", "Я"]


def test_a_quiet_second_cluster_stays_the_user(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(0), 30)
    who, _, _ = assign_mic(monkeypatch, mic=[(1, 19, "я"), (21, 34.9, "тихий")],
                           mic_diar=[(0, 20, "A"), (20, 34.9, "B")])
    assert who[:2] == ["Я", "Я"]


def test_exactly_15_seconds_is_a_person(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(0), 30)
    who, _, _ = assign_mic(monkeypatch, mic=[(1, 19, "я"), (21, 34, "гость")], mic_diar=[(0, 20, "A"), (20, 35, "B")])
    assert who[:2] == ["Я", "Собеседник 3"]


def test_no_own_print_leaves_the_mic_alone(monkeypatch, fake_track):
    voices.store("Анна Петрова", "acme", False, one_hot(20), 30)
    who, logs, runs = assign_mic(monkeypatch)
    assert who[:2] == ["Я", "Я"]
    assert "m" not in runs
    assert any("нет образца твоего голоса" in m for m in logs)


def test_own_print_of_another_model_does_not_count(monkeypatch, fake_track):
    rec = voices.store("Борис", "", True, one_hot(0), 30)
    voices.save({**rec, "model": "other/512"})
    who, _, runs = assign_mic(monkeypatch)
    assert who[:2] == ["Я", "Я"] and "m" not in runs


def test_no_cluster_like_me_leaves_the_mic_alone(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(7), 30)
    who, logs, runs = assign_mic(monkeypatch)
    assert who[:2] == ["Я", "Я"]
    assert runs.count("m") == 1
    assert any("твой голос в микрофоне не найден" in m for m in logs)


def test_the_other_side_leaking_into_the_mic_is_not_a_person(monkeypatch, fake_track):
    """Echo guard: the mic cluster starts when SPEAKER_01 does, so its print is that system voice's."""
    voices.store("Борис", "", True, one_hot(0), 30)
    who, logs, _ = assign_mic(monkeypatch, mic=[(1, 9, "я"), (56, 74, "эхо")], mic_diar=[(0, 10, "A"), (55, 75, "B")])
    assert who[:2] == ["Я", "Я"]
    assert any("эхо" in m for m in logs)


def far_voices(monkeypatch, vecs: dict):
    """Each microphone cluster gets the print given here; the system track's voices are unlike any of them."""
    def cluster_vectors(path, diar, known=None):
        if path == "m":
            return {label: np.array(vecs[label]) for label in dict.fromkeys(lab for *_, lab in diar)}
        return {label: np.array(one_hot(100 + i)) for i, label in enumerate(dict.fromkeys(lab for *_, lab in diar))}
    monkeypatch.setattr(voices, "cluster_vectors", cluster_vectors)


FOUR_MIC = [(1, 19, "я"), (21, 39, "дальний 1"), (41, 59, "дальний 2"), (61, 79, "дальний 3"), (81, 99, "сосед")]
FOUR_DIAR = [(0, 20, "A"), (20, 40, "B"), (40, 60, "C"), (60, 80, "D"), (80, 100, "E")]


def test_similar_unknown_voices_at_the_mic_are_one_label(monkeypatch, fake_track):
    """People far from the microphone blur together: clusters linked through a similar one are one label,
    a clearly different person next to the user keeps their own."""
    voices.store("Борис", "", True, one_hot(0), 30)
    far_voices(monkeypatch, {"A": one_hot(0), "B": one_hot(10), "C": mix(10, 11, 0.7), "D": mix(11, 12, 0.75),
                             "E": one_hot(30)})
    who, logs, _ = assign_mic(monkeypatch, mic=FOUR_MIC, mic_diar=FOUR_DIAR)
    assert who[:5] == ["Я", "Собеседник 3", "Собеседник 3", "Собеседник 3", "Собеседник 4"]
    assert any("Собеседник 3, Собеседник 4" in m for m in logs)


def test_unlike_unknown_voices_at_the_mic_stay_apart(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(0), 30)
    far_voices(monkeypatch, {"A": one_hot(0), "B": one_hot(10), "C": mix(10, 11, 0.45), "D": one_hot(20),
                             "E": one_hot(30)})
    who, _, _ = assign_mic(monkeypatch, mic=FOUR_MIC, mic_diar=FOUR_DIAR)
    assert who[:5] == ["Я", "Собеседник 3", "Собеседник 4", "Собеседник 5", "Собеседник 6"]


def test_a_voice_recognized_by_its_print_is_never_merged(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(0), 30)
    voices.store("Анна Петрова", "acme", False, one_hot(10), 30)
    far_voices(monkeypatch, {"A": one_hot(0), "B": one_hot(10), "C": mix(10, 11, 0.7), "D": one_hot(20),
                             "E": one_hot(30)})
    who, _, _ = assign_mic(monkeypatch, mic=FOUR_MIC, mic_diar=FOUR_DIAR)
    assert who[1] == "Анна Петрова"
    assert who[2] == "Собеседник 3"  # like Anna, but not recognized as her


# --- each long remote paragraph checked against the saved voices ---

def refine(items, logs=None, **kw):
    return voices.refine_by_print("s", items, voices.load_all(), (logs if logs is not None else []).append, **kw)


def test_long_remote_lines_get_the_voice_they_sound_like(fake_track):
    """One cluster that holds two people (diarization split by kind of speech, not by voice)."""
    voices.store("Евгений", "acme", False, one_hot(10), 30)
    voices.store("Алексей", "acme", False, one_hot(20), 30)
    items = [(10, 16, "долгий рассказ", "Собеседник 2"), (20, 27, "другой рассказ", "Собеседник 2")]
    logs = []
    assert [w for *_, w in refine(items, logs)] == ["Евгений", "Алексей"]
    assert logs


def test_a_line_alike_to_both_voices_keeps_its_label(fake_track):
    voices.store("Евгений", "acme", False, mix(10, 11, 0.8), 30)
    voices.store("Алексей", "acme", False, mix(10, 12, 0.75), 30)
    items = [(10, 16, "кто-то", "Собеседник 2")]
    assert refine(items) == items


def test_one_saved_voice_is_not_enough_to_relabel(fake_track):
    voices.store("Алексей", "acme", False, one_hot(20), 30)
    items = [(20, 27, "рассказ", "Собеседник 2")]
    assert refine(items) == items


def test_a_short_line_follows_the_nearest_long_line_of_its_label(fake_track):
    voices.store("Евгений", "acme", False, one_hot(10), 30)
    voices.store("Алексей", "acme", False, one_hot(20), 30)
    items = [(10, 16, "рассказ", "Собеседник 2"), (16, 17, "ага", "Собеседник 2"), (40, 41, "далеко", "Собеседник 2")]
    assert [w for *_, w in refine(items)] == ["Евгений", "Евгений", "Собеседник 2"]


def test_the_users_own_voice_is_never_a_candidate(fake_track):
    voices.store("Борис", "", True, one_hot(10), 30)
    voices.store("Алексей", "acme", False, one_hot(20), 30)
    voices.store("Евгений", "acme", False, one_hot(30), 30)
    items = [(10, 16, "похоже на меня", "Собеседник 2")]
    assert refine(items) == items


def merged_system(monkeypatch, vectors, diar, **kw):
    logs = []
    monkeypatch.setattr(voices, "cluster_vectors", lambda path, d, known=None: {
        label: (None if vectors[label] is None else np.array(vectors[label])) for label in dict.fromkeys(x for *_, x in d)})
    return voices.merge_same_voice("s", diar, logs.append, {}, **kw), logs


def test_one_voice_split_in_two_on_the_system_track_is_one_label(monkeypatch):
    diar = [(0, 60, "A"), (60, 70, "B"), (70, 100, "C")]
    out, logs = merged_system(monkeypatch, {"A": mix(1, 2, 0.97), "B": mix(1, 3, 0.97), "C": one_hot(20)}, diar)
    assert out == [(0, 60, "A"), (60, 70, "A"), (70, 100, "C")]  # named after the cluster with the most speech
    assert logs


def test_similar_but_different_people_on_the_system_track_stay_apart(monkeypatch):
    """0.7 is what two voices of one real call measured: wespeaker calls it the same person, we are not that sure."""
    diar = [(0, 60, "A"), (60, 70, "B")]
    out, logs = merged_system(monkeypatch, {"A": one_hot(1), "B": mix(1, 2, 0.7)}, diar)
    assert out == diar and not logs


def test_a_cluster_without_a_print_is_left_alone(monkeypatch):
    diar = [(0, 60, "A"), (60, 61, "B")]
    assert merged_system(monkeypatch, {"A": one_hot(1), "B": None}, diar)[0] == diar


def assign_system(monkeypatch, same_voice, speakers_n=3):
    monkeypatch.setattr(speakers.diarize, "available", lambda: True)
    logs = []
    items = speakers.assign_speakers(
        mic=[], mic_dead=[], system=[(1, 9, "первый"), (11, 19, "второй")], tracks={"system": "s"}, me="Я", names=[],
        speakers=speakers_n, diarize_on=True, single_name=None, log=logs.append,
        run_diarization=lambda path, k=None: [(0, 10, "A"), (10, 20, "B")], name_voices=lambda t, d: {},
        same_voice=same_voice)
    return [w for *_, w in items], logs


def test_a_merged_voice_keeps_one_label_in_the_transcript(monkeypatch):
    who, _ = assign_system(monkeypatch, lambda d: [(s, e, "A") for s, e, _ in d])
    assert len(set(who)) == 1


def test_a_failure_of_the_merge_keeps_the_split(monkeypatch):
    def boom(d):
        raise RuntimeError("no model")
    who, logs = assign_system(monkeypatch, boom)
    assert len(set(who)) == 2
    assert any("no model" in m for m in logs)


def test_mic_diarization_failure_keeps_todays_labels(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(0), 30)
    who, logs, _ = assign_mic(monkeypatch, fail_mic=True)
    assert who == ["Я", "Я", "Собеседник 1", "Собеседник 2"]
    assert any("второй человек у микрофона" in m and "no mps" in m for m in logs)


def test_embedding_failure_keeps_todays_labels(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(0), 30)
    monkeypatch.setattr(voices, "embed", lambda pieces, sr=SR: (_ for _ in ()).throw(voices.VoiceUnavailable("нет")))
    who, logs, _ = assign_mic(monkeypatch)
    assert who[:2] == ["Я", "Я"]
    assert any("второй человек у микрофона" in m for m in logs)


def test_too_little_mic_speech_is_not_diarized(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(0), 30)
    who, _, runs = assign_mic(monkeypatch, mic=[(1, 9, "я"), (21, 27, "ещё")])
    assert who[:2] == ["Я", "Я"] and "m" not in runs


def test_one_mic_voice_is_not_embedded(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(0), 30)

    def boom(pieces, sr=SR):
        raise AssertionError("nothing to compare")
    monkeypatch.setattr(voices, "embed", boom)
    who, _, _ = assign_mic(monkeypatch, mic=[(1, 39, "я")], mic_diar=[(0, 40, "A")], system=[], system_diar=[])
    assert who == ["Я"]


def test_mic_without_diarization_is_not_touched(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(0), 30)
    who, _, runs = assign_mic(monkeypatch, diarize_on=False)
    assert who[:2] == ["Я", "Я"] and runs == []


def test_dead_system_audio_still_diarizes_the_mic_once(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(0), 30)
    who, _, runs = assign_mic(monkeypatch, mic_dead=[(21, 39, "гость")], mic=[(1, 9, "я")], mic_diar=MIC_DIAR)
    assert runs.count("m") == 1
    assert who[0] == "Я"


def test_system_voices_are_embedded_once(monkeypatch, fake_track):
    """The echo guard compares against the embeddings that naming the system voices already made."""
    voices.store("Борис", "", True, one_hot(0), 30)
    voices.store("Олег", "acme", False, one_hot(99), 30)  # so that identify embeds the system voices
    fake = voices.embed
    count = []

    def counting(pieces, sr=SR):
        count.append(1)
        return fake(pieces, sr)
    monkeypatch.setattr(voices, "embed", counting)
    assign_mic(monkeypatch)
    assert len(count) == 4  # 2 system voices + 2 mic voices, nothing twice


def test_system_failure_leaves_the_mic_alone(monkeypatch, fake_track):
    voices.store("Борис", "", True, one_hot(0), 30)
    monkeypatch.setattr(speakers.diarize, "available", lambda: True)
    runs = []

    def run_diarization(path, k=None):
        runs.append(path)
        raise RuntimeError("no mps")
    logs = []
    items = speakers.assign_speakers(
        mic=list(MIC_SEGS), mic_dead=[], system=list(SYSTEM_SEGS), tracks={"mic": "m", "system": "s"}, me="Я", names=[],
        speakers=None, diarize_on=True, single_name=None, log=logs.append, run_diarization=run_diarization,
        mic_people=lambda diarize_mic, sys_diar: voices.mic_people("m", diarize_mic, "s", sys_diar, "", logs.append, {}))
    assert [w for *_, w in items][:2] == ["Я", "Я"]
    assert runs == ["s"]


def _two_track_call(tmp_path, monkeypatch, data, kind=None):
    from sozvon_engine.pipeline import transcribe
    d = _system_only_call(tmp_path, monkeypatch, data)
    (d / "mic.m4a").write_bytes(b"\0" * 2048)
    call = {"schema": 1, "id": "2026-11-04 15-01", "status": "recorded",
            "audio": {"system_start": 0.0, "mic_start": 0.0}}
    if kind:
        call["kind"] = kind
    (d / "call.json").write_text(json.dumps(call))
    monkeypatch.setattr(transcribe, "transcribe_tracks", lambda tr, **kw: (
        {"mic": list(MIC_SEGS), "system": list(SYSTEM_SEGS)}, {"mic": "ru", "system": "ru"}))
    runs = []

    def run_diar(path, num_speakers=None):
        runs.append(Path(path).stem)
        return MIC_DIAR if Path(path).stem.startswith("mic") else SYSTEM_DIAR
    monkeypatch.setattr(diarize, "run", run_diar)
    return d, runs


def test_run_names_a_second_person_and_lists_them(tmp_path, capsys, monkeypatch, fake_track, data):
    voices.store("Борис", "", True, one_hot(0), 30)
    voices.store("Анна Петрова", "", False, one_hot(20), 30)
    d, runs = _two_track_call(tmp_path, monkeypatch, data)
    assert run.main([str(d)]) == 0
    assert "Анна Петрова: гость" in (d / "transcript.txt").read_text()
    call = json.loads((d / "call.json").read_text())
    assert "Анна Петрова" in call["participants"]
    assert len([r for r in runs if r.startswith("mic")]) == 1
    assert call["speaker_tracks"] == {"Я": "mic", "Анна Петрова": "mic", "Собеседник 1": "system", "Собеседник 2": "system"}


def test_run_without_a_mic_person_leaves_no_speaker_tracks(tmp_path, capsys, monkeypatch, fake_track, data):
    """Today's calls get no new field, and a transcription that finds nobody removes an old one."""
    d, _ = _two_track_call(tmp_path, monkeypatch, data)
    call = json.loads((d / "call.json").read_text())
    (d / "call.json").write_text(json.dumps({**call, "speaker_tracks": {"Вера": "mic"}}))
    assert run.main([str(d)]) == 0
    assert "speaker_tracks" not in json.loads((d / "call.json").read_text())


def test_speaker_tracks_follow_the_assistants_names():
    items = [(0, 1, "я", "Я"), (2, 3, "гость", "Собеседник 3"), (4, 5, "а", "Собеседник 1"), (6, 7, "б", "Олег")]
    assert speakers.track_labels(items, 2, {"Собеседник 3": "Вера"}, "Я") == {
        "Я": "mic", "Вера": "mic", "Собеседник 1": "system", "Олег": "system"}


def test_speaker_tracks_mark_a_person_on_both_tracks():
    items = [(0, 1, "я", "Я"), (2, 3, "гость", "Анна"), (4, 5, "а", "Анна")]
    assert speakers.track_labels(items, 2, {}, "Я") == {"Я": "mic", "Анна": "both"}


def test_speaker_tracks_are_nothing_when_the_mic_is_only_the_user():
    assert speakers.track_labels([(0, 1, "я", "Я"), (4, 5, "а", "Анна")], 1, {}, "Я") is None


def test_run_never_splits_the_mic_of_a_reflection(tmp_path, capsys, monkeypatch, fake_track, data):
    voices.store("Борис", "", True, one_hot(0), 30)
    d, runs = _two_track_call(tmp_path, monkeypatch, data, kind="reflection")
    assert run.main([str(d)]) == 0
    assert runs == []
    assert "гость" in (d / "transcript.txt").read_text() and "Собеседник" not in (d / "transcript.txt").read_text()


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


@pytest.fixture
def voices_on(monkeypatch):
    """Send voice prints turned on: it is off unless the user asked for it."""
    monkeypatch.setenv("SOZVON_SYNC_VOICES", "1")


def server_rec(name, vec, at="2026-11-05T10:00:00Z", **kw):
    r = rec(name, vec, **kw)
    r["updated_at"] = at
    return r


def test_sync_voices_both_ways(fake, root, data, voices_on):
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


def test_sync_never_overwrites_a_newer_local_voice(fake, root, voices_on):
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


def test_sync_deletions_both_ways(fake, root, voices_on):
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


def test_sync_folds_a_duplicate_from_another_mac(fake, root, voices_on):
    fake.version = "0.4.0"
    mine = voices.store("Анна", "acme", False, one_hot(0), 10)
    dup = server_rec("Анна", one_hot(1), profile="acme")
    fake.voices[dup["id"]] = dup
    remote.sync(root=root)
    recs = voices.load_all()
    assert [r["id"] for r in recs] == [mine["id"]] and recs[0]["seconds"] == 40
    assert fake.voices[dup["id"]]["deleted"] is True and fake.voices[mine["id"]]["seconds"] == 40


def test_sync_merges_a_concurrent_enrollment_of_the_same_voice(fake, root, monkeypatch, voices_on):
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


@pytest.mark.parametrize("value", [None, "0"])
def test_sync_voices_switch_off(fake, root, monkeypatch, value):
    """Off unless asked for (the key absent) and when turned off."""
    fake.version = "0.4.0"
    if value is not None:
        monkeypatch.setenv("SOZVON_SYNC_VOICES", value)
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


def test_sync_voice_failure_keeps_result(fake, root, monkeypatch, voices_on):
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
    assert config.Settings().sync_voices is False
    assert config.load(tmp_path / "none", environ={}).sync_voices is False, "biometric data: opt-in"
    assert config.load(tmp_path / "none", environ={"SOZVON_SYNC_VOICES": "0"}).sync_voices is False
    assert config.load(tmp_path / "none", environ={"SOZVON_SYNC_VOICES": "yes"}).sync_voices is True
    assert config.load(tmp_path / "none", environ={"SOZVON_SYNC_VOICES": "maybe"}).sync_voices is False
    env = tmp_path / ".env"
    env.write_text("SOZVON_SYNC_VOICES=1\n")
    assert config.load(env, environ={}).sync_voices is True


# --- the model of a voice print ---

OTHER = "someone/else-model/512"


def put_foreign(name="Чужой", vec=None, **kw):
    """A record of another embedding model, written straight to disk."""
    r = rec(name, vec or one_hot(40), **kw)
    r["model"] = OTHER
    voices.save(r)
    return r


def test_new_records_carry_the_model():
    assert voices.MODEL == "wespeaker-voxceleb-resnet34-LM/256"
    r = voices.store("Анна", "", False, one_hot(0), 10)
    assert r["model"] == voices.MODEL
    assert json.loads(voices._file(r["id"]).read_text())["model"] == voices.MODEL


def test_a_record_without_the_field_is_the_current_model_and_keeps_its_hash():
    old = rec("Анна", one_hot(0))
    voices.save(old)
    got = voices.load_all()[0]
    assert "model" not in got and voices.is_current(got)
    tagged = {**old, "model": voices.MODEL}
    other = {**old, "model": OTHER}
    # The hash is the same with or without the field (the own server doesn't store it).
    assert voices.content_hash(old) == voices.content_hash(tagged) == voices.content_hash(other)
    import hashlib
    canon = json.dumps({k: old[k] for k in ("id", "name", "profile", "me", "embedding", "seconds", "updated_at")},
                       sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    assert voices.content_hash(old) == hashlib.sha256(canon.encode()).hexdigest()
    assert not voices.is_current(other)


def test_other_models_are_skipped_kept_and_logged_once(monkeypatch):
    mine = voices.store("Анна", "", False, one_hot(0), 10)
    foreign = put_foreign("Олег")
    me_foreign = put_foreign("Борис", me=True)
    monkeypatch.setattr(voices, "_logged_foreign", False)
    lines = []
    assert [r["id"] for r in voices.candidates("", True, log=lines.append)] == [mine["id"]]
    voices.candidates("", True, log=lines.append)
    assert len(lines) == 1 and "2" in lines[0], "logged once per run"
    assert {r["id"] for r in voices.load_all()} == {mine["id"], foreign["id"], me_foreign["id"]}, "kept on disk"
    assert json.loads(voices._file(foreign["id"]).read_text())["model"] == OTHER


def test_store_never_merges_into_another_model():
    foreign = put_foreign("Анна", profile="acme")
    r = voices.store("Анна", "acme", False, one_hot(1), 10)
    assert r["id"] != foreign["id"] and r["embedding"] == one_hot(1) and r["model"] == voices.MODEL
    kept = json.loads(voices._file(foreign["id"]).read_text())
    assert kept["embedding"] == one_hot(40) and kept["model"] == OTHER
    # "me" is unique among the current model only; the foreign "me" stays.
    f_me = put_foreign("Борис", me=True)
    mine = voices.store("Борис", "", True, one_hot(2), 10)
    assert mine["id"] != f_me["id"] and voices._file(f_me["id"]).exists()
    assert voices.tombstones() == {}


def test_merge_embeddings_refuses_another_model():
    with pytest.raises(ValueError):
        voices.merge_embeddings({"embedding": one_hot(0), "seconds": 5.0, "model": OTHER}, one_hot(1), 5.0)
    emb, _ = voices.merge_embeddings({"embedding": one_hot(0), "seconds": 5.0, "model": voices.MODEL}, one_hot(1), 5.0)
    assert emb[0] == pytest.approx(emb[1])


def test_accept_and_merge_remote_keep_the_local_record_of_another_model():
    foreign = put_foreign("Анна")
    newer = {**foreign, "model": voices.MODEL, "embedding": one_hot(3), "updated_at": "2999-01-01T00:00:00Z"}
    assert voices.accept_remote(newer) is False
    assert json.loads(voices._file(foreign["id"]).read_text())["embedding"] == one_hot(40)
    # A conflict at sync: the server's record is another model than the one here.
    assert voices.merge_remote({**newer, "model": OTHER}, {**foreign, "model": voices.MODEL}) is None
    assert voices.merge_remote({**newer}, {**foreign}) is None, "here is another model: kept"
    assert json.loads(voices._file(foreign["id"]).read_text())["embedding"] == one_hot(40)
    # A record of another model from the server is not stored, and does not fold into a current one.
    mine = voices.store("Олег", "", False, one_hot(0), 10)
    assert voices.accept_remote({**rec("Олег", one_hot(5)), "model": OTHER}) is False
    assert [r["embedding"] for r in voices.load_all() if r["name"] == "Олег"] == [mine["embedding"]]


def test_sync_does_not_send_records_of_another_model(fake, root, voices_on):
    fake.version = "0.4.0"
    mine = voices.store("Анна", "", False, one_hot(0), 10)
    foreign = put_foreign("Олег")
    remote.sync(root=root)
    assert mine["id"] in fake.voices and foreign["id"] not in fake.voices


def test_my_name_from_a_record_of_another_model_still_counts_as_me(monkeypatch):
    put_foreign("Борис Иванов", me=True)
    assert voices.is_me_label("борис иванов")


def test_a_label_on_both_tracks_is_refused_with_its_own_message():
    with pytest.raises(voices.VoiceError) as e:
        voices._recorded_track({"speaker_tracks": {"Вера": "both"}}, "Вера")
    assert "дорожек" in str(e.value) and "Вера" in str(e.value)
