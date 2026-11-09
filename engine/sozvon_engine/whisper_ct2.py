"""Whisper on Windows: faster-whisper (ctranslate2) in place of mlx-whisper. Imported only on win32.

The GPU is optional and only speeds things up: with no CUDA libraries, or when anything goes wrong on the card, the
same transcription runs with int8 on the CPU. The device is chosen once per process, at the first load of a model.
"""
import ctypes
import os
import sys
from ctypes import wintypes
from pathlib import Path

from . import audio, config, paths
from .i18n import t

_kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
_kernel32.LoadLibraryExW.restype = wintypes.HMODULE
_kernel32.LoadLibraryExW.argtypes = (wintypes.LPCWSTR, wintypes.HANDLE, wintypes.DWORD)

# Dependencies first. Enough to run on the GPU: Whisper's convolutions need no cuDNN.
_CUBLAS = ("cublasLt64_12.dll", "cublas64_12.dll")
_LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR = 0x100
_LOAD_LIBRARY_SEARCH_DEFAULT_DIRS = 0x1000

_CPU = ("cpu", "int8")

# What mlx_whisper.transcribe uses, spelled out so that faster-whisper's own defaults decide nothing. Greedy search,
# as on the Mac (faster-whisper defaults to a beam of 5), and no voice activity filter of its own.
_DECODING = {
    "task": "transcribe",
    "beam_size": 1,
    "best_of": 1,
    "patience": 1.0,
    "vad_filter": False,
    "temperature": (0.0, 0.2, 0.4, 0.6, 0.8, 1.0),
    "compression_ratio_threshold": 2.4,
    "log_prob_threshold": -1.0,
    "no_speech_threshold": 0.6,
}

_ASSET = Path(__file__).resolve().parent / "assets" / "whisper-tokenizer.json"

_choice = None     # (device, compute type) for this process
_models: dict = {}
_loaded_tokenizer = None


def _log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def _load_cuda_libraries() -> bool:
    """cublas from <data>/cuda-libs, by absolute path, its dependencies from that folder and the system folders.

    ctranslate2 asks for it by name only and the loader would then look in the current folder and on PATH. Loaded here
    first, that request finds this module; without these files the CPU is used and nothing is asked for at all."""
    folder = (paths.data_dir() / "cuda-libs").resolve()
    files = [folder / name for name in _CUBLAS]
    if not all(f.is_file() for f in files):
        return False
    flags = _LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | _LOAD_LIBRARY_SEARCH_DEFAULT_DIRS
    return all(_kernel32.LoadLibraryExW(str(f), None, flags) for f in files)


def _decide() -> tuple:
    import ctranslate2
    if _load_cuda_libraries() and ctranslate2.get_cuda_device_count() > 0:
        types = ctranslate2.get_supported_compute_types("cuda")
        return "cuda", "float16" if "float16" in types else "float32"
    return _CPU


def _device() -> tuple:
    global _choice
    if _choice is None:
        _choice = _decide()
        _log(t("log_whisper_device", device=_choice[0], compute=_choice[1]))
    return _choice


def _new_model(path: str, device: str, compute: str):
    from faster_whisper import WhisperModel
    threads = config.load().threads or max(1, (os.cpu_count() or 2) // 2)
    return WhisperModel(path, device=device, compute_type=compute, cpu_threads=threads, num_workers=1, local_files_only=True)


def _model(path: str, device: str, compute: str):
    key = (path, device, compute)
    if key not in _models:
        _models[key] = _new_model(path, device, compute)
    return _models[key]


def _with_fallback(path: str, work):
    """work(model) on the chosen device. If the GPU fails, at load or at any point of the work, the rest of this process
    stays on the CPU and the work starts over there. work must return nothing it got before it failed."""
    global _choice
    while True:
        device, compute = _device()
        try:
            return work(_model(path, device, compute))
        except (RuntimeError, ValueError) as e:
            if device != "cuda":
                raise
            _log(t("log_whisper_gpu_failed", err=" ".join(str(e).split())[:300]))
            _choice = _CPU
            _models.clear()


def _segment(s) -> dict:
    """The dict mlx-whisper gives for a segment, for what the engine reads."""
    return {"start": s.start, "end": s.end, "text": s.text, "no_speech_prob": s.no_speech_prob,
            "avg_logprob": s.avg_logprob, "compression_ratio": s.compression_ratio,
            "words": [{"word": w.word, "start": w.start, "end": w.end, "probability": w.probability} for w in s.words or []]}


def transcribe(audio_input, *, path_or_hf_repo: str, language=None, initial_prompt=None, word_timestamps: bool = False,
               hallucination_silence_threshold=None, condition_on_previous_text: bool = True) -> dict:
    """mlx_whisper.transcribe, for the arguments the engine passes. -> {"segments": [...], "language": ...}."""
    # Always our own decoder: faster-whisper 1.2.1 cannot open a file with the locked av.
    samples = audio_input if hasattr(audio_input, "shape") else audio.decode(audio_input)
    options = {**_DECODING, "language": language, "initial_prompt": initial_prompt, "word_timestamps": word_timestamps,
               "hallucination_silence_threshold": hallucination_silence_threshold,
               "condition_on_previous_text": condition_on_previous_text}

    def work(model):
        segments, info = model.transcribe(samples, **options)
        return {"segments": [_segment(s) for s in segments], "language": info.language}  # lazy: the work happens here

    return _with_fallback(path_or_hf_repo, work)


def language_probs(model_path: str, chunk) -> dict:
    """{language code: probability} for a piece of audio, all the languages of the model."""
    from faster_whisper.audio import pad_or_trim

    def work(model):
        encoded = model.encode(pad_or_trim(model.feature_extractor(chunk), 3000))
        return {token[2:-2]: p for token, p in model.model.detect_language(encoded)[0]}

    return _with_fallback(model_path, work)


def _tokenizer():
    global _loaded_tokenizer
    if _loaded_tokenizer is None:
        from tokenizers import Tokenizer
        _loaded_tokenizer = Tokenizer.from_file(str(_ASSET))
    return _loaded_tokenizer


def count_tokens(text: str) -> int:
    """Whisper tokens of a prompt, as faster-whisper feeds it to the model, without loading the model."""
    return len(_tokenizer().encode(" " + text, add_special_tokens=False).ids)


def ensure_backend() -> None:
    import ctranslate2  # noqa: F401
    import faster_whisper  # noqa: F401
