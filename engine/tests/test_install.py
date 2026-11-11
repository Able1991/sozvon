"""install.py: pinned model revisions, markers, diarization models (no network)."""
import hashlib
import re
import io
import tarfile
from pathlib import Path

import pytest

from sozvon_engine import install, models
from sozvon_engine.paths import EngineDir


class FakeHub:
    def __init__(self):
        self.calls = []

    def __call__(self, repo, filename, revision, local_dir):
        self.calls.append((repo, filename, revision))
        Path(local_dir, filename).write_text("weights")


def test_fresh_download_passes_pinned_revision(tmp_path):
    hub = FakeHub()
    d = install.ensure_model(tmp_path, "turbo", hub)
    m = models.MODELS["turbo"]
    v = models.VAD
    assert hub.calls == [(m["repo"], f, m["revision"]) for f in m["files"]] + [(v["repo"], f, v["revision"]) for f in v["files"]]
    assert (d / models.COMPLETE).read_text() == m["revision"] + "\n"
    install.ensure_model(tmp_path, "turbo", hub)
    assert len(hub.calls) == len(m["files"]) + len(v["files"]), "the second time downloads nothing"


def test_legacy_complete_files_marked_without_refetch(tmp_path):
    d = models.model_dir(tmp_path, "turbo")
    d.mkdir(parents=True)
    for f in models.MODELS["turbo"]["files"]:
        (d / f).write_text("x")
    hub = FakeHub()
    install.ensure_model(tmp_path, "turbo", hub)
    assert all(c[0] == models.VAD["repo"] for c in hub.calls), "the model itself is not fetched again"
    assert (d / models.COMPLETE).read_text() == "legacy\n"


def test_onnx_model_also_gets_vad(tmp_path):
    hub = FakeHub()
    install.ensure_model(tmp_path, "gigaam", hub)
    repos = [c[0] for c in hub.calls]
    assert repos[0] == models.MODELS["gigaam"]["repo"] and repos[-1] == models.VAD["repo"]
    assert models.is_downloaded(tmp_path, "gigaam")


def test_unknown_model(tmp_path):
    with pytest.raises(ValueError):
        install.ensure_model(tmp_path, "medium", FakeHub())


def tarball() -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        data = b"model"
        info = tarfile.TarInfo("hf-cache/models--pyannote--speaker-diarization-3.1/config.yaml")
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


class FakeFetch:
    def __init__(self, payloads: dict):
        self.payloads, self.urls = payloads, []

    def __call__(self, url, dest):
        self.urls.append(url)
        p = self.payloads.get(url)
        if p is None:
            raise OSError("network down")
        Path(dest).write_bytes(p)


def test_pyannote_bundled_first(tmp_path):
    good = tarball()
    eng = EngineDir(tmp_path)
    bundled = tmp_path / "bundle.tar.gz"
    bundled.write_bytes(good)
    sources = install.pyannote_sources(str(bundled), "https://net/p.tar.gz")
    assert sources == [bundled.resolve().as_uri(), "https://net/p.tar.gz"]
    fetch = FakeFetch({sources[0]: good})
    (tmp_path / ".no-diarization").touch()
    assert install.install_pyannote(eng, sources, hashlib.sha256(good).hexdigest(), fetch)
    assert fetch.urls == [sources[0]] and eng.pyannote_cache.is_dir() and not eng.no_diarization.exists()


def test_pyannote_sha_mismatch_falls_back_to_network(tmp_path):
    good = tarball()
    eng = EngineDir(tmp_path)
    fetch = FakeFetch({"file:///bundle": b"corrupt", "https://net": good})
    assert install.install_pyannote(eng, ["file:///bundle", "https://net"], hashlib.sha256(good).hexdigest(), fetch)
    assert fetch.urls == ["file:///bundle", "https://net"] and eng.pyannote_cache.is_dir()


def test_pyannote_failure_marks_no_diarization(tmp_path):
    eng = EngineDir(tmp_path)
    fetch = FakeFetch({"https://net": b"corrupt"})
    assert not install.install_pyannote(eng, ["file:///missing", "https://net"], "0" * 64, fetch)
    assert eng.no_diarization.exists() and not eng.pyannote_cache.exists()


