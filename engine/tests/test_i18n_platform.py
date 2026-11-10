"""Texts that name an OS setting follow the platform; macOS keeps its own."""
from sozvon_engine import i18n, platform_support


def test_windows_names_its_own_settings(monkeypatch):
    monkeypatch.setattr(platform_support, "SYSTEM", "win32")
    monkeypatch.setenv("SOZVON_UI_LANG", "ru")
    assert "Параметрах Windows" in i18n.t("err_no_audio") and "Запись экрана" not in i18n.t("err_no_audio")
    monkeypatch.setenv("SOZVON_UI_LANG", "en")
    assert "Windows Settings" in i18n.t("err_no_audio") and "Screen" not in i18n.t("err_no_audio")


def test_macos_text_is_unchanged(monkeypatch):
    monkeypatch.setattr(platform_support, "SYSTEM", "darwin")
    monkeypatch.setenv("SOZVON_UI_LANG", "ru")
    assert i18n.t("err_no_audio") == i18n.MESSAGES["err_no_audio"][0]
    monkeypatch.setenv("SOZVON_UI_LANG", "en")
    assert i18n.t("err_no_audio") == i18n.MESSAGES["err_no_audio"][1]


def test_every_windows_text_has_a_mac_original():
    assert set(i18n.WINDOWS) <= set(i18n.MESSAGES)
