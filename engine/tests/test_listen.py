"""listen.m4a: the gently levelled listening file (pipeline/listen.py). Behaviour on real audio arrays and files."""
import json
import os
import re
import signal
import subprocess
import threading
import time
import sys
import tracemalloc
import wave
from pathlib import Path

import numpy as np
import pytest
from scipy.ndimage import gaussian_filter1d, minimum_filter1d

from sozvon_engine import audio
from sozvon_engine.pipeline import listen, tracks, run

SR = 16000
RATE = 48000
ENCODER_WATCHDOG = 60  # seconds: longer than any render here, short enough that a stuck encoder fails instead of hanging


@pytest.fixture(autouse=True)
def encoder_watchdog(monkeypatch):
    """An encoder left waiting on its stdin would hang the whole test run: kill it after a while and fail the test."""
    stuck, timers = [], []
    popen = subprocess.Popen

    def watched(args, **kw):
        proc = popen(args, **kw)
        if kw.get("stdin") == subprocess.PIPE:
            def kill():
                stuck.append(args)
                proc.kill()
            timers.append(threading.Timer(ENCODER_WATCHDOG, kill))
            timers[-1].daemon = True
            timers[-1].start()
        return proc
    monkeypatch.setattr(listen.subprocess, "Popen", watched)
    yield
    for timer in timers:
        timer.cancel()
    assert not stuck, "the encoder was left running after the render"


def noise(sec: float, dbfs: float, rng=None, sr: int = SR) -> np.ndarray:
    """Uniform noise of a given RMS level (uniform: peaks stay near 1.7x the RMS, the limiter stays out of it)."""
    rng = rng or np.random.default_rng(1)
    amp = 10 ** (dbfs / 20) * np.sqrt(3)
    return rng.uniform(-amp, amp, int(sec * sr))


def db(x: np.ndarray) -> float:
    return float(10 * np.log10(max(np.mean(np.square(x)), 1e-12)))


def write_wav(path: Path, x: np.ndarray, sr: int = SR) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())
    return path


def pcm(wav: Path, source: Path | None = None, delay: float = 0.0, boost: float = 1.0) -> np.ndarray:
    """One track levelled to 48 kHz: analysis from `wav`, audio from `source` (default: the same file)."""
    return np.concatenate(list(listen.track_pcm(wav, source or wav, delay, boost)))


def tone(hz: float, n: int, sr: int, amp: float = 0.1) -> np.ndarray:
    return np.float32(amp * np.sin(2 * np.pi * hz * np.arange(n) / sr))


def peak_in_band(y: np.ndarray, low: float, high: float) -> float:
    """The largest spectrum value of one second of the mix (from 1 s on) between two frequencies."""
    s = np.abs(np.fft.rfft(y[RATE:2 * RATE]))
    freqs = np.fft.rfftfreq(RATE, 1 / RATE)
    return float(s[(freqs > low) & (freqs < high)].max())


def seg(y: np.ndarray, a: float, b: float) -> np.ndarray:
    return y[int(a * RATE):int(b * RATE)]


def seg16(x: np.ndarray, a: float, b: float) -> np.ndarray:
    return x[int(a * SR):int(b * SR)]


def call(tmp_path: Path, sys_x=None, mic_x=None, sys_sr: int = RATE, offsets=None, mic_sr: int = SR):
    """A call folder with a .work: mic track at mic_sr, system track at sys_sr (wavs named .m4a: ffmpeg reads the content),
    the 16 kHz working wavs made by the engine's own to_wav. -> (d, files, offsets, tracks)."""
    d = tmp_path / "call"
    work = d / tracks.WORK
    work.mkdir(parents=True)
    offsets = offsets or {}
    files, out = {}, {}
    if sys_x is not None:
        f = write_wav(d / "system.m4a", sys_x, sys_sr)
        files["system"] = f
        out["system"] = audio.to_wav(f, work / "system.wav", offsets.get("system", 0.0))
    if mic_x is not None:
        f = write_wav(d / "mic.m4a", mic_x, mic_sr)
        files["mic"] = f
        out["mic"] = audio.to_wav(f, work / "mic.wav", offsets.get("mic", 0.0))
    return d, files, offsets, out


def lines() -> tuple[list, callable]:
    logged: list = []
    return logged, logged.append


# --- loud parts down, quiet parts up by the cap, pauses left alone ---

def test_loud_stretch_is_pulled_down_toward_the_target(tmp_path):
    """-6 dBFS speech: 14 dB over -20, 0.85 of it is 11.9 dB. Catches a wrong strength (down=0.85) or a dropped gain."""
    x = np.concatenate([noise(3, -60), noise(6, -6), noise(3, -60)])
    y = pcm(write_wav(tmp_path / "w.wav", x))
    change = db(seg(y, 4.5, 8.0)) - db(seg16(x, 4.5, 8.0))
    assert change == pytest.approx(-14 * 0.85, abs=1.0)


def test_quiet_speech_is_raised_gently(tmp_path):
    """-35 dBFS speech: 15 dB under the target, raised 0.35 of it = 5.25 dB. Catches up strength."""
    x = np.concatenate([noise(3, -70), noise(6, -35), noise(3, -70)])
    y = pcm(write_wav(tmp_path / "w.wav", x))
    change = db(seg(y, 4.5, 8.0)) - db(seg16(x, 4.5, 8.0))
    assert change == pytest.approx(15 * 0.35, abs=0.7)


