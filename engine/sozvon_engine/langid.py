"""Spoken language detection among allowed languages, and language switches mid-speech.

Whisper picks the language once per run. Here:
- detect_track: track language from the few most speech-heavy 30-second windows,
  among allowed languages only (ru+en will not be confused with Ukrainian or Bulgarian);
- relabel: per-segment language detection; if a segment is clearly in another
  allowed language, it is re-transcribed in that language.
"""
from pathlib import Path

import numpy as np

from . import audio as _audio
from . import platform_support

SR = _audio.SR
WIN = 30 * SR


def parse_languages(value: str):
    """'ru' -> ['ru']; 'ru,en' -> ['ru', 'en']; 'auto' or '' -> None (any)."""
    items = [x.strip().lower() for x in (value or "").split(",") if x.strip()]
    if not items or "auto" in items:
        return None
    return list(dict.fromkeys(items))


def load_audio(wav: Path) -> np.ndarray:
    return _audio.decode(wav)


def pick(probs: dict, allowed) -> tuple:
    """Best language among the allowed ones and its share among them. -> (lang, share)."""
    cands = {k: v for k, v in probs.items() if allowed is None or k in allowed}
    if not cands:
        return (allowed[0] if allowed else "en"), 0.0
    total = sum(cands.values()) or 1.0
    lang = max(cands, key=cands.get)
    return lang, cands[lang] / total


class Detector:
    """Lazy wrapper around the mlx-whisper model (the same one used for transcription)."""

    def __init__(self, model_path: str):
        self.repo = model_path
        self._model = None

    def model(self):
        if self._model is None:
            import mlx.core as mx
            from mlx_whisper.transcribe import ModelHolder
            self._model = ModelHolder.get_model(self.repo, mx.float16)
        return self._model

    def probs(self, chunk: np.ndarray) -> dict:
        if platform_support.SYSTEM == "win32":
            from . import whisper_ct2
            return whisper_ct2.language_probs(self.repo, chunk)
        import mlx.core as mx
        from mlx_whisper.audio import N_FRAMES, log_mel_spectrogram, pad_or_trim
        m = self.model()
        mel = log_mel_spectrogram(chunk, n_mels=m.dims.n_mels)
        mel = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)
        _, probs = m.detect_language(mel)
        return dict(probs[0] if isinstance(probs, list) else probs)


def speech_windows(audio: np.ndarray, n: int = 3) -> list:
    """Up to n non-overlapping 30-second windows with the highest energy."""
    if len(audio) <= WIN:
        return [audio]
    starts = range(0, len(audio) - WIN + 1, WIN)
    scored = sorted(starts, key=lambda s: float(np.mean(audio[s:s + WIN] ** 2)), reverse=True)
    return [audio[s:s + WIN] for s in scored[:n]]


def detect_track(audio: np.ndarray, allowed, probs_fn) -> tuple:
    """Track language: probabilities averaged over the most speech-heavy windows. -> (lang, share)."""
    acc: dict = {}
    for w in speech_windows(audio):
        for k, v in probs_fn(w).items():
            acc[k] = acc.get(k, 0.0) + v
    return pick(acc, allowed)


def relabel(audio: np.ndarray, segs: list, main: str, allowed, probs_fn, retranscribe,
            min_len: float = 1.2, threshold: float = 0.75) -> tuple:
    """Re-transcribe segments that are clearly in another allowed language.

    segs: [(start, end, text)]; retranscribe(chunk, lang) -> text.
    -> (new segments, number of segments switched to another language).
    """
    out, changed = [], 0
    for s, e, t in segs:
        if e - s < min_len or not allowed or len(allowed) < 2:
            out.append((s, e, t))
            continue
        a, b = max(0, int((s - 0.2) * SR)), min(len(audio), int((e + 0.2) * SR))
        chunk = audio[a:b]
        lang, share = pick(probs_fn(chunk), allowed)
        if lang != main and share >= threshold:
            text = (retranscribe(chunk, lang) or "").strip()
            if text:
                out.append((s, e, text))
                changed += 1
                continue
        out.append((s, e, t))
    return out, changed
