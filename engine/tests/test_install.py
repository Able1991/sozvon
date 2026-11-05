"""install.py: модели закреплённых ревизий, метки, модели разбивки по голосам (без сети)."""
import hashlib
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
    assert hub.calls == [(m["repo"], f, m["revision"]) for f in m["files"]]
    assert (d / models.COMPLETE).read_text() == m["revision"] + "\n"
    install.ensure_model(tmp_path, "turbo", hub)
    assert len(hub.calls) == len(m["files"]), "второй раз не качает"


def test_legacy_complete_files_marked_without_refetch(tmp_path):
    d = models.model_dir(tmp_path, "turbo")
    d.mkdir(parents=True)
    for f in models.MODELS["turbo"]["files"]:
        (d / f).write_text("x")
    hub = FakeHub()
    install.ensure_model(tmp_path, "turbo", hub)
    assert hub.calls == [] and (d / models.COMPLETE).read_text() == "legacy\n"


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
    assert {c[0] for c in hub.calls} == {models.MODELS["small"]["repo"]}
    assert (tmp_path / ".venv-lock").read_text().strip() == hashlib.sha256(b"lock").hexdigest()[:16]
    assert (tmp_path / ".installed").read_text().strip().isdigit()
    out = capsys.readouterr().out.splitlines()
    assert out[0] == "==> Скачиваю модель small (один раз)" and out[-1] == "==> Готово"
