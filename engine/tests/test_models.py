"""Model manifest: a single source of truth for the installer, engine and app."""
import re
from pathlib import Path

import pytest

from sozvon_engine import models

ROOT = Path(__file__).resolve().parent.parent.parent


def test_manifest_shape():
    assert models.MANIFEST["schema"] == 1
    assert models.DEFAULT_MODEL in models.MODELS and "medium" not in models.MODELS
    for name, m in models.MODELS.items():
        assert m["kind"] in ("whisper", "onnx"), name
        assert re.fullmatch(r"[0-9a-f]{40}", m["revision"]), f"{name}: the revision must be pinned"
        assert m["files"] and m["dir"] and m["repo"]
    assert re.fullmatch(r"[0-9a-f]{40}", models.VAD["revision"])


def test_swift_enum_matches_manifest():
    """WhisperModel in the app and the manifest must not drift apart (folders and names)."""
    for f in sorted((ROOT / "Sources").rglob("*.swift")):
        swift = f.read_text(encoding="utf-8")
        if "enum WhisperModel" in swift:
            break
    else:
        pytest.skip("WhisperModel enum not found in the app")
    enum = swift[swift.index("enum WhisperModel"):]
    enum = enum[:enum.index("\n}\n")]
    for name, m in models.MODELS.items():
        assert f'"{m["dir"]}"' in enum, f"folder {m['dir']} of model {name} does not match the app"


def test_complete_marker_and_legacy(tmp_path):
    d = models.model_dir(tmp_path, "turbo")
    assert not models.is_downloaded(tmp_path, "turbo")
    d.mkdir(parents=True)
    for f in models.MODELS["turbo"]["files"]:
        (d / f).write_text("x")
    assert models.is_downloaded(tmp_path, "turbo"), "old installs without the .complete marker"
    (d / models.MODELS["turbo"]["files"][-1]).write_text("")  # the weights, whatever the platform names them
    assert not models.is_downloaded(tmp_path, "turbo"), "an empty file means an interrupted download"


def test_local_whisper_only_known_downloaded_whisper(tmp_path):
    from conftest import fake_model
    assert models.local_whisper(tmp_path, "medium") is None
    assert models.local_whisper(tmp_path, "gigaam") is None
    assert models.local_whisper(tmp_path, "turbo") is None, "not downloaded: no network request"
    d = fake_model(tmp_path, "turbo")
    assert models.local_whisper(tmp_path, "turbo") == str(d)
