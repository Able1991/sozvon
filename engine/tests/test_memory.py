"""Memory between stages: what MLX and torch keep for reuse is given back (a 75-minute call held 17 GB)."""
import sys
import types

import numpy as np
import pytest

from sozvon_engine import accel, diarize, platform_support, whisper, whisper_ct2


@pytest.fixture
def macos(monkeypatch):
    monkeypatch.setattr(platform_support, "SYSTEM", "darwin")


@pytest.fixture
def fake_mlx(monkeypatch, macos):
    calls = []
    core = types.ModuleType("mlx.core")
    core.set_cache_limit = lambda n: calls.append(("limit", n))
    core.clear_cache = lambda: calls.append(("clear",))
    core.random = types.SimpleNamespace(seed=lambda n: calls.append(("seed", n)))
    mlx = types.ModuleType("mlx")
    mlx.core = core
    mw = types.ModuleType("mlx_whisper")

    def transcribe(audio, **kw):
        calls.append(("transcribe",))
        if kw.get("fail"):
            raise RuntimeError("boom")
        return {"segments": []}
    mw.transcribe = transcribe
    inner = types.ModuleType("mlx_whisper.transcribe")      # the module behind the function of the same name
    inner.log_mel_spectrogram = "the library's own"

    class ModelHolder:
        model = object()
        model_path = "somewhere"
    inner.ModelHolder = ModelHolder
    monkeypatch.setitem(sys.modules, "mlx", mlx)
    monkeypatch.setitem(sys.modules, "mlx.core", core)
    monkeypatch.setitem(sys.modules, "mlx_whisper", mw)
    monkeypatch.setitem(sys.modules, "mlx_whisper.transcribe", inner)
    return calls


def test_whisper_runs_with_a_small_mlx_cache_and_clears_it(fake_mlx):
    whisper._transcribe("a.wav")
    assert fake_mlx[0] == ("limit", whisper.MLX_CACHE_LIMIT)
    assert whisper.MLX_CACHE_LIMIT <= 1 << 30
    assert fake_mlx[1:] == [("seed", whisper.SEED), ("transcribe",), ("clear",)]


def test_mlx_cache_is_cleared_when_whisper_fails(fake_mlx):
    with pytest.raises(RuntimeError):
        whisper._transcribe("a.wav", fail=True)
    assert fake_mlx[-1] == ("clear",)


class FakeAnnotation:
    def itertracks(self, yield_label=False):
        return iter([])


def test_diarization_gives_torch_memory_back(monkeypatch):
    released = []
    monkeypatch.setattr(diarize, "load_pipeline", lambda: (lambda wave, **kw: FakeAnnotation()))
    monkeypatch.setattr(diarize, "load_waveform", lambda path: {})
    monkeypatch.setattr(diarize, "release_memory", lambda: released.append(1))
    assert diarize.run("a.wav") == []
    assert released == [1]


def test_diarization_gives_memory_back_on_failure(monkeypatch):
    released = []

    def broken(wave, **kw):
        raise RuntimeError("mps out of memory")
    monkeypatch.setattr(diarize, "load_pipeline", lambda: broken)
    monkeypatch.setattr(diarize, "load_waveform", lambda path: {})
    monkeypatch.setattr(diarize, "release_memory", lambda: released.append(1))
    with pytest.raises(RuntimeError):
        diarize.run("a.wav")
    assert released == [1]


def test_release_memory_is_safe_without_mps():
    diarize.release_memory()


# The spectrogram of a whole track: mlx-whisper builds it in one piece, about 12 times the audio in memory.

def test_whisper_gets_the_spectrogram_in_pieces(fake_mlx):
    whisper._transcribe("a.wav")
    assert sys.modules["mlx_whisper.transcribe"].log_mel_spectrogram is whisper.log_mel


@pytest.mark.parametrize("seconds, padding", [(1, 0), (95, 0), (95, 480000)])
def test_the_spectrogram_in_pieces_is_the_library_one(seconds, padding, monkeypatch):
    np = pytest.importorskip("numpy")
    mx = pytest.importorskip("mlx.core")
    audio = pytest.importorskip("mlx_whisper.audio")
    monkeypatch.setattr(whisper, "MEL_FRAMES", 3000)        # several pieces in 95 seconds
    x = (0.1 * np.random.default_rng(3).standard_normal(seconds * 16000 + 77)).astype(np.float32)
    want = np.array(audio.log_mel_spectrogram(x, n_mels=128, padding=padding))
    got = np.array(whisper.log_mel(x, n_mels=128, padding=padding))
    assert got.shape == want.shape
    assert float(np.abs(got - want).max()) < 1e-5
    assert np.array_equal(np.array(whisper.log_mel(mx.array(x), n_mels=128, padding=padding)), got)


