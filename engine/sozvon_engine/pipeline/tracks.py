"""Дорожки звонка: wav, есть ли речь, где пропал системный звук, эхо собеседника в микрофоне.

mic.m4a всегда «я», system.m4a всегда собеседники: кто есть кто известно без угадывания.
Грабля «колонки вместо наушников»: микрофон слышит собеседника из динамиков, и его фраза
попадает в расшифровку дважды. Такие сегменты микрофона выкидываются (drop_echo).
"""
import difflib
import re
from pathlib import Path

import numpy as np

from .. import audio
from ..i18n import t

TRACKS = (("mic", "mic.m4a"), ("system", "system.m4a"))
MIN_FILE_BYTES = 1024


def track_files(d: Path) -> dict:
    """{ключ: файл} дорожек, которые вообще записались."""
    out = {}
    for key, name in TRACKS:
        f = Path(d) / name
        if f.exists() and f.stat().st_size >= MIN_FILE_BYTES:
            out[key] = f
    return out


def delays(meta: dict) -> dict:
    """Сдвиг начала каждой дорожки относительно самой ранней (по общим часам записи)."""
    starts = {k: float(meta[f"{k}_start"]) for k, _ in TRACKS
              if isinstance(meta.get(f"{k}_start"), (int, float))}
    t0 = min(starts.values(), default=0.0)
    return {k: starts.get(k, t0) - t0 for k, _ in TRACKS}


def active_seconds(wav: Path) -> float:
    """Сколько секунд в дорожке реально есть звук (грубый энергетический VAD, кадры по 30 мс)."""
    x = audio.decode(wav)
    frame = 480
    n = len(x) // frame
    if n == 0:
        return 0.0
    rms = np.sqrt((x[: n * frame].reshape(n, frame) ** 2).mean(axis=1))
    return float((rms > 0.01).sum() * 0.03)


def dead_spans(wav: Path, min_len: float = 60.0) -> list:
    """Куски цифровой тишины (захват звука отвалился) длиннее min_len. -> [(start, end)]."""
    x = audio.decode(wav)
    frame = 1600  # 0,1 с
    n = len(x) // frame
    if n == 0:
        return []
    dead = np.abs(x[: n * frame].reshape(n, frame)).max(axis=1) < 1e-4
    spans, start = [], None
    for i, flag in enumerate(list(dead) + [False]):
        if flag and start is None:
            start = i
        elif not flag and start is not None:
            if (i - start) * 0.1 >= min_len:
                spans.append((start * 0.1, i * 0.1))
            start = None
    return spans


def split_dead(mic: list, spans: list) -> tuple[list, list]:
    """Разделить реплики микрофона: вне пропусков системного звука и внутри них."""
    def inside(s, e):
        return any(ds - 1 <= s and e <= de + 1 for ds, de in spans)
    return [x for x in mic if not inside(x[0], x[1])], [x for x in mic if inside(x[0], x[1])]


def _norm(text: str) -> str:
    return re.sub(r"[^\w]+", " ", text.lower()).strip()


def drop_echo(mic: list, system: list, window: float = 3.0, thr: float = 0.6) -> tuple[list, int]:
    """Убрать из микрофона фразы собеседника, услышанные из динамиков. -> (оставшиеся, выкинуто)."""
    kept, dropped = [], 0
    for s, e, text in mic:
        near = " ".join(_norm(tt) for ss, ee, tt in system if ee >= s - window and ss <= e + window)
        a = _norm(text)
        if a and near:
            sm = difflib.SequenceMatcher(None, a, near, autojunk=False)
            if sum(b.size for b in sm.get_matching_blocks()) / len(a) >= thr:
                dropped += 1
                continue
        kept.append((s, e, text))
    return kept, dropped


def prepare(files: dict, offsets: dict, d: Path, log) -> dict:
    """Дорожки -> wav в папке звонка; дорожки без речи отбрасываются. -> {ключ: wav}."""
    out = {}
    for key, src in files.items():
        wav = audio.to_wav(src, Path(d) / f"{key}.wav", offsets.get(key, 0.0))
        act = active_seconds(wav)
        log(t("log_track_speech", file=src.name, sec=act))
        if act >= 1.0:
            out[key] = wav
        else:
            wav.unlink(missing_ok=True)
    return out


def cleanup(d: Path) -> None:
    for key, _ in TRACKS:
        (Path(d) / f"{key}.wav").unlink(missing_ok=True)
