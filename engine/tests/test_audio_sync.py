"""Call audio on the own server: chunked upload, resume, 507, download on a new Mac, audio_removed_at, the switch."""
import json
import urllib.parse
import os

from pathlib import Path

import numpy as np
import pytest

from sozvon_engine import config, remote, remote_audio
from test_remote import fake, make_call, root  # noqa: F401  the fake own server
from test_voices import tone, write_track

CID = "2026-11-04 15-01"


@pytest.fixture(autouse=True)
def small_chunks(monkeypatch):
    monkeypatch.setattr(remote_audio, "CHUNK", 1000)


def audio_call(root, cid=CID, name=None, size=2500, seed=1, **call):
    d = make_call(root, name or cid, cid)
    if call:
        c = json.loads((d / "call.json").read_text())
        (d / "call.json").write_text(json.dumps({**c, **call}))
    data = np.random.default_rng(seed).integers(0, 256, size, dtype=np.uint8).tobytes()
    (d / "mic.m4a").write_bytes(data)
    return d, data


def chunk_puts(fake):
    return [p for m, p, *_ in fake.requests if m == "PUT" and "/audio/" in p]


def test_uploads_tracks_in_chunks(fake, root):
    fake.version = "0.4.0"
    d, data = audio_call(root)
    lines = []
    assert tuple(remote.sync(root=root, status=lines.append)) == (1, 0, 0, 0, 0)
    a = fake.audio[CID]["mic"]
    assert a["data"] == data and a["chunks"] == 3 and a["size"] == 2500
    assert len(chunk_puts(fake)) == 3
    assert "Аудио: отправлено дорожек 1, скачано 0, удалено с сервера звонков 0" in lines
    # Nothing changed: nothing is sent or even hashed again.
    monkeypatch_hash = remote_audio.file_sha256
    remote_audio.file_sha256 = lambda p: (_ for _ in ()).throw(AssertionError("hashed again"))
    try:
        remote.sync(root=root)
    finally:
        remote_audio.file_sha256 = monkeypatch_hash
    assert len(chunk_puts(fake)) == 3
    # A changed track goes up again.
    (d / "mic.m4a").write_bytes(data[:1500])
    remote.sync(root=root)
    assert fake.audio[CID]["mic"]["data"] == data[:1500] and len(chunk_puts(fake)) == 5


def test_resumes_an_interrupted_upload(fake, root):
    fake.version = "0.4.0"
    audio_call(root)
    fake.fail_chunk = (CID, "mic", 1)
    lines = []
    sent, _, _, _, failed = remote.sync(root=root, status=lines.append)
    assert (sent, failed) == (1, 1), "the call's text went up, its audio failed and counts"
    assert CID not in fake.audio and sorted(fake.staged[(CID, "mic")]["chunks"]) == [0]
    assert any(x.startswith(f"Не получилось с {CID}") for x in lines)
    before = len(chunk_puts(fake))
    assert tuple(remote.sync(root=root)) == (0, 0, 0, 0, 0)
    assert [p.rsplit("/", 1)[1] for p in chunk_puts(fake)[before:]] == ["1", "2"], "chunk 0 is not sent again"
    assert fake.audio[CID]["mic"]["size"] == 2500


def test_storage_full_stops_audio_not_text(fake, root):
    fake.version = "0.4.0"
    audio_call(root, "2026-11-04 15-01", seed=1)
    audio_call(root, "2026-11-04 16-00", seed=2)
    fake.audio_limit = 1500
    lines = []
    assert tuple(remote.sync(root=root, status=lines.append)) == (2, 0, 0, 0, 0)
    assert set(fake.calls) == {"2026-11-04 15-01", "2026-11-04 16-00"}, "text still syncs"
    assert fake.audio == {}
    full = [x for x in lines if x.startswith("Бесплатное место для аудио")]
    assert len(full) == 1
    puts = [p for p in chunk_puts(fake)]
    assert all("16-00" not in p for p in puts), "no more audio tried after the 507"