def test_the_spectrogram_of_a_long_track_takes_a_fraction_of_the_memory():
    np = pytest.importorskip("numpy")
    mx = pytest.importorskip("mlx.core")
    pytest.importorskip("mlx_whisper.audio")
    x = (0.1 * np.random.default_rng(4).standard_normal(8 * 60 * 16000)).astype(np.float32)   # 8 minutes, 29 MB
    mx.clear_cache()
    mx.reset_peak_memory()
    mel = whisper.log_mel(x, n_mels=128)
    mx.eval(mel)
    # The library's own function peaks at about 12 times the audio; the result alone is 0.8 of it.
    assert mx.get_peak_memory() < 5 * x.nbytes, f"{mx.get_peak_memory() / x.nbytes:.1f} times the audio"


# Whisper retries an unsure piece with random sampling: with a fixed seed the same call gives the same text.

def test_whisper_samples_the_same_way_every_time(monkeypatch):
    mx = pytest.importorskip("mlx.core")
    picks = []
    mw = types.ModuleType("mlx_whisper")
    inner = types.ModuleType("mlx_whisper.transcribe")

    def transcribe(audio, **kw):
        picks.append(mx.random.categorical(mx.zeros((1, 50)), num_samples=20).tolist())
        return {"segments": []}
    mw.transcribe = transcribe
    monkeypatch.setitem(sys.modules, "mlx_whisper", mw)
    monkeypatch.setitem(sys.modules, "mlx_whisper.transcribe", inner)
    whisper._transcribe("a.wav")
    mx.random.categorical(mx.zeros((1, 50)))      # something else draws in between
    whisper._transcribe("a.wav")
    assert picks[0] == picks[1]


# Parakeet and GigaAM stay cached after recognition: diarization does not need them.

def test_the_onnx_model_is_dropped(monkeypatch):
    from sozvon_engine import asr_onnx
    monkeypatch.setattr(asr_onnx, "_cache", {"parakeet": object()})
    asr_onnx.release()
    assert asr_onnx._cache == {}


# The Whisper model stays loaded in mlx-whisper after a call: 1.5 GB that diarization does not need.

def test_the_whisper_model_is_dropped(fake_mlx):
    holder = sys.modules["mlx_whisper.transcribe"].ModelHolder
    whisper.release_model()
    assert holder.model is None and holder.model_path is None
    assert fake_mlx[-1] == ("clear",)


def test_dropping_the_model_without_whisper_loaded_does_nothing(monkeypatch, macos):
    monkeypatch.delitem(sys.modules, "mlx_whisper.transcribe", raising=False)
    monkeypatch.delitem(sys.modules, "mlx_whisper", raising=False)
    before = set(sys.modules)
    whisper.release_model()
    assert "mlx_whisper.transcribe" not in set(sys.modules) - before


def test_the_windows_whisper_models_are_dropped_and_the_card_is_given_back(monkeypatch):
    """faster-whisper keeps a model per device: the same drop lets go of them and empties the CUDA cache,
    and the device chosen for this process stays."""
    monkeypatch.setattr(platform_support, "SYSTEM", "win32")
    monkeypatch.setattr(whisper_ct2, "_models", {("m", "cuda", "float16"): object()})
    monkeypatch.setattr(whisper_ct2, "_choice", ("cuda", "float16"))
    freed = []
    monkeypatch.setattr(accel, "release", lambda: freed.append(True))
    whisper.release_model()
    assert whisper_ct2._models == {} and freed == [True]
    assert whisper_ct2._choice == ("cuda", "float16")


def test_release_memory_empties_the_cuda_cache_on_windows(monkeypatch):
    monkeypatch.setattr(platform_support, "SYSTEM", "win32")
    import torch
    emptied = []
    monkeypatch.setattr(torch.cuda, "is_available", lambda: True)
    monkeypatch.setattr(torch.cuda, "empty_cache", lambda: emptied.append(True))
    diarize.release_memory()
    assert emptied == [True]


# Whole tracks in memory: one copy, and only while something needs it.

