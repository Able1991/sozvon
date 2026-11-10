"""Corporate networks: the system certificate store, and network keys from .env (docs/CORPORATE.md)."""
import os
import platform
import shutil
import subprocess
import sys
import types
from pathlib import Path

import pytest

from sozvon_engine import runtime

ENGINE = Path(__file__).resolve().parent.parent
NETWORK_KEYS = ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "HF_ENDPOINT", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY",
                "UV_DEFAULT_INDEX", "UV_PYTHON", "UV_PYTHON_INSTALL_MIRROR", "PIP_INDEX_URL",
                "SOZVON_SYSTEM_CERTS", "HF_HUB_OFFLINE")


@pytest.fixture(autouse=True)
def clean_network_env(monkeypatch):
    for k in NETWORK_KEYS:
        monkeypatch.delenv(k, raising=False)


@pytest.fixture
def fake_truststore(monkeypatch):
    calls = []
    mod = types.ModuleType("truststore")
    mod.inject_into_ssl = lambda: calls.append("inject")
    monkeypatch.setitem(sys.modules, "truststore", mod)
    return calls


def test_engine_trusts_the_system_certificate_store(fake_truststore):
    runtime.prepare()
    assert fake_truststore == ["inject"]


def test_system_store_can_be_turned_off(fake_truststore, monkeypatch):
    monkeypatch.setenv("SOZVON_SYSTEM_CERTS", "0")
    runtime.prepare()
    assert fake_truststore == []


def test_an_explicit_certificate_file_wins_over_the_system_store(fake_truststore, monkeypatch, tmp_path):
    monkeypatch.setenv("SSL_CERT_FILE", str(tmp_path / "corp.pem"))
    runtime.prepare()
    assert fake_truststore == []


def test_missing_truststore_does_not_break_the_engine(monkeypatch):
    monkeypatch.setitem(sys.modules, "truststore", None)
    runtime.prepare()


def test_network_keys_from_env_file_reach_the_process(data, fake_truststore):
    (data / ".env").write_text("HF_ENDPOINT=https://hf.corp.example\nHTTPS_PROXY=http://proxy:3128\n"
                               "HF_TOKEN=secret\n")
    runtime.prepare()
    assert os.environ["HF_ENDPOINT"] == "https://hf.corp.example"
    assert os.environ["HTTPS_PROXY"] == "http://proxy:3128"
    assert "HF_TOKEN" not in os.environ


def test_process_environment_overrides_env_file(data, fake_truststore, monkeypatch):
    monkeypatch.setenv("HF_ENDPOINT", "https://from-env")
    (data / ".env").write_text("HF_ENDPOINT=https://from-file\n")
    runtime.prepare()
    assert os.environ["HF_ENDPOINT"] == "https://from-env"


def test_certificate_file_from_env_file_also_skips_the_system_store(data, fake_truststore):
    (data / ".env").write_text("SSL_CERT_FILE=/etc/corp.pem\n")
    runtime.prepare()
    assert os.environ["REQUESTS_CA_BUNDLE"] == "/etc/corp.pem"
    assert fake_truststore == []


# setup.sh with a fake uv that records how it was called.

FAKE_UV = """#!/bin/bash
{ echo "ARGS $*"; echo "ENV UV_SYSTEM_CERTS=${UV_SYSTEM_CERTS:-} UV_NATIVE_TLS=${UV_NATIVE_TLS:-} \
UV_PYTHON=${UV_PYTHON:-} HF_TOKEN=${HF_TOKEN:-}"; } >> "$UV_LOG"
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then echo "x==1 --hash=sha256:00" > "$a"; fi
  prev="$a"
done
exit 0
"""

arm_mac = pytest.mark.skipif(sys.platform != "darwin" or platform.machine() != "arm64",
                             reason="setup.sh runs on Apple silicon only")


def run_setup(tmp_path, env_file="", pip_conf=None, extra_env=None):
    home = tmp_path / "home"
    (home / ".local/bin").mkdir(parents=True)
    uv = home / ".local/bin/uv"
    uv.write_text(FAKE_UV)
    uv.chmod(0o755)
    data = tmp_path / "engine-data"
    data.mkdir()
    shutil.copy(ENGINE / "setup.sh", data / "setup.sh")
    (data / ".env").write_text(env_file)
    if pip_conf is not None:
        (home / ".config/pip").mkdir(parents=True)
        (home / ".config/pip/pip.conf").write_text(pip_conf)
    log = tmp_path / "uv.log"
    env = {"HOME": str(home), "UV_LOG": str(log), "SOZVON_UI_LANG": "en", "PATH": "/usr/bin:/bin"}
    env.update(extra_env or {})
    # The fake uv makes no .venv, so the script stops at ffmpeg; only the uv calls matter here.
    subprocess.run(["/bin/bash", str(data / "setup.sh"), str(data)], env=env, capture_output=True, timeout=60)
    return log.read_text() if log.exists() else ""


@arm_mac
def test_setup_lets_uv_trust_the_system_certificates(tmp_path):
    log = run_setup(tmp_path)
    assert "ARGS sync --frozen --no-dev" in log
    assert "UV_SYSTEM_CERTS=1 UV_NATIVE_TLS=1" in log


@arm_mac
def test_setup_installs_through_a_package_mirror_from_env_file(tmp_path):
    log = run_setup(tmp_path, "UV_DEFAULT_INDEX=https://mirror.corp/simple\nHF_TOKEN=secret\n")
    assert "sync --frozen" not in log
    assert "ARGS export --frozen --no-dev" in log
    assert "--index-url https://mirror.corp/simple" in log
    assert "HF_TOKEN=secret" not in log


@arm_mac
def test_setup_takes_the_mirror_from_pip_conf(tmp_path):
    log = run_setup(tmp_path, pip_conf="[global]\nindex-url = https://nexus.corp/pypi/simple\n")
    assert "--index-url https://nexus.corp/pypi/simple" in log


@arm_mac
def test_setup_passes_an_own_python(tmp_path):
    log = run_setup(tmp_path, "UV_PYTHON=/opt/corp/python3.12\n")
    assert "UV_PYTHON=/opt/corp/python3.12" in log