def test_pyannote_already_installed_is_skipped(tmp_path):
    eng = EngineDir(tmp_path)
    eng.pyannote_cache.mkdir(parents=True)
    fetch = FakeFetch({})
    assert install.install_pyannote(eng, ["https://net"], "0" * 64, fetch) and fetch.urls == []


def test_main_installs_everything(tmp_path, monkeypatch, capsys):
    good = tarball()
    (tmp_path / "uv.lock").write_text("lock")
    (tmp_path / ".env").write_text("SOZVON_MODEL=small\n")
    monkeypatch.delenv("SOZVON_PYANNOTE_TAR", raising=False)
    monkeypatch.setenv("SOZVON_PYANNOTE_URL", "https://net")
    monkeypatch.setenv("SOZVON_PYANNOTE_SHA", hashlib.sha256(good).hexdigest())
    hub = FakeHub()
    assert install.main([str(tmp_path)], downloader=hub, fetch=FakeFetch({"https://net": good})) == 0
    assert {c[0] for c in hub.calls} == {models.MODELS["small"]["repo"], models.VAD["repo"], models.MANIFEST["aec"]["repo"]}
    assert (tmp_path / ".venv-lock").read_text().strip() == hashlib.sha256(b"lock").hexdigest()[:16]
    assert (tmp_path / ".installed").read_text().strip().isdigit()
    out = capsys.readouterr().out.splitlines()
    assert out[0] == "==> Скачиваю модель small (один раз)" and out[-1] == "==> Готово"


def echo_entry(monkeypatch, good=b"weights"):
    entry = {"repo": "r", "revision": "rev", "dir": "aec", "files": ["w.pt"], "sha256": hashlib.sha256(good).hexdigest()}
    monkeypatch.setitem(models.MANIFEST, "aec", entry)
    return entry


class EchoHub:
    """Writes `bodies` one per call, the last one for every call after that."""

    def __init__(self, *bodies):
        self.bodies = list(bodies)
        self.calls = []

    def __call__(self, repo, filename, revision, local_dir):
        body = self.bodies.pop(0) if len(self.bodies) > 1 else self.bodies[0]
        self.calls.append((repo, filename, revision, local_dir))
        Path(local_dir, filename).write_bytes(body)


def test_echo_model_clean_install_fetches_only_the_one_file(tmp_path, monkeypatch):
    entry = echo_entry(monkeypatch)
    hub = EchoHub(b"weights")
    install.ensure_echo_model(tmp_path, hub)
    assert hub.calls == [(entry["repo"], "w.pt", "rev", tmp_path / "models" / "aec")]
    assert (tmp_path / "models" / "aec" / models.COMPLETE).exists()


def test_echo_model_already_intact_is_not_fetched_again(tmp_path, monkeypatch):
    echo_entry(monkeypatch)
    install.ensure_echo_model(tmp_path, EchoHub(b"weights"))
    hub = EchoHub(b"weights")
    install.ensure_echo_model(tmp_path, hub)
    assert hub.calls == []


def test_a_corrupted_echo_model_is_downloaded_again(tmp_path, monkeypatch):
    echo_entry(monkeypatch)
    install.ensure_echo_model(tmp_path, EchoHub(b"weights"))
    d = tmp_path / "models" / "aec"
    (d / "w.pt").write_bytes(b"flipped bits")
    hub = EchoHub(b"weights")
    install.ensure_echo_model(tmp_path, hub)
    assert len(hub.calls) == 1
    assert (d / "w.pt").read_bytes() == b"weights" and (d / models.COMPLETE).exists()


def test_a_legacy_marker_on_a_bad_file_is_repaired(tmp_path, monkeypatch):
    echo_entry(monkeypatch)
    d = tmp_path / "models" / "aec"
    d.mkdir(parents=True)
    (d / "w.pt").write_bytes(b"from an interrupted copy")
    hub = EchoHub(b"weights")
    install.ensure_echo_model(tmp_path, hub)
    assert len(hub.calls) == 1 and (d / "w.pt").read_bytes() == b"weights"