def test_quiet_speech_is_raised_at_most_by_the_cap(tmp_path):
    """Very quiet speech: 22 dB under the target would be 7.7 dB, the cap stops it at 6 dB. Catches a missing max_up."""
    x = np.concatenate([noise(3, -75), noise(6, -42), noise(3, -75)])
    y = pcm(write_wav(tmp_path / "w.wav", x))
    change = db(seg(y, 4.5, 8.0)) - db(seg16(x, 4.5, 8.0))
    assert 5.0 < change < 6.3


def test_pauses_are_never_raised(tmp_path):
    """Hiss in a pause must not come up, between speech that is raised. Catches pause gain not clamped to 0 dB."""
    x = np.concatenate([noise(4, -33), noise(4, -68), noise(4, -33)])
    y = pcm(write_wav(tmp_path / "w.wav", x))
    speech = db(seg(y, 1.0, 3.0)) - db(seg16(x, 1.0, 3.0))
    pause = db(seg(y, 5.0, 7.0)) - db(seg16(x, 5.0, 7.0))
    assert speech > 3.5, "this speech is raised"
    assert pause <= 0.3, f"pause raised by {pause:.2f} dB"


def test_gain_drops_before_a_loud_part_arrives(tmp_path):
    """The gain reacts ahead of a loud onset. Catches removing the look-ahead minimum filter."""
    rng = np.random.default_rng(5)
    x = np.concatenate([noise(4, -70, rng), noise(4, -30, rng), noise(4, -3, rng), noise(2, -30, rng), noise(4, -70, rng)])
    y = pcm(write_wav(tmp_path / "w.wav", x))
    # 20 ms just before the loud part, compared with the same quiet speech well before it
    before_onset = db(seg(y, 7.96, 7.99)) - db(seg16(x, 7.96, 7.99))
    calm = db(seg(y, 5.0, 7.0)) - db(seg16(x, 5.0, 7.0))
    assert before_onset < calm - 3.0


def test_digital_silence_is_not_raised(tmp_path):
    """An all-zero track: nothing to level, and no noise or error comes from it."""
    x = np.zeros(SR * 3)
    y = pcm(write_wav(tmp_path / "w.wav", x))
    assert np.abs(y).max() == 0


# --- the limiter ---

def test_limiter_holds_the_ceiling():
    """A full-scale tone: nothing above -1.5 dBFS, also where the need curve is smoothed. Catches a window narrower than the smoothing."""
    t = np.arange(RATE * 2) / RATE
    y = np.float32(0.99 * np.sin(2 * np.pi * 330 * t))
    out = np.concatenate(list(listen.limited(iter([y[:RATE], y[RATE:]]))))
    assert len(out) == len(y)
    assert np.abs(out).max() <= 10 ** (-1.5 / 20) + 1e-6


