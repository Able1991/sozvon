"""Speaker diarization (pyannote speaker-diarization-3.1).

The installer puts the models in <data>/hf-cache (no Hugging Face token needed); with HF_TOKEN
you can download them yourself. The pipeline loads once per process and only when needed: torch
is heavy. Voices here are anonymous: numbered by order of first appearance, names and labels
are up to the caller.
"""
from . import accel, audio, config, paths

PIPELINE = "pyannote/speaker-diarization-3.1"
_pipeline = None
_pipeline_device = None


class DiarizationUnavailable(RuntimeError):
    pass


def available() -> bool:
    """Installer models are present or a Hugging Face token is set."""
    return paths.engine_dir().pyannote_cache.is_dir() or bool(config.load().hf_token)


def load_pipeline():
    global _pipeline, _pipeline_device
    if _pipeline is not None and _pipeline_device == accel.torch_device("diarize"):
        return _pipeline
    if not available():
        raise DiarizationUnavailable("нет моделей pyannote: переустанови движок")
    settings = config.load()
    import torch
    if settings.threads:
        torch.set_num_threads(settings.threads)
    from pyannote.audio import Pipeline
    pipeline = Pipeline.from_pretrained(PIPELINE, token=settings.hf_token or None)
    _pipeline_device = accel.torch_device("diarize")
    pipeline.to(torch.device(_pipeline_device))
    _pipeline = pipeline
    return pipeline


def load_waveform(path) -> dict:
    """File -> {"waveform", "sample_rate"} for pyannote.

    Decoded by our ffmpeg: pyannote never touches torchcodec (it needs ffmpeg shared libraries),
    and the sample count does not drift at chunk boundaries on VBR mp3.
    """
    import torch
    x = audio.decode(path)
    return {"waveform": torch.from_numpy(x.copy()).unsqueeze(0), "sample_rate": audio.SR}


def run(path, num_speakers=None) -> list:
    """-> [(start, end, raw_label)] who spoke when."""
    wave = load_waveform(path)

    def work():
        pipeline = load_pipeline()
        return pipeline(wave, num_speakers=num_speakers) if num_speakers else pipeline(wave)

    output = accel.with_cpu_fallback("diarize", work)
    # pyannote>=4 wraps the result in DiarizeOutput, older versions return an Annotation.
    annotation = getattr(output, "speaker_diarization", output)
    return [(turn.start, turn.end, label) for turn, _, label in annotation.itertracks(yield_label=True)]


NEAR = 2.0  # seconds: a segment this close to a voice's turn (and overlapping none) is that voice's


def best_label(start: float, end: float, diar: list):
    """Voice with the largest time overlap; with no overlap, the one speaking at the midpoint, else the one
    whose turn is nearest within NEAR seconds (Whisper's word times often end a phrase just after the turn):
    otherwise a phrase tail would become a separate unnamed speaker."""
    best, best_overlap = None, 0.0
    for d_start, d_end, label in diar:
        overlap = min(end, d_end) - max(start, d_start)
        if overlap > best_overlap:
            best_overlap, best = overlap, label
    if best is not None:
        return best
    mid = (start + end) / 2
    for d_start, d_end, label in diar:
        if d_start <= mid <= d_end:
            return label
    gap, near = min(((max(d_start - end, start - d_end), label) for d_start, d_end, label in diar),
                    default=(None, None), key=lambda x: x[0])
    return near if gap is not None and gap <= NEAR else None


def assign(segs: list, diar: list) -> tuple[list, int]:
    """[(start, end, text)] -> ([(start, end, text, voice)], number of voices).

    voice: zero-based voice number by order of first appearance, or None (no voice found).
    """
    out, order = assign_order(segs, diar)
    return out, len(order)


def assign_order(segs: list, diar: list) -> tuple[list, dict]:
    """Like assign, plus {raw label: voice number}."""
    order: dict = {}
    out = []
    for s, e, t in segs:
        label = best_label(s, e, diar)
        if label is not None and label not in order:
            order[label] = len(order)
        out.append((s, e, t, order.get(label) if label is not None else None))
    return out, order
