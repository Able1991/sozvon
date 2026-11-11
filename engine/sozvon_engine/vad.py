"""Where a track has a voice: Silero VAD (the one onnx models already use), on the CPU.

Whisper writes text on a track without speech: a raised room tone or a fan becomes "Thank you." every half
minute. The energy detector in tracks.py hears speech there too (raised noise is loud), Silero hears none.
"""
from pathlib import Path

import numpy as np

from . import models
from .audio import SR, decode


def available(data_dir) -> bool:
    return data_dir is not None and models.is_complete(models.vad_dir(data_dir), models.VAD["files"])


def speech_spans(data_dir, wav: Path) -> list:
    """-> [(start, end)] in seconds where Silero hears a voice."""
    import onnx_asr
    detector = onnx_asr.load_vad("silero", path=models.vad_dir(data_dir), providers=["CPUExecutionProvider"])
    x = decode(Path(wav)).astype(np.float32)
    spans = next(iter(detector.segment_batch(x[None, :], np.array([len(x)]), SR)))
    return [(s / SR, e / SR) for s, e in spans]
