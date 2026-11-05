"""Разбивка по голосам (pyannote speaker-diarization-3.1).

Модели ставит установщик в <data>/hf-cache (токен Hugging Face не нужен); с HF_TOKEN их
можно скачать и самому. Пайплайн грузится один раз на процесс и только когда нужен: torch
тяжёлый. Голоса здесь безымянные: номер по порядку первого появления, имена и подписи
решает вызывающий код.
"""
from . import audio, config, paths

PIPELINE = "pyannote/speaker-diarization-3.1"
_pipeline = None


class DiarizationUnavailable(RuntimeError):
    pass


def available() -> bool:
    """Есть модели из установщика или свой токен Hugging Face."""
    return paths.engine_dir().pyannote_cache.is_dir() or bool(config.load().hf_token)


def load_pipeline():
    global _pipeline
    if _pipeline is not None:
        return _pipeline
    if not available():
        raise DiarizationUnavailable("нет моделей pyannote: переустанови движок или добавь HF_TOKEN")
    settings = config.load()
    import torch
    if settings.threads:
        torch.set_num_threads(settings.threads)
    from pyannote.audio import Pipeline
    pipeline = Pipeline.from_pretrained(PIPELINE, token=settings.hf_token or None)
    pipeline.to(torch.device("mps" if torch.backends.mps.is_available() else "cpu"))
    _pipeline = pipeline
    return pipeline


def load_waveform(path) -> dict:
    """Файл -> {"waveform", "sample_rate"} для pyannote.

    Декодирует наш ffmpeg: pyannote не трогает torchcodec (ему нужны shared-библиотеки ffmpeg),
    и на VBR-mp3 не плывёт счётчик семплов на границах чанков.
    """
    import torch
    x = audio.decode(path)
    return {"waveform": torch.from_numpy(x.copy()).unsqueeze(0), "sample_rate": audio.SR}


def run(path, num_speakers=None) -> list:
    """-> [(start, end, raw_label)] кто и когда говорил."""
    pipeline = load_pipeline()
    wave = load_waveform(path)
    output = pipeline(wave, num_speakers=num_speakers) if num_speakers else pipeline(wave)
    # pyannote>=4 оборачивает результат в DiarizeOutput, старые версии отдают Annotation.
    annotation = getattr(output, "speaker_diarization", output)
    return [(turn.start, turn.end, label) for turn, _, label in annotation.itertracks(yield_label=True)]


def best_label(start: float, end: float, diar: list):
    """Голос с наибольшим пересечением по времени; без пересечения тот, кто звучал в середине."""
    best, best_overlap = None, 0.0
    for d_start, d_end, label in diar:
        overlap = min(end, d_end) - max(start, d_start)
        if overlap > best_overlap:
            best_overlap, best = overlap, label
    if best is None:
        mid = (start + end) / 2
        for d_start, d_end, label in diar:
            if d_start <= mid <= d_end:
                return label
    return best


def assign(segs: list, diar: list) -> tuple[list, int]:
    """[(start, end, text)] -> ([(start, end, text, voice)], число голосов).

    voice: номер голоса с нуля по порядку первого появления в речи, или None (голос не найден).
    """
    order: dict = {}
    out = []
    for s, e, t in segs:
        label = best_label(s, e, diar)
        if label is not None and label not in order:
            order[label] = len(order)
        out.append((s, e, t, order.get(label) if label is not None else None))
    return out, len(order)