def test_downloads_audio_for_a_restored_call(fake, root, tmp_path):
    fake.version = "0.4.0"
    track = write_track(tmp_path / "t.m4a", tone(300, 2.0))
    data = track.read_bytes()
    fake.put({"schema": 1, "id": CID, "hash": "a" * 64, "folder": f"{CID} · acme",
              "call": {"schema": 1, "id": CID, "status": "done"}, "transcript": "[00:00] Я: Привет.\n", "summary": None})
    import hashlib
    fake.audio[CID] = {"system": {"size": len(data), "chunks": -(-len(data) // 1000),
                                  "sha256": hashlib.sha256(data).hexdigest(), "data": data}}
    lines = []
    remote.sync(root=root, status=lines.append)
    d = root / f"{CID} · acme"
    assert (d / "system.m4a").read_bytes() == data
    assert not [f for f in os.listdir(d) if f.startswith(".download-")]
    meta = json.loads((d / "call.json").read_text())["audio"]
    assert meta["system_seconds"] == pytest.approx(2.0, abs=0.2)
    assert "Аудио: отправлено дорожек 0, скачано 1, удалено с сервера звонков 0" in lines
    before = len(fake.requests)
    remote.sync(root=root)
    assert not [p for m, p, *_ in fake.requests[before:] if "/audio" in p], "in step: nothing to do"


def test_bad_download_leaves_nothing(fake, root):
    fake.version = "0.4.0"
    d = make_call(root, CID, CID)
    (d / "mic.m4a").unlink()
    fake.put(remote.payload(d))
    fake.audio[CID] = {"mic": {"size": 5, "chunks": 1, "sha256": "0" * 64, "data": b"12345"}}
    _, _, _, _, failed = remote.sync(root=root)
    assert failed == 1 and not (d / "mic.m4a").exists() and not [f for f in os.listdir(d) if f.startswith(".")]


def test_removed_audio_is_deleted_on_the_server_and_never_synced(fake, root):
    fake.version = "0.4.0"
    d, data = audio_call(root, audio_removed_at="2026-12-04T09:00:00Z")
    (d / "mic.m4a").unlink()
    # The server still has a copy from before: deleted there, marked removed, never downloaded.
    fake.put(remote.payload(d))
    fake.audio[CID] = {"mic": {"size": 2500, "chunks": 3, "sha256": "f" * 64, "data": data}}
    lines = []
    remote.sync(root=root, status=lines.append)
    assert CID not in fake.audio and not (d / "mic.m4a").exists() and CID in fake.audio_removed
    assert ("DELETE", f"/api/calls/{CID.replace(' ', '%20')}/audio") in [(m, p) for m, p, *_ in fake.requests]
    assert "Аудио: отправлено дорожек 0, скачано 0, удалено с сервера звонков 1" in lines
    # Marked: the next sync sends nothing more for it.
    before = len(fake.requests)
    remote.sync(root=root)
    assert not [p for _, p, *_ in fake.requests[before:] if "/audio" in p]


def test_removal_is_marked_even_when_the_server_has_no_audio(fake, root):
    fake.version = "0.4.0"
    audio_call(root, audio_removed_at="2026-12-04T09:00:00Z")
    lines = []
    remote.sync(root=root, status=lines.append)
    assert CID not in fake.audio and not chunk_puts(fake), "never uploaded"
    assert CID in fake.audio_removed, "the removal is a fact on the server"
    assert not any(x.startswith("Аудио:") for x in lines), "nothing was deleted there"


def test_audio_removed_on_another_mac_is_never_synced_again(fake, tmp_path, data):
    """No ping-pong: Mac A removed the audio, Mac B still has its tracks, keeps them, and never uploads them."""
    fake.version = "0.4.0"
    a, b = tmp_path / "a", tmp_path / "b"
    da, track = audio_call(a)
    db_, _ = audio_call(b)
    remote.sync(root=a)
    assert fake.audio[CID]["mic"]["data"] == track
    # Mac A's retention setting removed the tracks.
    (da / "mic.m4a").unlink()
    c = json.loads((da / "call.json").read_text())
    (da / "call.json").write_text(json.dumps({**c, "audio_removed_at": "2026-12-04T09:00:00Z"}))
    remote.sync(root=a)
    assert CID not in fake.audio and CID in fake.audio_removed
    # Mac B: its own copy differs from nothing on the server now, yet nothing goes up, and its tracks stay.
    (db_ / "mic.m4a").write_bytes(track[:1500])
    before = len(chunk_puts(fake))
    remote.sync(root=b)
    assert len(chunk_puts(fake)) == before and CID not in fake.audio
    assert (db_ / "mic.m4a").read_bytes() == track[:1500], "other Macs keep their own audio"
    # A direct push is refused by the mark too.
    srv = remote.server()
    assert remote_audio.push_call_audio(srv, db_) == 0
    # Mac B without its tracks never downloads any, even if the server somehow held some.
    (db_ / "mic.m4a").unlink()
    fake.audio[CID] = {"mic": {"size": 1500, "chunks": 2, "sha256": "f" * 64, "data": track[:1500]}}
    remote.sync(root=b)
    assert not (db_ / "mic.m4a").exists()
    assert remote_audio.pull_call_audio(srv, db_) == 0


def test_start_offsets_go_up_and_come_down(fake, root, tmp_path):
    fake.version = "0.4.0"
    d, data = audio_call(root, audio={"mic_start": 3764879.93, "system_start": 3764879.64,
                                      "mic_seconds": 1.0, "system_seconds": 1.0})
    (d / "system.m4a").write_bytes(data[::-1])
    remote.sync(root=root)
    assert fake.audio[CID]["mic"]["start"] == pytest.approx(0.29)
    assert fake.audio[CID]["system"]["start"] == 0
    # The text hash does not depend on them.
    assert fake.calls[CID]["hash"] == remote.content_hash(remote.payload(d)["call"], "[00:00] Я: Привет.\n", None)
    assert "mic_start" not in json.dumps(fake.calls[CID])
    # A new Mac restores the call, then its tracks with the offsets.
    other = tmp_path / "other"
    other.mkdir()
    real = write_track(tmp_path / "t.m4a", tone(300, 1.0)).read_bytes()
    import hashlib
    for tr, start in (("mic", 0.29), ("system", 0)):
        fake.audio[CID][tr] = {"size": len(real), "chunks": -(-len(real) // 1000),
                               "sha256": hashlib.sha256(real).hexdigest(), "data": real, "start": start}
    remote.sync(root=other)
    (nd,) = [p for p in other.iterdir() if p.is_dir()]
    meta = json.loads((nd / "call.json").read_text())["audio"]
    assert meta["mic_start"] == pytest.approx(0.29) and meta["system_start"] == 0
    from sozvon_engine.pipeline import tracks
    assert tracks.delays(meta) == {"mic": pytest.approx(0.29), "system": 0.0}


def test_download_never_mixes_offsets_with_host_times(fake, root, tmp_path):
    fake.version = "0.4.0"
    d = make_call(root, CID, CID)
    (d / "mic.m4a").unlink()
    c = json.loads((d / "call.json").read_text())
    (d / "call.json").write_text(json.dumps({**c, "audio": {"system_start": 3764879.64}}))
    fake.put(remote.payload(d))
    real = write_track(tmp_path / "t.m4a", tone(300, 1.0)).read_bytes()
    import hashlib
    fake.audio[CID] = {"mic": {"size": len(real), "chunks": -(-len(real) // 1000),
                               "sha256": hashlib.sha256(real).hexdigest(), "data": real, "start": 0.29}}
    remote.sync(root=root)
    meta = json.loads((d / "call.json").read_text())["audio"]
    assert (d / "mic.m4a").exists() and "mic_start" not in meta and meta["system_start"] == 3764879.64


def test_stale_download_leftovers_are_removed(fake, root, tmp_path):
    fake.version = "0.4.0"
    d = make_call(root, CID, CID)
    (d / "mic.m4a").unlink()
    fake.put(remote.payload(d))
    old = d / ".download-0123.m4a"
    old.write_bytes(b"half")
    os.utime(old, (1, 1))
    fresh = d / ".download-4567.m4a"  # another download in progress right now
    fresh.write_bytes(b"busy")
    real = write_track(tmp_path / "t.m4a", tone(300, 1.0)).read_bytes()
    import hashlib
    fake.audio[CID] = {"mic": {"size": len(real), "chunks": -(-len(real) // 1000),
                               "sha256": hashlib.sha256(real).hexdigest(), "data": real}}
    remote.sync(root=root)
    assert (d / "mic.m4a").read_bytes() == real
    assert not old.exists() and fresh.exists()


def test_switch_off(fake, root, monkeypatch):
    fake.version = "0.4.0"
    monkeypatch.setenv("SOZVON_SYNC_AUDIO", "0")
    audio_call(root)
    gone, data = audio_call(root, "2026-11-04 16-00", audio_removed_at="2026-12-04T09:00:00Z")
    (gone / "mic.m4a").unlink()
    fake.put(remote.payload(gone))
    fake.audio["2026-11-04 16-00"] = {"mic": {"size": 1, "chunks": 1, "sha256": "f" * 64, "data": b"x"}}
    remote.sync(root=root)
    assert not chunk_puts(fake) and "2026-11-04 16-00" not in fake.audio, "removed audio is still deleted"
    assert config.load().sync_audio is False


def test_older_server_gets_no_audio(fake, root):
    fake.version = "0.3.3"
    audio_call(root)
    remote.sync(root=root)
    assert not [p for _, p, *_ in fake.requests if "/audio" in p]


def test_push_after_transcription_sends_only_text(fake, root):
    """Audio goes up with the app's background sync after the transcription, never inline in process_call."""
    fake.version = "0.4.0"
    d, data = audio_call(root)
    logs = []
    remote.push_after_transcription(d, logs.append)
    assert CID in fake.calls and CID not in fake.audio and not chunk_puts(fake)
    assert logs == ["звонок отправлен на свой сервер"]
    remote.sync(root=root)
    assert fake.audio[CID]["mic"]["data"] == data


def test_sync_audio_key(tmp_path):
    assert config.load(tmp_path / "none", environ={}).sync_audio is True
    assert config.load(tmp_path / "none", environ={"SOZVON_SYNC_AUDIO": "0"}).sync_audio is False


def test_start_offsets():
    assert remote_audio.start_offsets({"mic_start": 10.5, "system_start": 10.0}) == {"mic": 0.5, "system": 0.0}
    assert remote_audio.start_offsets({"system_start": 0}) == {"system": 0.0}
    assert remote_audio.start_offsets({"mic_seconds": 3}) == {}
    assert remote_audio.start_offsets({"mic_start": True, "system_start": 1.0}) == {"system": 0.0}
    assert remote_audio.start_offsets({"mic_start": 1e9, "system_start": 0.0}) == {"system": 0.0}, "out of range"


# --- a call trimmed on another Mac (server 0.5.0+) ---

TRIM_AT = "2026-11-05T09:30:00Z"
NOTE = {"id": "0b7e0c4e-5f1a-4c3a-9d41-5d2f7f1a0a01", "at": "2026-11-05T09:12:44Z", "text": "договор в пятницу"}
KEPT = 30.5  # 40 s tracks here (system 0.5 s after mic): 40.5 s of call, minus 5 s at each end


@pytest.fixture(scope="module")
def tones(tmp_path_factory):
    """Real tracks, made once: {(track, seconds): bytes}."""
    d = tmp_path_factory.mktemp("tones")
    return {(tr, sec): write_track(d / f"{tr}-{sec}.m4a", tone(f, sec)).read_bytes()
            for tr, f in (("mic", 300), ("system", 500)) for sec in (40.0, KEPT)}


def trimmed_elsewhere(fake, root, tones, status="done", server_audio="trimmed", head=5, tail=5):
    """This Mac: the untrimmed call (40 s mic from 100.0, 40 s system from 100.5 on the recording clock), derived
    files, marks and a note. The server: the copy another Mac trimmed by head and tail seconds, holding
    server_audio: "trimmed" (both tracks cut), "untrimmed" (the old tracks: the trimming Mac has not committed its
    new ones yet), "mic" (only a cut mic track) or None. -> (folder, the server's copy)."""
    import hashlib
    from test_remote import server_copy
    fake.version = "0.5.0"
    d, _ = audio_call(root, status=status, notes=[NOTE], marks=[3.0, 12.0, 30.0], silence={"head": 4.0, "tail": 0},
                      audio={"mic_start": 100.0, "system_start": 100.5, "mic_seconds": 40.0, "system_seconds": 40.0},
                      engine={"model": "turbo"})
    (d / "mic.m4a").write_bytes(tones[("mic", 40.0)])
    (d / "system.m4a").write_bytes(tones[("system", 40.0)])
    (d / "mic.clean.m4a").write_bytes(b"c" * 2000)
    (d / "listen.m4a").write_bytes(b"l" * 2000)
    (d / "summary.md").write_text("старое резюме\n", encoding="utf-8")
    kept = 40.5 - head - tail
    copy = server_copy(CID, folder=CID, call={
        "schema": 1, "id": CID, "status": "done", "topic": "запуск", "summary": True,
        "audio": {"mic_seconds": kept, "system_seconds": kept},
        "trimmed": {"at": TRIM_AT, "head": head, "tail": tail}})
    fake.put(copy)
    kinds = {"trimmed": ("mic", "system"), "untrimmed": ("mic", "system"), "mic": ("mic",), None: ()}[server_audio]
    for tr in kinds:
        set_server_track(fake, tr, tones[(tr, 40.0 if server_audio == "untrimmed" else KEPT)])
    return d, copy


def set_server_track(fake, track, data, start=0):
    import hashlib
    fake.audio.setdefault(CID, {})[track] = {"size": len(data), "chunks": -(-len(data) // 1000),
                                             "sha256": hashlib.sha256(data).hexdigest(), "data": data,
                                             "start": start}


def writes(fake, since=0):
    return [(m, p) for m, p, *_ in fake.requests[since:] if m in ("PUT", "POST", "DELETE")]


def audio_reads(fake, since=0):
    return [p for m, p, *_ in fake.requests[since:] if m == "GET" and "/audio/" in p]


def call_json(d):
    return json.loads((d / "call.json").read_text())


def files_of(d):
    return {f.name: f.read_bytes() for f in d.iterdir() if f.is_file()}


def assert_server_text(d, copy):
    assert (d / "transcript.txt").read_text(encoding="utf-8") == copy["transcript"]
    assert (d / "summary.md").read_text(encoding="utf-8") == copy["summary"]
    assert "Пока" in (d / "transcript.md").read_text(encoding="utf-8")
    call = call_json(d)
    assert call["trimmed"] == copy["call"]["trimmed"] and call["summary"] is True
    assert call["notes"] == [NOTE], "notes stay"
    assert call["engine"] == {"model": "turbo"}, "local-only keys stay"
    assert "silence" not in call, "it described the old timeline"
    assert call["marks"] == [7.0, 25.0], "marks moved by the head the server cut"
    assert not (d / "mic.clean.m4a").exists() and not (d / "listen.m4a").exists()
    assert remote.payload(d)["hash"] == copy["hash"], "this copy now hashes as the server's"


def assert_cut_here(d, tracks=("mic", "system")):
    from sozvon_engine import audio
    for tr in tracks:
        assert audio.duration(d / f"{tr}.m4a") == pytest.approx(KEPT, abs=0.15), f"{tr} cut 5 s at each end"
    call = call_json(d)
    assert call["audio"] == {"mic_start": 105.0, "system_start": 105.0, "mic_seconds": KEPT, "system_seconds": KEPT}
    assert call["audio_cut_from"] == TRIM_AT


def assert_still_untrimmed(d, before):
    assert files_of(d) == before, "nothing here changed or went"
    assert "trimmed" not in call_json(d)


def test_server_newer_trim_replaces_local_copy(fake, root, tones, monkeypatch):
    """Audio sync off here: the tracks here are cut to the server's trim, nothing is downloaded or deleted."""
    monkeypatch.setenv("SOZVON_SYNC_AUDIO", "0")
    d, copy = trimmed_elsewhere(fake, root, tones)
    lines = []
    assert tuple(remote.sync(root=root, status=lines.append)) == (0, 0, 1, 0, 0)
    assert not writes(fake) and not audio_reads(fake), "nothing uploaded, nothing downloaded"
    assert_cut_here(d)
    assert_server_text(d, copy)
    assert any(CID in x and "обрезан" in x for x in lines)


def test_server_trimmed_audio_is_pulled_when_synced(fake, root, tones):
    d, copy = trimmed_elsewhere(fake, root, tones)
    assert tuple(remote.sync(root=root)) == (0, 0, 1, 0, 0)
    assert not writes(fake), "the untrimmed copy is never uploaded"
    for tr in ("mic", "system"):
        assert (d / f"{tr}.m4a").read_bytes() == tones[(tr, KEPT)], "the server's trimmed tracks replaced the ones here"
    assert_server_text(d, copy)
    call = call_json(d)
    assert call["audio"] == {"mic_seconds": KEPT, "system_seconds": KEPT, "mic_start": 0, "system_start": 0}
    assert "audio_cut_from" not in call
    assert not [p for p in d.iterdir() if p.name.startswith(".sync-")]


def test_untrimmed_server_audio_is_never_pulled(fake, root, tones):
    """The trimming Mac sent its text, not yet its tracks: the server still serves the old ones. They are not taken;
    the tracks here are cut, and stay so (never sent, never replaced) after the trimming Mac commits its own."""
    d, copy = trimmed_elsewhere(fake, root, tones, server_audio="untrimmed")
    assert tuple(remote.sync(root=root)) == (0, 0, 1, 0, 0)
    assert_cut_here(d)
    assert_server_text(d, copy)
    assert not [p for p in d.iterdir() if p.name.startswith(".sync-")]
    remote.sync(root=root)  # the note this Mac had goes up once
    for tr in ("mic", "system"):  # the trimming Mac commits its tracks now
        set_server_track(fake, tr, tones[(tr, KEPT)])
    here = files_of(d)
    before = len(fake.requests)
    for _ in range(2):
        assert tuple(remote.sync(root=root)) == (0, 0, 0, 0, 0)
    assert not writes(fake, before) and not audio_reads(fake, before), "no loop either way"
    assert files_of(d) == here


def test_partial_server_audio_keeps_the_local_track(fake, root, tones):
    d, copy = trimmed_elsewhere(fake, root, tones, server_audio="mic")
    assert remote.sync(root=root).downloaded == 1
    assert_cut_here(d)  # the system track the server lacks is cut here, not deleted
    assert_server_text(d, copy)


def test_replace_keeps_audio_when_server_has_none(fake, root, tones):
    d, copy = trimmed_elsewhere(fake, root, tones, server_audio=None)
    assert remote.sync(root=root).downloaded == 1
    assert_cut_here(d)
    assert_server_text(d, copy)
    remote.sync(root=root)
    assert not chunk_puts(fake) and CID not in fake.audio, \
        "tracks cut here are never sent over the trimming Mac's own"


def test_mismatched_trim_is_skipped_not_deleted(fake, root, tones):
    d, copy = trimmed_elsewhere(fake, root, tones, head=366, tail=290)  # not the same recording
    before = files_of(d)
    for _ in range(2):
        lines = []
        _, _, downloaded, _, failed = remote.sync(root=root, status=lines.append)
        assert (downloaded, failed) == (0, 1), "the user sees it"
        assert_still_untrimmed(d, before)
        assert any(CID in x and "не совпадает" in x for x in lines)
    assert not writes(fake) and not audio_reads(fake)


def test_stale_lengths_in_call_json_are_refused(fake, root, tones):
    """A cut whose call.json write failed: the tracks are shorter than call.json says. Cutting on those numbers would
    cut them twice: refused, nothing changes."""
    d, copy = trimmed_elsewhere(fake, root, tones)
    c = call_json(d)
    (d / "call.json").write_text(json.dumps({**c, "audio": {**c["audio"], "mic_seconds": 45.0}}))
    before = files_of(d)
    lines = []
    _, _, downloaded, _, failed = remote.sync(root=root, status=lines.append)
    assert (downloaded, failed) == (0, 1)
    assert_still_untrimmed(d, before)
    assert any(CID in x and "call.json" in x for x in lines)


@pytest.mark.parametrize("server_audio", ["trimmed", None])
def test_no_reupload_loop(fake, root, tones, server_audio):
    d, copy = trimmed_elsewhere(fake, root, tones, server_audio=server_audio)
    assert remote.sync(root=root).downloaded == 1
    before = len(fake.requests)
    assert remote.sync(root=root).sent == 1
    assert writes(fake, before) == [("POST", f"/api/calls/{urllib.parse.quote(CID)}/notes")], \
        "only the note this Mac had goes up, once: never the call or its tracks"
    before = len(fake.requests)
    assert tuple(remote.sync(root=root)) == (0, 0, 0, 0, 0)
    assert tuple(remote.sync(root=root)) == (0, 0, 0, 0, 0)
    assert not writes(fake, before) and not audio_reads(fake, before), "the two copies agree: nothing moves"
    assert fake.calls[CID]["hash"] == copy["hash"]
    if server_audio:
        assert fake.audio[CID]["mic"]["data"] == tones[("mic", KEPT)]
    else:
        assert CID not in fake.audio


def test_text_only_copy_never_takes_untrimmed_tracks(fake, root, tones):
    d, copy = trimmed_elsewhere(fake, root, tones, server_audio="untrimmed")
    (d / "mic.m4a").unlink()
    (d / "system.m4a").unlink()
    assert remote.sync(root=root).downloaded == 1
    assert_server_text(d, copy)
    assert not (d / "mic.m4a").exists() and not (d / "system.m4a").exists(), "the old tracks never come down"
    before = len(fake.requests)
    remote.sync(root=root)
    assert not audio_reads(fake, before), "and are not downloaded again"


def test_busy_call_waits_for_next_sync(fake, root, tones):
    from sozvon_engine.pipeline import guard
    d, copy = trimmed_elsewhere(fake, root, tones, status="processing")
    assert tuple(remote.sync(root=root)) == (0, 0, 0, 0, 0)
    assert (d / "listen.m4a").exists() and "trimmed" not in call_json(d), "being transcribed: left alone"
    (d / "call.json").write_text(json.dumps({**call_json(d), "status": "done"}))
    fd = guard.lock_call(d)  # a run holds the call: the sync does not wait for it
    try:
        assert tuple(remote.sync(root=root)) == (0, 0, 0, 0, 0)
        assert (d / "listen.m4a").exists() and "trimmed" not in call_json(d)
    finally:
        os.close(fd)
    assert not writes(fake), "never uploaded meanwhile"
    assert remote.sync(root=root).downloaded == 1
    assert call_json(d)["trimmed"]["at"] == TRIM_AT


def test_failed_fetch_leaves_the_local_copy(fake, root, tones):
    d, copy = trimmed_elsewhere(fake, root, tones)
    fake.fail_ids[CID] = 500
    before = files_of(d)
    _, _, downloaded, _, failed = remote.sync(root=root)
    assert (downloaded, failed) == (0, 1)
    assert_still_untrimmed(d, before)
    assert not writes(fake)


def test_failed_audio_download_leaves_the_local_copy(fake, root, tones):
    d, copy = trimmed_elsewhere(fake, root, tones)
    fake.audio[CID]["mic"]["sha256"] = "0" * 64  # the download does not check out
    before = files_of(d)
    _, _, downloaded, _, failed = remote.sync(root=root)
    assert (downloaded, failed) == (0, 1)
    assert_still_untrimmed(d, before)
    assert not [p for p in d.iterdir() if p.name.startswith(".sync-")]


def test_failed_swap_keeps_the_staged_tracks(fake, root, tones, monkeypatch):
    d, copy = trimmed_elsewhere(fake, root, tones)
    real_replace = os.replace

    def flaky(src, dst):
        if Path(src).parent.name.startswith(".sync-") and Path(src).name == "system.m4a":
            raise OSError("disk went away")
        return real_replace(src, dst)
    monkeypatch.setattr(remote.os, "replace", flaky)
    _, _, downloaded, _, failed = remote.sync(root=root)
    assert (downloaded, failed) == (0, 1)
    (stage,) = [p for p in d.iterdir() if p.name.startswith(".sync-")]
    assert (stage / "system.m4a").read_bytes() == tones[("system", KEPT)], "the staged copy is kept"
    assert (d / "system.m4a").read_bytes() == tones[("system", 40.0)], "the track here is not deleted"
    assert "trimmed" not in call_json(d)


def test_stale_stage_folders_are_swept(fake, root, tones):
    d, copy = trimmed_elsewhere(fake, root, tones)
    old, fresh = d / ".sync-old", d / ".sync-fresh"
    for f in (old, fresh):
        f.mkdir()
        (f / "mic.m4a").write_bytes(b"x")
    os.utime(old, (1, 1))
    remote.sync(root=root)
    assert not old.exists() and fresh.exists()


def test_audio_uploads_carry_the_trim(fake, root):
    fake.version = "0.5.0"
    audio_call(root, trimmed={"at": TRIM_AT, "head": 3.0, "tail": 0})
    audio_call(root, "2026-11-04 16-00", seed=2)
    remote.sync(root=root)
    sent = {p.split("/")[3]: h for _, p, h in fake.trim_headers}
    assert sent == {urllib.parse.quote(CID): TRIM_AT, urllib.parse.quote("2026-11-04 16-00"): ""}
    assert {m for m, *_ in fake.trim_headers} == {"PUT", "POST"}, "chunks and commits"
    assert set(fake.audio) == {CID, "2026-11-04 16-00"}


def test_refused_audio_upload_is_skipped(fake, root):
    fake.version = "0.5.0"
    d, _ = audio_call(root)
    remote.sync(root=root)  # text and audio up, untrimmed
    (d / "mic.m4a").write_bytes(b"n" * 2500)  # changed here meanwhile
    fake.trims[CID] = TRIM_AT
    fake.hide_trims = True  # trimmed on another Mac after this one listed the calls
    before = dict(fake.audio[CID]["mic"])
    assert tuple(remote.sync(root=root)) == (0, 0, 0, 0, 0), "skipped, not a failure"
    assert fake.audio[CID]["mic"] == before


def test_trimmed_call_waiting_for_its_rerun_is_not_uploaded(fake, root):
    """A trim here leaves the old transcript (uncut timeline) until the rerun: neither it nor the cut tracks go up
    under the new trim time, or the other Mac would take stale text and the right upload would not win later."""
    fake.version = "0.5.0"
    queued, _ = audio_call(root, trimmed={"at": TRIM_AT, "head": 3.0, "tail": 0}, queued_at="2026-11-05T09:30:01Z")
    unrun, _ = audio_call(root, "2026-11-04 16-00", seed=2, trimmed={"at": TRIM_AT, "head": 3.0, "tail": 0})
    os.utime(unrun / "transcript.txt", (1, 1))  # written before the trim: the app quit before the rerun
    assert remote.payload(queued) is None and remote.payload(unrun) is None
    assert tuple(remote.sync(root=root)) == (0, 0, 0, 0, 0), "skipped, not failed"
    assert not fake.calls and not fake.audio and not fake.trim_headers
    # The rerun ends: a fresh transcript, no queue mark. Both go up, text and tracks.
    c = json.loads((queued / "call.json").read_text())
    c.pop("queued_at")
    (queued / "call.json").write_text(json.dumps(c))
    (unrun / "transcript.txt").write_text("[00:00] Я: Новый текст.\n", encoding="utf-8")
    assert remote.sync(root=root).sent == 2
    assert set(fake.calls) == set(fake.audio) == {CID, "2026-11-04 16-00"}
    assert fake.calls["2026-11-04 16-00"]["transcript"] == "[00:00] Я: Новый текст.\n"


def test_queued_untrimmed_call_waits_too(fake, root):
    fake.version = "0.5.0"
    d, _ = audio_call(root, queued_at="2026-11-05T09:30:01Z")
    assert remote.payload(d) is None
    assert tuple(remote.sync(root=root)) == (0, 0, 0, 0, 0)
    assert not fake.calls and not fake.audio