def test_limiter_holds_a_single_peak():
    """One sample at full scale in quiet audio: smoothing wider than the look-around window would let it through."""
    y = np.full(RATE, 0.01, dtype=np.float32)
    y[RATE // 2] = 0.99
    out = np.concatenate(list(listen.limited(iter([y]))))
    assert np.abs(out).max() <= 10 ** (-1.5 / 20) + 1e-6


def test_limiter_leaves_quiet_audio_alone():
    y = np.float32(np.sin(2 * np.pi * 220 * np.arange(RATE) / RATE) * 0.2)
    out = np.concatenate(list(listen.limited(iter([y]))))
    assert np.allclose(out, y, atol=1e-5)


def test_mix_is_limited(tmp_path):
    """Two loud voices added together: the mix limiter holds, and both tracks are in it. Catches the sum left unlimited or a dropped track."""
    t = np.arange(RATE * 2) / RATE
    tone = np.float32(0.6 * np.sin(2 * np.pi * 440 * t))
    out = np.concatenate(list(listen.mix_chunks([iter([tone]), iter([tone])])))
    assert 0.75 < np.abs(out).max() <= 10 ** (-1.5 / 20) + 1e-6


# --- the system track: full band, aligned ---

@pytest.mark.parametrize("delay,expected", [(0.5, 24000), (0.0374, 1776), (0.005, 0)])
def test_system_audio_is_aligned_to_the_sample(tmp_path, delay, expected):
    """An impulse at sample 12345 of a 48 kHz system.m4a lands exactly where the working wav's delay (integer ms) puts it.
    Catches a delay computed differently from to_wav, or a delay under the 10 ms threshold applied."""
    x = np.zeros(RATE * 4, dtype=np.float32)
    x[12345] = 0.5
    d, files, offsets, tr = call(tmp_path, sys_x=x, offsets={"system": delay})
    y = np.concatenate(list(listen.mix_pcm(files, offsets, tr, {})))
    assert int(np.argmax(np.abs(y))) == 12345 + expected


def test_stereo_system_is_as_loud_as_its_working_wav(tmp_path):
    """A stereo system.m4a at the -20 dBFS target: no gain, so the mix is at -20 like the working wav. ffmpeg downmixes
    to float without normalizing, +3 dB over the wav the gain was measured on. Catches decoding to float."""
    d = tmp_path / "call"
    (d / tracks.WORK).mkdir(parents=True)
    tone = np.sqrt(2) * 10 ** (-20 / 20) * np.sin(2 * np.pi * 1000 * np.arange(RATE * 8) / RATE)  # in the 16 kHz band
    x = np.concatenate([noise(3, -75, sr=RATE), tone, noise(3, -75, sr=RATE)])
    src = d / "system.m4a"
    with wave.open(str(src), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((np.stack([x, x], axis=1) * 32767).astype("<i2").tobytes())
    wav = audio.to_wav(src, d / tracks.WORK / "system.wav")
    y = np.concatenate(list(listen.mix_pcm({"system": src}, {}, {"system": wav}, {})))
    assert db(seg16(audio.decode(wav), 5, 9)) == pytest.approx(-20, abs=0.5), "the working wav is the reference"
    assert db(seg(y, 5, 9)) == pytest.approx(-20, abs=0.5)


def test_full_band_of_the_system_track_is_kept(tmp_path):
    """A 10 kHz tone in system.m4a survives (a 16 kHz listening file could not carry it)."""
    t = np.arange(RATE * 3) / RATE
    x = np.float32(0.1 * np.sin(2 * np.pi * 10000 * t))
    d, files, offsets, tr = call(tmp_path, sys_x=x)
    y = np.concatenate(list(listen.mix_pcm(files, offsets, tr, {})))
    s = np.abs(np.fft.rfft(y[RATE:2 * RATE]))
    freqs = np.fft.rfftfreq(RATE, 1 / RATE)
    assert s[(freqs > 9800) & (freqs < 10200)].max() > 50 * s[(freqs > 1000) & (freqs < 8000)].max()


# --- the mic track: full band unless echo was removed, aligned either way ---

@pytest.mark.parametrize("gains", [{}, {"mic": 1.0, "mic_echo_free": False}])
def test_mic_keeps_its_full_band_when_no_echo_was_removed(tmp_path, gains):
    """An 11 kHz tone in mic.m4a survives on a call with no echo removal, also when a boost alone left a mic.clean.m4a.
    Catches the mic always taken from the 16 kHz working wav, and the flag inferred from mic.clean.m4a existing."""
    d, files, offsets, tr = call(tmp_path, mic_x=tone(11000, RATE * 3, RATE), mic_sr=RATE)
    (d / tracks.CLEAN_MIC).write_bytes(b"raised only" * 200)
    y = np.concatenate(list(listen.mix_pcm(files, offsets, tr, gains)))
    assert peak_in_band(y, 10800, 11200) > 50 * peak_in_band(y, 1000, 8000)


def test_echo_removed_mic_is_the_cleaned_audio(tmp_path):
    """Echo was removed: the mic is the cleaned 16 kHz wav, never the original (which still holds the echo).
    Original: an 11 kHz tone. Cleaned: 1 kHz. Catches the original mic used on an echo-removed call."""
    d, files, offsets, tr = call(tmp_path, mic_x=tone(11000, RATE * 3, RATE), mic_sr=RATE)
    write_wav(tr["mic"], tone(1000, SR * 3, SR))
    y = np.concatenate(list(listen.mix_pcm(files, offsets, tr, {"mic": 1.0, "mic_echo_free": True})))
    assert peak_in_band(y, 900, 1100) > 50 * peak_in_band(y, 10800, 11200)
    assert db(seg(y, 1, 2)) == pytest.approx(db(tone(1000, SR * 3, SR)), abs=1.0)


@pytest.mark.parametrize("echo_free", [False, True])
@pytest.mark.parametrize("delay,expected", [(0.5, 24000), (0.0374, 1776), (0.005, 0)])
def test_mic_is_aligned_to_the_sample(tmp_path, delay, expected, echo_free):
    """An impulse at sample 12345 of a 48 kHz mic.m4a (a multiple of 3, so it is a sample of the 16 kHz wav too) lands where
    the working wav's delay puts it, on either path. Catches the delay left out of the original mic and the mic delayed
    twice (the cleaned working wav already carries its delay)."""
    x = np.zeros(RATE * 4, dtype=np.float32)
    x[12345] = 0.5
    d, files, offsets, tr = call(tmp_path, mic_x=x, mic_sr=RATE, offsets={"mic": delay})
    y = np.concatenate(list(listen.mix_pcm(files, offsets, tr, {"mic_echo_free": echo_free})))
    assert int(np.argmax(np.abs(y))) == 12345 + expected


def test_boost_of_the_mic_working_wav_reaches_the_original_audio(tmp_path):
    """No echo removed, the mic raised in the working wav: the original audio gets the same boost, once, so the level
    matches what the working wav had. Catches the boost dropped or applied twice."""
    x = tone(1000, RATE * 10, RATE, np.sqrt(2) * 10 ** (-50 / 20))  # in the 16 kHz band, so the wav and the original agree
    d, files, offsets, tr = call(tmp_path, mic_x=x, mic_sr=RATE)
    wav = write_wav(tr["mic"], audio.decode(tr["mic"]) * 31.6)  # the engine's boost: +30 dB, to -20 dBFS
    y = np.concatenate(list(listen.mix_pcm(files, offsets, {"mic": wav}, {"mic": 31.6})))
    assert db(seg(y, 2, 8)) == pytest.approx(-20, abs=0.5)


def test_mic_upsampled_from_the_cleaned_wav_is_in_place(tmp_path):
    """The cleaned mic wav (16 kHz) comes up to 48 kHz at the same moment."""
    x = np.zeros(SR * 3)
    x[8000] = 0.5
    d, files, offsets, tr = call(tmp_path, mic_x=x)
    y = np.concatenate(list(listen.mix_pcm(files, offsets, tr, {"mic_echo_free": True})))
    assert int(np.argmax(np.abs(y))) == 8000 * 3


@pytest.mark.parametrize("removed", [True, False])
def test_prepare_records_whether_echo_was_removed(tmp_path, monkeypatch, removed):
    """The listening step is told what cancel_echo did on this run, not what files it left. Catches a missing record."""
    monkeypatch.setattr(tracks, "cancel_echo", lambda *a, **k: removed)
    monkeypatch.setattr(tracks, "save_clean_mic", lambda *a, **k: None)
    src = {k: write_wav(tmp_path / f"{k}.m4a", noise(4, -10)) for k in ("mic", "system")}
    gains = {}
    tracks.prepare(src, {}, tmp_path, print, None, gains)
    assert gains["mic_echo_free"] is removed


def test_a_boost_alone_does_not_count_as_echo_removed(tmp_path, monkeypatch):
    """A quiet mic on a call without echo: the boost writes mic.clean.m4a, and the original mic still goes in the file."""
    monkeypatch.setattr(tracks, "cancel_echo", lambda *a, **k: False)
    src = {k: write_wav(tmp_path / f"{k}.m4a", noise(4, -40)) for k in ("mic", "system")}
    gains = {}
    tracks.prepare(src, {}, tmp_path, print, None, gains)
    assert gains["mic"] > 1.5 and (tmp_path / tracks.CLEAN_MIC).is_file()
    assert not gains["mic_echo_free"]


# --- the gain over the whole call, past the first chunk ---

def test_levelled_audio_follows_the_curve_across_chunks(tmp_path):
    """A constant 48 kHz source with a separate analysis wav over 75 s: output / source is the gain actually applied, and it
    is the curve interpolated at each sample's place, past 30 s and across both seams (the level changes right on them).
    Catches first_sample not advancing, a wrong frame centre, and no interpolation into or out of a chunk."""
    rng = np.random.default_rng(11)
    # 20% silence (the gate's floor). A loud second starting 0.25 s after the 30 s seam, another ending 0.25 s before the
    # 60 s seam: the gain is at its steepest on both seams
    x = np.concatenate([noise(15, -70, rng), noise(15.25, -33, rng), noise(1, -8, rng), noise(27.5, -33, rng),
                        noise(1, -8, rng), noise(15.25, -33, rng)])
    wav = write_wav(tmp_path / "analysis.wav", x)
    source = write_wav(tmp_path / "source.wav", np.full(RATE * 75, 0.1), RATE)
    out = pcm(wav, source)
    assert len(out) == RATE * 75
    with wave.open(str(source), "rb") as w:
        level = int.from_bytes(w.readframes(1), "little", signed=True) / 32768  # what the decoder delivers: the file's samples
    applied = 20 * np.log10(out / level)
    g = np.concatenate([g for _, g in listen.gain_db_stream(lambda: listen._read_frames(wav))])
    centres = np.arange(len(g)) * listen.RATE_HOP + listen.RATE_HOP / 2
    expected = np.interp(np.arange(len(out)), centres, g)
    for seam in (30, 60):
        around = expected[(seam * RATE - RATE // 20):(seam * RATE + RATE // 20)]
        assert np.ptp(around) > 0.5, f"the level does not change at {seam} s: the test would prove nothing"
    assert np.max(np.abs(applied - expected)) < 0.01


# --- no speech, and the limiter at a chunk boundary ---

def test_a_chunk_with_no_speech_is_never_raised():
    """_curve on frames with no speech, after a raised stretch: the gain may go down, never up. The stream cannot reach this
    with a raised gain today (a raised last frame means speech in the left context); this holds the rule itself."""
    g = listen._curve(np.full(listen.CHUNK_FRAMES, 1e-9), -50.0, 5.0)
    assert g.max() <= 0.0


def test_silence_after_raised_speech_stays_unraised():
    """Quiet speech raised at the end of a chunk, then over two chunks of silence: the silence is not raised."""
    rng = np.random.default_rng(13)
    x = np.concatenate([noise(listen.CHUNK_S, -33, rng), noise(2 * listen.CHUNK_S + 5, -85, rng)])
    chunks = list(listen.gain_db_stream(iter_frames_for(x)))
    assert chunks[0][1][1000:2000].max() > 3, "the speech is raised"
    assert chunks[1][1][100:].max() <= 0.0 and chunks[2][1].max() <= 0.0, "beyond the smoothing at the edge of the speech"


@pytest.mark.parametrize("offset", [-5, 5])
def test_limiter_boundary_next_to_a_peak(offset):
    """A chunk boundary 5 samples from a peak: exactly the output of the limiter on the whole array, and the ceiling holds.
    Catches a limiter window without enough context from the next or the previous chunk."""
    y = np.full(RATE, 0.01, dtype=np.float32)
    boundary = RATE // 2
    y[boundary + offset] = 0.99
    out = np.concatenate(list(listen.limited(iter([y[:boundary], y[boundary:]]))))
    assert np.allclose(out, listen._limit(y), atol=1e-6)
    assert np.abs(out).max() <= 10 ** (-1.5 / 20) + 1e-6


def test_boost_of_the_working_wav_reaches_the_full_band_audio(tmp_path):
    """The engine raised a quiet system track in the working wav: the gain is measured on it, so it must be applied to the
    full-band audio too. Catches a level curve for the raised wav applied to the quiet original."""
    d, files, offsets, _ = call(tmp_path, sys_x=noise(10, -50, sr=RATE))
    raw = audio.decode(files["system"])
    wav = write_wav(d / tracks.WORK / "system.wav", raw * 31.6)  # the engine's boost: +30 dB
    y = np.concatenate(list(listen.mix_pcm(files, offsets, {"system": wav}, {"system": 31.6})))
    # -50 + 30 = -20 dBFS, right on the target: no change from the levelling.
    assert db(seg(y, 2, 8)) == pytest.approx(-20, abs=1.5)


# --- the length of the call, single tracks ---

def test_length_is_the_length_of_the_call(tmp_path):
    """mic 10 s, system 45 s starting at 0.5 s (over a chunk longer): the file is 45.5 s. Catches min() of the tracks."""
    d, files, offsets, tr = call(tmp_path, sys_x=noise(45, -30, sr=RATE), mic_x=noise(10, -30), offsets={"system": 0.5})
    y = np.concatenate(list(listen.mix_pcm(files, offsets, tr, {})))
    assert abs(len(y) - int(45.5 * RATE)) <= 6


def test_mic_longer_than_system(tmp_path):
    d, files, offsets, tr = call(tmp_path, sys_x=noise(5, -30, sr=RATE), mic_x=noise(40, -30))
    y = np.concatenate(list(listen.mix_pcm(files, offsets, tr, {})))
    assert abs(len(y) - 40 * RATE) <= 6


@pytest.mark.parametrize("keys", [("mic",), ("system",)])
def test_a_single_track_call_renders(tmp_path, keys):
    """A reflection has the mic, an imported recording only system.m4a."""
    d, files, offsets, tr = call(tmp_path, sys_x=noise(4, -30, sr=RATE) if "system" in keys else None,
                                 mic_x=noise(4, -30) if "mic" in keys else None)
    out = listen.render(d, files, offsets, tr, {}, print)
    assert out and (d / listen.OUT).is_file()
    assert audio.duration(d / listen.OUT) == pytest.approx(4.0, abs=0.1)


def test_a_track_without_speech_is_still_in_the_mix(tmp_path):
    """prepare() drops a track with under a second of speech from transcription, but the player plays it today."""
    t = np.arange(RATE * 6) / RATE
    quiet_tone = np.float32(0.1 * np.sin(2 * np.pi * 440 * t))  # the working wav is gone, as prepare leaves it
    d, files, offsets, tr = call(tmp_path, sys_x=quiet_tone, mic_x=noise(6, -30))
    (d / tracks.WORK / "system.wav").unlink()
    y = np.concatenate(list(listen.mix_pcm(files, offsets, {"mic": tr["mic"]}, {})))
    assert db(seg(y, 1, 5)) > db(seg16(audio.decode(files["mic"]), 1, 5)) + 0.5


# --- render: the file, the failures ---

def test_render_writes_a_mono_aac_of_the_right_size(tmp_path):
    d, files, offsets, tr = call(tmp_path, sys_x=noise(30, -30, sr=RATE), mic_x=noise(30, -30))
    logged, log = lines()
    assert listen.render(d, files, offsets, tr, {}, log) is True
    out = d / listen.OUT
    info = subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-i", str(out)], capture_output=True, text=True).stderr
    assert re.search(r"Audio: aac\b.*, 48000 Hz, mono,", info), info  # ffmpeg only: neither CI nor the app has ffprobe
    assert audio.duration(out) == pytest.approx(30.0, abs=0.1)
    per_hour = out.stat().st_size * 120 / 1e6
    assert 28 <= per_hour <= 38, f"{per_hour:.1f} MB per hour"
    assert any("listen" in m or "прослушив" in m for m in logged)


def test_render_never_touches_the_tracks_or_the_working_wavs(tmp_path):
    d, files, offsets, tr = call(tmp_path, sys_x=noise(5, -30, sr=RATE), mic_x=noise(5, -30))
    (d / tracks.CLEAN_MIC).write_bytes(b"clean" * 400)
    before = {p: p.read_bytes() for p in [*d.iterdir(), *(d / tracks.WORK).iterdir()] if p.is_file()}
    assert listen.render(d, files, offsets, tr, {}, print)
    for p, data in before.items():
        assert p.read_bytes() == data, f"{p.name} changed"


def test_chunks_join_without_a_seam():
    """Audio with a loud stretch straddling a chunk boundary: the output equals the whole-file result of the approved
    formula, also around the boundary. Catches a chunking bug (a missing context, a gap at the seam)."""
    rng = np.random.default_rng(3)
    seam = listen.CHUNK_S
    x = np.concatenate([noise(10, -70, rng), noise(seam - 24, -33, rng), noise(4, -8, rng), noise(9.7, -33, rng),
                        noise(0.6, -8, rng), noise(9.7, -33, rng), noise(20, -70, rng), noise(20, -33, rng)])
    g = np.concatenate([g for _, g in listen.gain_db_stream(iter_frames_for(x))])
    assert len(g) == len(x) // listen.HOP
    assert np.max(np.abs(g - reference_gain(x)[:len(g)])) < 0.5


def iter_frames_for(x):
    """The 10 ms power frames of an array, as listen reads them from a wav, cut into its chunks."""
    frames = (x[:len(x) // listen.HOP * listen.HOP].reshape(-1, listen.HOP) ** 2).mean(1)
    return lambda: iter([frames[i:i + listen.CHUNK_FRAMES] for i in range(0, len(frames), listen.CHUNK_FRAMES)])


def reference_gain(x):
    """The approved prototype's gain in dB, whole-file (the reference for the chunked one). Numbers from the prototype."""
    n = len(x) // 160
    p = (x[:n * 160].reshape(n, 160) ** 2).mean(1)
    fast = 10 * np.log10(np.maximum(p, 1e-12))
    floor = np.percentile(fast[fast > -90], 15)
    gate = max(-50.0, floor + 12)
    active = gaussian_filter1d((fast > gate).astype(float), 8) > 0.3
    w = gaussian_filter1d(p * active, 15) / np.maximum(gaussian_filter1d(active.astype(float), 15), 1e-3)
    d = 10 * np.log10(np.maximum(w, 1e-12)) + 20
    g = np.where(d > 0, -d * 0.85, np.minimum(-d * 0.35, 6.0))
    idx = np.arange(n)
    g = np.interp(idx, idx[active], g[active])
    g[~active] = np.minimum(g[~active], 0)
    return gaussian_filter1d(minimum_filter1d(g, 11), 10)


def test_reads_are_bounded(tmp_path, monkeypatch):
    """Neither the working wav nor the decoder pipe is asked for more than a chunk. Catches a whole-file read of either."""
    d, files, offsets, tr = call(tmp_path, sys_x=noise(240, -30, sr=RATE), mic_x=noise(240, -30))
    frames, pipe = [], []
    readframes = wave.Wave_read.readframes

    def spy(self, n):
        frames.append(n)
        return readframes(self, n)
    monkeypatch.setattr(wave.Wave_read, "readframes", spy)
    init = listen._Decoder.__init__

    class Pipe:
        """The decoder's stdout: remembers how much each read asked for and got."""
        def __init__(self, raw):
            self.raw = raw

        def read(self, n=-1):
            data = self.raw.read(n)
            pipe.append(max(n, len(data)) if n >= 0 else len(data) + 1 + listen.CHUNK_SAMPLES * 2)
            return data

        def close(self):
            self.raw.close()

    def decoder(self, path, delay):
        init(self, path, delay)
        self.proc.stdout = Pipe(self.proc.stdout)
    monkeypatch.setattr(listen._Decoder, "__init__", decoder)
    assert sum(len(c) for c in listen.mix_pcm(files, offsets, tr, {})) == 240 * RATE
    assert frames and max(frames) <= listen.CHUNK_FRAMES * listen.HOP
    assert pipe and max(pipe) <= listen.CHUNK_SAMPLES * 2


def test_memory_does_not_grow_with_the_call(tmp_path):
    """Peak allocation of a 6 minute render is about that of a 3 minute one. Catches accumulating arrays for the whole call."""
    def peak(sec: int) -> int:
        sub = tmp_path / f"m{sec}"
        d, files, offsets, tr = call(sub, sys_x=noise(sec, -30, sr=RATE), mic_x=noise(sec, -30))
        tracemalloc.start()
        tracemalloc.reset_peak()
        n = sum(len(c) for c in listen.mix_pcm(files, offsets, tr, {}))
        _, top = tracemalloc.get_traced_memory()
        tracemalloc.stop()
        assert n == sec * RATE
        return top
    short, long_ = peak(180), peak(360)
    assert long_ < short * 1.25, f"{short} -> {long_}"
    assert long_ < 200 * (1 << 20)


def test_a_broken_track_leaves_no_file_and_does_not_raise(tmp_path):
    d, files, offsets, tr = call(tmp_path, sys_x=noise(3, -30, sr=RATE), mic_x=noise(3, -30))
    (d / "system.m4a").write_bytes(b"not audio" * 2000)
    (d / listen.OUT).write_bytes(b"old listening file")
    logged, log = lines()
    assert listen.render(d, files, offsets, tr, {}, log) is False
    assert not (d / listen.OUT).exists(), "the old file of an earlier run goes too"
    assert logged


def test_broken_working_wav_does_not_raise(tmp_path):
    d, files, offsets, tr = call(tmp_path, sys_x=noise(3, -30, sr=RATE))
    tr["system"].write_bytes(b"not a wav at all")
    logged, log = lines()
    assert listen.render(d, files, offsets, tr, {}, log) is False
    assert not (d / listen.OUT).exists() and logged


def test_failure_of_the_encoder_leaves_nothing(tmp_path, monkeypatch):
    d, files, offsets, tr = call(tmp_path, sys_x=noise(3, -30, sr=RATE))
    monkeypatch.setattr(listen, "ENCODER", ("-c:a", "no-such-codec"))
    logged, log = lines()
    assert listen.render(d, files, offsets, tr, {}, log) is False
    assert not (d / listen.OUT).exists() and logged


def test_exit_during_the_render_leaves_nothing_partial(tmp_path, monkeypatch):
    """SystemExit from inside the render (no real signal: see the next test): the temp file stays in .work, the exit passes
    through, and the encoder is gone and reaped. Catches writing straight to listen.m4a and swallowing the exit."""
    d, files, offsets, tr = call(tmp_path, sys_x=noise(3, -30, sr=RATE))
    real = listen.mix_pcm

    written, encoders = [], []
    popen = subprocess.Popen

    def spy(args, **kw):
        proc = popen(args, **kw)
        if "-i" in args and args[args.index("-i") + 1] == "-":
            written.append(Path(args[-1]))
            encoders.append(proc)
        return proc
    monkeypatch.setattr(listen.subprocess, "Popen", spy)

    def dying(*a, **k):
        yield next(real(*a, **k))
        raise SystemExit(143)
    monkeypatch.setattr(listen, "mix_pcm", dying)
    with pytest.raises(SystemExit):
        listen.render(d, files, offsets, tr, {}, print)
    assert written == [d / tracks.WORK / listen.OUT], "the encoder writes into .work, the file is renamed when complete"
    assert encoders[0].returncode is not None, "the encoder was not waited for"
    assert not (d / listen.OUT).exists() and not (d / tracks.WORK / listen.OUT).exists()
    assert sorted(p.name for p in d.glob(".*") if p.name != tracks.WORK) == []


SIGTERM_CHILD = """
import os, subprocess, sys, time
from pathlib import Path
from sozvon_engine.pipeline import guard, listen, tracks
guard.exit_on_sigterm()
children = []
popen = subprocess.Popen
def spy(args, **kw):
    proc = popen(args, **kw)
    children.append(proc.pid)
    return proc
subprocess.Popen = spy
real = listen.mix_pcm
def held(*a):
    for i, chunk in enumerate(real(*a)):
        yield chunk
        if i == 0:
            print(" ".join(map(str, children)), flush=True)
        time.sleep(30)
listen.mix_pcm = held
d = Path(sys.argv[1])
work = d / tracks.WORK
files = {k: d / f"{k}.m4a" for k in ("mic", "system")}
tr = {k: work / f"{k}.wav" for k in files}
listen.render(d, files, {}, tr, {}, print)
"""


def test_real_sigterm_during_the_render(tmp_path):
    """A real SIGTERM mid-render with real decoders and encoder, as the app sends on quit: exit 143, every ffmpeg gone, no
    temp file, no listen.m4a. Catches children left running and a handler that does not unwind the render."""
    d, files, offsets, tr = call(tmp_path, sys_x=noise(65, -30, sr=RATE), mic_x=noise(65, -30))
    env = {**os.environ, "PYTHONPATH": str(Path(listen.__file__).parents[2])}
    child = subprocess.Popen([sys.executable, "-c", SIGTERM_CHILD, str(d)], stdout=subprocess.PIPE, text=True, env=env)
    try:
        pids = [int(p) for p in child.stdout.readline().split()]
        assert len(pids) == 3, "two decoders and the encoder are running"
        child.send_signal(signal.SIGTERM)
        assert child.wait(timeout=30) == 143
    finally:
        child.kill()
        child.stdout.close()
    deadline = time.monotonic() + 5
    alive = pids
    while alive and time.monotonic() < deadline:
        alive = [p for p in alive if subprocess.run(["kill", "-0", str(p)], capture_output=True).returncode == 0]
        time.sleep(0.05)
    assert not alive, "ffmpeg still running"
    assert not (d / listen.OUT).exists() and not (d / tracks.WORK / listen.OUT).exists()


class _Mix:
    """A mix that fails after one chunk and whose close() fails as well."""
    def __init__(self):
        self.left = [np.zeros(RATE, dtype=np.float32)]

    def __iter__(self):
        return self

    def __next__(self):
        if not self.left:
            raise OSError("read failed")
        return self.left.pop()

    def close(self):
        raise RuntimeError("close failed")


def test_a_failing_cleanup_does_not_raise_and_stops_the_encoder(tmp_path, monkeypatch):
    """render never raises, also from its cleanup, and the encoder is still stopped. Catches the cleanup outside the try."""
    d, files, offsets, tr = call(tmp_path, sys_x=noise(3, -30, sr=RATE))
    monkeypatch.setattr(listen, "mix_pcm", lambda *a: _Mix())
    encoders = []
    popen = subprocess.Popen

    def spy(args, **kw):
        encoders.append(popen(args, **kw))
        return encoders[-1]
    monkeypatch.setattr(listen.subprocess, "Popen", spy)
    logged, log = lines()
    assert listen.render(d, files, offsets, tr, {}, log) is False
    assert logged and encoders[0].returncode is not None
    assert not (d / listen.OUT).exists()


def test_a_failing_temp_removal_does_not_raise(tmp_path, monkeypatch):
    """The last line of the cleanup can fail too: the render still returns, and the finished file stays."""
    d, files, offsets, tr = call(tmp_path, sys_x=noise(3, -30, sr=RATE))
    unlink = Path.unlink

    def failing(self, missing_ok=False):
        if self == d / tracks.WORK / listen.OUT:
            raise PermissionError("no")
        return unlink(self, missing_ok=missing_ok)
    monkeypatch.setattr(Path, "unlink", failing)
    listen.render(d, files, offsets, tr, {}, print)
    assert (d / listen.OUT).is_file()


def test_no_listen_without_files(tmp_path):
    """No tracks: nothing is written and a file of an earlier run goes. Catches a render that returns without removing it."""
    d = tmp_path / "call"
    d.mkdir()
    (d / listen.OUT).write_bytes(b"old listening file")
    assert listen.render(d, {}, {}, {}, {}, print) is False
    assert not (d / listen.OUT).exists()


# --- the pipeline: order, what it sees, failures ---

from test_run import fakes, make_call, result  # noqa: E402,F401  the fixtures of the pipeline tests


def test_pipeline_renders_after_the_transcript_is_written(tmp_path, capsys, fakes, monkeypatch):
    """Runs on the tracks prepare left, once the transcript is on disk. Catches a step that is not wired into run.process."""
    d = make_call(tmp_path, {"id": "2026-11-04 15-01"})
    seen = []

    def render(call_dir, files, offsets, tr, gains, log):
        seen.append(dict(transcript=(Path(call_dir) / "transcript.txt").exists(), files=set(files), tr=set(tr), work=Path(call_dir, tracks.WORK).is_dir()))
        return True
    monkeypatch.setattr(listen, "render", render)
    assert run.main([str(d)]) == 0
    assert result(capsys) == "RESULT: ok"
    assert seen == [{"transcript": True, "files": {"mic", "system"}, "tr": {"mic", "system"}, "work": True}]
    assert not (d / tracks.WORK).exists(), "the working files still go at the end"


def test_the_call_is_done_before_the_render_starts(tmp_path, capsys, fakes, monkeypatch):
    """call.json says done, with everything in it, before the render starts: a quit during the render cannot make a finished
    call look unfinished. Catches status done written after the render."""
    d = make_call(tmp_path, {"id": "2026-11-04 15-01"})
    seen = {}
    monkeypatch.setattr(run.remote, "push_after_transcription", lambda *a: seen.update(pushed=True))

    def render(call_dir, *a):
        seen.update(json.loads((Path(call_dir) / "call.json").read_text()))
        return True
    monkeypatch.setattr(listen, "render", render)
    assert run.main([str(d)]) == 0
    assert result(capsys) == "RESULT: ok"
    assert seen["status"] == "done" and seen["engine"]["model"] and "participants" in seen and seen["pushed"]


def test_a_quit_during_the_render_keeps_the_call_done(tmp_path, capsys, fakes, monkeypatch):
    """SIGTERM during the render (the app quitting): the call stays done, the transcript is there, .work is gone."""
    d = make_call(tmp_path, {"id": "2026-11-04 15-01"})

    def render(*a):
        raise SystemExit(143)
    monkeypatch.setattr(listen, "render", render)
    with pytest.raises(SystemExit):
        run.main([str(d)])
    assert json.loads((d / "call.json").read_text())["status"] == "done"
    assert (d / "transcript.txt").exists() and not (d / listen.OUT).exists() and not (d / tracks.WORK).exists()


def test_a_failing_render_does_not_fail_the_run(tmp_path, capsys, fakes):
    """The fake to_wav writes rubbish wavs, so the step fails on the real code: the call is still done, no warning, no file."""
    d = make_call(tmp_path, {"id": "2026-11-04 15-01"})
    assert run.main([str(d)]) == 0
    assert result(capsys) == "RESULT: ok"
    assert (d / "transcript.txt").exists() and not (d / listen.OUT).exists()
    assert "warnings" not in json.loads((d / "call.json").read_text())


def test_transcription_never_sees_the_levelling(tmp_path, capsys, fakes):
    """A listen.m4a from an earlier run is in the folder: transcription still gets exactly the two working wavs in .work."""
    d = make_call(tmp_path, {"id": "2026-11-04 15-01"})
    (d / listen.OUT).write_bytes(b"old listening file" * 200)
    run.main([str(d)])
    assert result(capsys) == "RESULT: ok"
    assert {k: (p.parent.name, p.name) for k, p in fakes["tracks"].items()} == {
        "mic": (tracks.WORK, "mic.wav"), "system": (tracks.WORK, "system.wav")}


def test_prepare_reports_the_boost(tmp_path, monkeypatch):
    """prepare() tells the listening step how much it raised a quiet track."""
    x = noise(4, -30)
    src = write_wav(tmp_path / "system.m4a", x * 0.05)  # peak well under 0.1
    d = tmp_path
    gains = {}
    out = tracks.prepare({"system": src}, {}, d, print, None, gains)
    assert "system" in out and gains["system"] > 1.5


def test_the_engine_starts_without_scipy(tmp_path):
    """No scipy: the whole pipeline still imports and the render only loses its own file, with a log line. Catches a
    module-level scipy import anywhere in what the engine loads for a run."""
    d, files, offsets, tr = call(tmp_path, sys_x=noise(2, -30, sr=RATE))
    code = f"""
import sys
sys.modules['scipy'] = None
sys.modules['scipy.ndimage'] = None
from pathlib import Path
from sozvon_engine.pipeline import listen, run
d = Path({str(d)!r})
print(listen.render(d, {{'system': d / 'system.m4a'}}, {{}}, {{'system': d / '.work' / 'system.wav'}}, {{}}, lambda m: print('LOG', m)))
"""
    r = subprocess.run([sys.executable, "-c", code], cwd=Path(listen.__file__).parents[2], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[-300:]
    assert r.stdout.strip().endswith("False") and "LOG" in r.stdout, r.stdout[-300:]
    assert not (d / listen.OUT).exists()
