"""Определение языка речи среди разрешённых и смена языка посреди речи.

Whisper выбирает язык один раз на запуск. Здесь:
- detect_track: язык дорожки по нескольким самым «речевым» 30-секундным окнам,
  только среди разрешённых (ru+en не спутается с украинским или болгарским);
- relabel: для каждой фразы своё определение языка; если фраза явно на другом
  разрешённом языке, она перераспознаётся с этим языком.
"""
from pathlib import Path

import numpy as np

from . import audio as _audio

SR = _audio.SR
WIN = 30 * SR


def parse_languages(value: str):
    """'ru' -> ['ru']; 'ru,en' -> ['ru', 'en']; 'auto' или '' -> None (любой)."""
    items = [x.strip().lower() for x in (value or "").split(",") if x.strip()]
    if not items or "auto" in items:
        return None
    return list(dict.fromkeys(items))


def load_audio(wav: Path) -> np.ndarray:
    return _audio.decode(wav)


def pick(probs: dict, allowed) -> tuple:
    """Лучший язык среди разрешённых и его доля среди них. -> (lang, share)."""
    cands = {k: v for k, v in probs.items() if allowed is None or k in allowed}
    if not cands:
        return (allowed[0] if allowed else "en"), 0.0
    total = sum(cands.values()) or 1.0
    lang = max(cands, key=cands.get)
    return lang, cands[lang] / total


class Detector:
    """Ленивая обёртка над моделью mlx-whisper (та же, что для расшифровки)."""

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
        import mlx.core as mx
        from mlx_whisper.audio import N_FRAMES, log_mel_spectrogram, pad_or_trim
        m = self.model()
        mel = log_mel_spectrogram(chunk, n_mels=m.dims.n_mels)
        mel = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)
        _, probs = m.detect_language(mel)
        return dict(probs[0] if isinstance(probs, list) else probs)


def speech_windows(audio: np.ndarray, n: int = 3) -> list:
    """До n непересекающихся 30-секундных окон с наибольшей энергией."""
    if len(audio) <= WIN:
        return [audio]
    starts = range(0, len(audio) - WIN + 1, WIN)
    scored = sorted(starts, key=lambda s: float(np.mean(audio[s:s + WIN] ** 2)), reverse=True)
    return [audio[s:s + WIN] for s in scored[:n]]


def detect_track(audio: np.ndarray, allowed, probs_fn) -> tuple:
    """Язык дорожки: усредняем вероятности по самым речевым окнам. -> (lang, share)."""
    acc: dict = {}
    for w in speech_windows(audio):
        for k, v in probs_fn(w).items():
            acc[k] = acc.get(k, 0.0) + v
    return pick(acc, allowed)


def relabel(audio: np.ndarray, segs: list, main: str, allowed, probs_fn, retranscribe,
            min_len: float = 1.2, threshold: float = 0.75) -> tuple:
    """Перераспознать фразы, которые явно на другом разрешённом языке.

    segs: [(start, end, text)]; retranscribe(chunk, lang) -> текст.
    -> (новые сегменты, сколько фраз переведено на другой язык).
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
