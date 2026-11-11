"""Alternative ASR models via onnx-asr: GigaAM v3 (Russian) and Parakeet v3.

Unlike Whisper they take no prompt (project terms do not apply, only replacements),
but they are lighter and faster. A long recording is split into segments by VAD (Silero)
and each segment is recognized separately: this gives timestamps for merging tracks.
"""
import numpy as np

from . import config
from . import models as _models
from .audio import SR

is_onnx = _models.is_onnx
_cache: dict = {}


def _load(engine_dir, model: str):
    if model not in _cache:
        import onnx_asr
        import onnxruntime
        onnxruntime.set_default_logger_severity(3)  # keep pages of CoreML warnings out of the log
        name = _models.MODELS[model]["onnx_name"]
        opts = None
        threads = config.load().threads
        if threads:
            opts = onnxruntime.SessionOptions()
            opts.intra_op_num_threads = threads
        # CPU only. By default onnxruntime hands the graph to CoreML, which compiles it
        # piecewise: Parakeet ate 7 GB of memory, GigaAM ran 10x slower than real time.
        cpu = ["CPUExecutionProvider"]
        asr = onnx_asr.load_model(name, path=_models.model_dir(engine_dir, model), quantization="int8",
                                  sess_options=opts, providers=cpu)
        vad = onnx_asr.load_vad("silero", path=_models.vad_dir(engine_dir), providers=cpu)
        # Segments up to 20 s (model limit is ~20-30 s), pauses of 0.4 s or more split segments.
        _cache[model] = asr.with_vad(vad, max_speech_duration_s=20, min_silence_duration_ms=400,
                                     speech_pad_ms=150)
    return _cache[model]


def release() -> None:
    """Drop the loaded model and its speech detector (up to 2 GB for Parakeet): diarization does not need them,
    and the next call loads them again in a second."""
    import gc
    _cache.clear()
    gc.collect()


def transcribe(engine_dir, model: str, audio: np.ndarray) -> list:
    """16 kHz mono float32 -> [(start, end, text)]."""
    segs = _load(engine_dir, model).recognize(audio, sample_rate=SR)
    out = []
    for s in segs:
        t = (s.text or "").strip()
        if t:
            out.append((float(s.start), float(s.end), t))
    return out