def test_the_shipped_echo_model_is_v12_in_its_own_folder():
    entry = models.MANIFEST["aec"]
    assert entry["dir"] == "localvqe-v1.2", "the folder name must never match an old v1.3 download"
    assert entry["files"] == ["localvqe-v1.2-1.3M.pt"]
    assert entry["sha256"] == "ff6885e7c8d7d29a8ce963303dcd668ae0f2a7bdafae28631292fe6f06f7cd77"
    assert re.fullmatch(r"[0-9a-f]{40}", entry["revision"]), "a pinned commit, not a branch"


def old_folder(root) -> Path:
    d = Path(root) / "models" / "localvqe-v1.3"
    d.mkdir(parents=True)
    (d / "localvqe-v1.3-4.8M.pt").write_bytes(b"v" * 100)
    (d / models.COMPLETE).write_text("done")
    return d


def test_a_previous_echo_model_folder_is_removed_on_install(tmp_path, monkeypatch):
    entry = echo_entry(monkeypatch)
    old = old_folder(tmp_path)
    keep = tmp_path / "models" / "gigaam-v3-onnx"
    keep.mkdir()
    (keep / "w").write_bytes(b"x")
    install.ensure_echo_model(tmp_path, EchoHub(b"weights"))
    assert not old.exists(), "54 MB nobody reads any more"
    assert (keep / "w").exists(), "other models are not touched"
    assert (tmp_path / "models" / entry["dir"] / models.COMPLETE).exists()


def test_a_previous_echo_model_folder_is_removed_even_when_nothing_is_fetched(tmp_path, monkeypatch):
    echo_entry(monkeypatch)
    install.ensure_echo_model(tmp_path, EchoHub(b"weights"))
    old = old_folder(tmp_path)
    hub = EchoHub(b"weights")
    install.ensure_echo_model(tmp_path, hub)
    assert hub.calls == []
    assert not old.exists()


def test_a_failed_download_still_clears_the_previous_folder(tmp_path, monkeypatch):
    echo_entry(monkeypatch)
    old = old_folder(tmp_path)
    def boom(*a):
        raise OSError("no network")
    install.ensure_echo_model(tmp_path, boom)
    assert not old.exists(), "the engine reads only the current folder, the old one is dead weight either way"


def test_the_current_folder_is_never_cleared_as_previous(tmp_path, monkeypatch):
    """Should the manifest ever point back at the old name, its download stays."""
    entry = {"repo": "r", "revision": "rev", "dir": "localvqe-v1.3", "files": ["w.pt"], "sha256": hashlib.sha256(b"weights").hexdigest()}
    monkeypatch.setitem(models.MANIFEST, "aec", entry)
    install.ensure_echo_model(tmp_path, EchoHub(b"weights"))
    hub = EchoHub(b"weights")
    install.ensure_echo_model(tmp_path, hub)
    assert hub.calls == [], "the good copy was not thrown away"
    assert (tmp_path / "models" / "localvqe-v1.3" / "w.pt").read_bytes() == b"weights"


def test_a_repeated_bad_download_stops_after_one_retry(tmp_path, monkeypatch, capsys):
    echo_entry(monkeypatch)
    hub = EchoHub(b"garbage")
    install.ensure_echo_model(tmp_path, hub)
    d = tmp_path / "models" / "aec"
    assert len(hub.calls) == 2, "one retry, no loop"
    assert not (d / models.COMPLETE).exists(), "no .complete: the next launch tries again"
    assert not (d / "w.pt").exists()
    assert (tmp_path / ".no-echo-model").exists(), "reported to the first call that runs without the model"
    assert capsys.readouterr().out.strip() != ""


def test_a_failed_download_leaves_the_marker_and_success_clears_it(tmp_path, monkeypatch):
    echo_entry(monkeypatch)
    def boom(*a):
        raise OSError("no network")
    install.ensure_echo_model(tmp_path, boom)
    assert (tmp_path / ".no-echo-model").exists()
    install.ensure_echo_model(tmp_path, EchoHub(b"weights"))
    assert not (tmp_path / ".no-echo-model").exists()


def test_echo_model_failure_does_not_stop_the_install(tmp_path, capsys):
    def boom(*a):
        raise OSError("no network")
    install.ensure_echo_model(tmp_path, boom)
    assert "no network" in capsys.readouterr().out