def pcm_wav(path, samples, rate=16000, channels=1):
    import wave
    with wave.open(str(path), "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(np.asarray(samples, dtype="<i2").tobytes())
    return path


def some_samples(n=40000):
    return np.random.default_rng(1).integers(-32768, 32767, n, dtype=np.int16)


def test_a_working_wav_is_read_without_ffmpeg(tmp_path, monkeypatch):
    from sozvon_engine import audio
    s = some_samples()
    wav = pcm_wav(tmp_path / "mic.wav", s)
    monkeypatch.setattr(audio, "_run", lambda *a, **k: pytest.fail("ffmpeg holds the whole track twice"))
    x = audio.decode(wav)
    assert x.dtype == np.float32 and x.flags.writeable
    assert np.array_equal(x, s.astype(np.float32) / 32768)


def test_a_working_wav_reads_the_same_as_through_ffmpeg(tmp_path):
    import shutil
    from sozvon_engine import audio
    if not shutil.which("ffmpeg"):
        pytest.skip("no ffmpeg")
    wav = pcm_wav(tmp_path / "mic.wav", some_samples())
    through = np.frombuffer(audio._run(["-i", str(wav), "-f", "f32le", "-ac", "1", "-ar", "16000", "-"], wav),
                            dtype=np.float32)
    assert np.array_equal(audio.decode(wav), through)


@pytest.mark.parametrize("rate,channels", [(48000, 1), (16000, 2)])
def test_any_other_file_still_goes_through_ffmpeg(tmp_path, monkeypatch, rate, channels):
    from sozvon_engine import audio
    wav = pcm_wav(tmp_path / "a.wav", some_samples(), rate, channels)
    monkeypatch.setattr(audio, "_run", lambda args, src: np.ones(5, dtype=np.float32).tobytes())
    assert audio.decode(wav).tolist() == [1.0] * 5
    notwav = tmp_path / "a.m4a"
    notwav.write_bytes(b"not a wav")
    assert audio.decode(notwav).tolist() == [1.0] * 5


def test_diarization_gets_the_track_without_a_second_copy(monkeypatch):
    from sozvon_engine import audio, diarize
    x = np.zeros(1600, dtype=np.float32)
    monkeypatch.setattr(audio, "decode", lambda path: x)
    wave = diarize.load_waveform("mic.wav")
    assert wave["waveform"].shape == (1, 1600) and np.shares_memory(wave["waveform"].numpy(), x)


def test_the_diarization_pipeline_is_dropped(monkeypatch):
    from sozvon_engine import diarize
    monkeypatch.setattr(diarize, "_pipeline", object())
    freed = []
    monkeypatch.setattr(diarize, "release_memory", lambda: freed.append(True))
    diarize.unload()
    assert diarize._pipeline is None and freed == [True]


def test_the_track_is_not_held_through_whisper_when_languages_do_not_switch(monkeypatch):
    import gc
    import weakref
    from sozvon_engine import langid
    from sozvon_engine.pipeline import transcribe
    held = []

    def load_audio(wav):
        x = np.zeros(16000, dtype=np.float32)
        held.append(weakref.ref(x))
        return x

    def whisper_track(wav, model_path, lang, prompts, log):
        gc.collect()
        assert held[-1]() is None, "the decoded track is still alive while Whisper decodes the file again"
        return []
    monkeypatch.setattr(langid, "load_audio", load_audio)
    monkeypatch.setattr(langid, "detect_track", lambda audio, allowed, probs: ("ru", 1.0))
    monkeypatch.setattr(transcribe, "whisper_track", whisper_track)
    segs, langs = transcribe.transcribe_tracks(
        {"mic": "mic.wav"}, data_dir=None, model="turbo", model_path="m", allowed=["ru", "en"], switch=False,
        prompts=transcribe.Prompts(lambda lang: ("", ""), []), log=lambda *a: None)
    assert langs == {"mic": "ru"} and len(held) == 1


def test_dropping_a_pipeline_that_was_never_loaded_does_not_touch_torch(monkeypatch):
    from sozvon_engine import diarize
    monkeypatch.setattr(diarize, "_pipeline", None)
    monkeypatch.setattr(diarize, "release_memory", lambda: pytest.fail("torch is heavy to import for nothing"))
    diarize.unload()


# pyannote's own batches (32 ten-second windows) keep 4 GB on the GPU for a 75-minute track; in batches of 8
# the same turns come out of 1.3 GB, about a tenth slower (measured on a real call, same result to the turn).

def test_diarization_runs_in_small_batches(monkeypatch, data):
    (data / "hf-cache" / "hub").mkdir(parents=True)

    class FakePipeline:
        embedding_batch_size = 32
        segmentation_batch_size = 32

        def to(self, device):
            self.device = device

    made = FakePipeline()
    torch = types.ModuleType("torch")
    torch.set_num_threads = lambda n: None
    torch.device = lambda name: name
    torch.backends = types.SimpleNamespace(mps=types.SimpleNamespace(is_available=lambda: False))
    pa = types.ModuleType("pyannote.audio")
    pa.Pipeline = types.SimpleNamespace(from_pretrained=lambda name, token=None: made)
    monkeypatch.setitem(sys.modules, "torch", torch)
    monkeypatch.setitem(sys.modules, "pyannote", types.ModuleType("pyannote"))
    monkeypatch.setitem(sys.modules, "pyannote.audio", pa)
    monkeypatch.setattr(diarize, "_pipeline", None)
    monkeypatch.setattr(diarize, "available", lambda: True)
    assert diarize.load_pipeline() is made
    assert (made.embedding_batch_size, made.segmentation_batch_size) == (diarize.BATCH, diarize.BATCH)
    assert diarize.BATCH < 32
    monkeypatch.setattr(diarize, "_pipeline", None)
