"""Call audio on the own server: chunked upload, resume, 507, download on a new Mac, audio_removed_at, the switch."""
import json
import os

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
