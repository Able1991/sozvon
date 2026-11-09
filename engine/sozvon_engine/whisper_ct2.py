"""Whisper on Windows: faster-whisper (ctranslate2) in place of mlx-whisper. Imported only on win32.

The GPU is optional and only speeds things up: without the GPU part of the install, or when anything goes wrong on the
card, the same transcription runs with int8 on the CPU. The device is chosen once per process, at the first load of a
model.
"""
import sys
from pathlib import Path

from . import accel, audio, config, platform_support
from .i18n import t

_CPU = ("cpu", "int8")
_SEED = 1  # the retries with a temperature above 0 sample at random: the same call gives the same text

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


def _decide() -> tuple:
    """torch first, always: it loads the CUDA libraries by absolute path, and ctranslate2, which asks for them by name
    only, then finds those. Without the GPU part of the install nothing asks for them at all."""
    if accel.gpu_configured() and accel.torch_device("whisper") == "cuda":
        import ctranslate2
        if ctranslate2.get_cuda_device_count() > 0:
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
    threads = config.load().threads or platform_support.default_thread_limit()
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
            accel.note_failure("whisper", e)
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
        import ctranslate2
        ctranslate2.set_random_seed(_SEED)
        segments, info = model.transcribe(samples, **options)
        return {"segments": [_segment(s) for s in segments], "language": info.language}  # lazy: the work happens here

    return _with_fallback(path_or_hf_repo, work)


def language_probs(model_path: str, chunk) -> dict:
    """{language code: probability} for a piece of audio, all the languages of the model."""
    def work(model):
        return dict(model.detect_language(audio=chunk)[2])

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


def release() -> None:
    """The models leave the memory of the card for the stages after recognition."""
    _models.clear()
    accel.release()


def ensure_backend() -> None:
    import ctranslate2  # noqa: F401
    import faster_whisper  # noqa: F401
