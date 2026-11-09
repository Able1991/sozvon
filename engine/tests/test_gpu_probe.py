"""Which torch build goes with which card, and what the check of the GPU step leaves behind."""
import json
import sys
from types import SimpleNamespace

import pytest

from sozvon_engine import gpu_probe as gp

TABLE = gp.load_table()


def nvidia(cap):
    return {"vendor": "nvidia", "name": "Card", "compute_cap": cap, "driver": "1", "vram_mb": "8192"}


@pytest.mark.parametrize("cap,expected", [("6.1", "cu126"), ("8.6", "cu126"), ("9.0", "cu126"), ("12.0", "cu130")])
def test_nvidia_generation_picks_the_build(cap, expected):
    assert gp.select([nvidia(cap)], TABLE)[0]["id"] == expected


def test_a_card_older_than_any_build_stays_on_the_cpu():
    assert gp.select([nvidia("4.0")], TABLE) == (None, None)


def test_a_cap_that_cannot_be_read_stays_on_the_cpu():
    assert gp.select([nvidia("N/A")], TABLE) == (None, None)


def test_amd_only_with_the_experimental_flag():
    rx = {"vendor": "amd", "name": "AMD Radeon RX 7800 XT"}
    assert gp.select([rx], TABLE) == (None, None)
    assert gp.select([rx], TABLE, experimental=True)[0]["id"] == "rocm721"


def test_old_radeon_and_intel_stay_on_the_cpu():
    assert gp.select([{"vendor": "amd", "name": "AMD Radeon RX 580"}, {"vendor": "other", "name": "Intel(R) UHD Graphics 630"}], TABLE, True) == (None, None)


def test_nvidia_wins_over_the_integrated_card():
    adapters = [{"vendor": "other", "name": "Intel(R) UHD Graphics 630"}, nvidia("6.1")]
    assert gp.select(adapters, TABLE)[1]["vendor"] == "nvidia"


def test_only_what_ran_on_a_card_counts_as_tested():
    backend = next(b for b in TABLE if b["id"] == "cu126")
    assert gp.is_tested(backend, nvidia("6.1")) is True
    assert gp.is_tested(backend, nvidia("8.6")) is False


def test_table_entries_with_requirements_have_their_files():
    for b in TABLE:
        if b.get("requirements"):
            text = (gp.TABLE.parent / b["requirements"]).read_text(encoding="utf-8")
            assert "--hash=sha256:" in text and b["index"].startswith("https://download.pytorch.org/whl/")


def child(code):
    return [sys.executable, "-c", code]


def state(data):
    return json.loads((data / ".gpu.json").read_text(encoding="utf-8"))


def test_a_good_check_is_written(data):
    result = gp.verify("cu126", child('print(\'{"ok": true, "device": "cuda", "torch": "2.14"}\')'))
    assert result["ok"] is True
    saved = state(data)
    assert saved["backend"] == "cu126" and saved["device"] == "cuda" and saved["ok"] is True and saved["probed_at"]


def test_a_crashing_check_is_a_failed_gpu(data):
    assert gp.verify("cu126", child("import sys; sys.exit(3)"))["ok"] is False
    assert state(data)["ok"] is False


def test_garbage_from_the_check_is_a_failed_gpu(data):
    assert gp.verify("cu126", child("print('not json')"))["ok"] is False


def test_a_hanging_check_is_cut_off(data, monkeypatch):
    monkeypatch.setattr(gp, "TIMEOUT", 1)
    result = gp.verify("cu126", child("import time; time.sleep(30)"))
    assert result["ok"] is False and "1 s" in result["reason"]
    assert state(data)["ok"] is False


def test_a_library_that_does_not_import_is_a_failed_gpu(data):
    """After torch is swapped, a broken pyannote or faster-whisper must end the GPU step, not a later transcription."""
    result = gp.verify("cu126", child("import a_module_that_is_not_there"))
    assert result["ok"] is False and "a_module_that_is_not_there" in result["reason"]


class FakeTensor:
    def to(self, device):
        return self

    def __matmul__(self, other):
        return self

    def sum(self):
        return self

    def item(self):
        return 1.0


@pytest.mark.parametrize("missing", ["faster_whisper", "pyannote.audio"])
def test_the_check_fails_when_a_library_does_not_import_with_this_torch(monkeypatch, missing):
    fake_torch = SimpleNamespace(cuda=SimpleNamespace(is_available=lambda: True), manual_seed=lambda s: None,
                                 rand=lambda *a: FakeTensor())
    monkeypatch.setitem(sys.modules, "torch", fake_torch)
    monkeypatch.setitem(sys.modules, "ctranslate2", SimpleNamespace())
    monkeypatch.setitem(sys.modules, "faster_whisper", SimpleNamespace())
    monkeypatch.setitem(sys.modules, missing, None)  # Python raises ImportError for it
    with pytest.raises(ImportError):
        gp.check()


def test_fail_records_the_reason(data):
    assert gp.main(["fail", "cu126", "no", "disk"]) == 0
    saved = state(data)
    assert saved["ok"] is False and saved["reason"] == "no disk"
