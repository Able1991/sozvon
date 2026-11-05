"""Альтернативные модели распознавания через onnx-asr: GigaAM v3 (русский) и Parakeet v3.

В отличие от Whisper они не принимают подсказку (термины проекта не работают, только
автозамены), зато легче и быстрее. Длинная запись режется на фразы VAD (Silero),
каждая фраза распознаётся отдельно: так получаем таймкоды для склейки дорожек.
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
        onnxruntime.set_default_logger_severity(3)  # без простыней предупреждений CoreML в журнале
        name = _models.MODELS[model]["onnx_name"]
        opts = None
        threads = config.load().threads
        if threads:
            opts = onnxruntime.SessionOptions()
            opts.intra_op_num_threads = threads
        # Только обычный процессор. По умолчанию onnxruntime отдаёт граф CoreML, тот компилирует
        # его кусками: Parakeet съедал 7 ГБ памяти, GigaAM работал в 10 раз медленнее реального времени.
        cpu = ["CPUExecutionProvider"]
        asr = onnx_asr.load_model(name, path=_models.model_dir(engine_dir, model), quantization="int8",
                                  sess_options=opts, providers=cpu)
        vad = onnx_asr.load_vad("silero", path=_models.vad_dir(engine_dir), providers=cpu)
        # Фразы до 20 с (предел моделей ~20-30 с), паузы от 0,4 с режут фразы.
        _cache[model] = asr.with_vad(vad, max_speech_duration_s=20, min_silence_duration_ms=400,
                                     speech_pad_ms=150)
    return _cache[model]


def transcribe(engine_dir, model: str, audio: np.ndarray) -> list:
    """16 кГц mono float32 -> [(start, end, text)]."""
    segs = _load(engine_dir, model).recognize(audio, sample_rate=SR)
    out = []
    for s in segs:
        t = (s.text or "").strip()
        if t:
            out.append((float(s.start), float(s.end), t))
    return out
