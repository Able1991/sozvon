"""Whisper recognition (mlx-whisper) and the shared segment filter.

One segment filter for everything: call transcription, the transcribe MCP tool and onnx
models all use it. mlx_whisper is imported only on first recognition: the MCP server
must not load hundreds of megabytes until it is asked to transcribe.
"""
import re
import zlib

# Typical Whisper hallucinations on silence (trained on YouTube subtitles) and empty lines.
NOISE = re.compile(
    r"(субтитр|продолжение следует|спасибо за просмотр|подписывайтесь|"
    r"dimatorzok|редактор|корректор|amara\.org|^\W*$)",
    re.I,
)


def is_hallucination(text: str) -> bool:
    """Looping repetitions on silence ("ерстиерсти..."): such text barely compresses.

    The threshold is conservative so normal speech is not cut.
    """
    t = text.strip()
    if len(t) < 50:
        return False
    raw = t.encode("utf-8")
    return len(zlib.compress(raw)) / len(raw) < 0.20


def is_noise(text: str) -> bool:
    t = text.strip()
    return not t or is_hallucination(t) or bool(NOISE.search(t))


def apply_replacements(text: str, replacements: list) -> str:
    """Replace mishearings by whole words, case-insensitive."""
    for pair in replacements:
        if not isinstance(pair, (list, tuple)) or len(pair) != 2:
            continue
        wrong, right = pair
        # \b handles boundaries poorly next to a hyphen or a space inside a phrase: custom boundaries.
        pattern = r"(?<!\w)" + re.escape(wrong) + r"(?!\w)"
        text = re.sub(pattern, lambda _m, r=right: r, text, flags=re.IGNORECASE | re.UNICODE)
    return text


def keep_segment(seg: dict) -> bool:
    if is_noise(seg.get("text", "")):
        return False
    # The model itself is confident there is no speech, and the text is unlikely.
    return not (seg.get("no_speech_prob", 0) > 0.8 and seg.get("avg_logprob", 0) < -1.0)


def clean_segments(segments: list, replacements: list) -> list:
    """Whisper segments -> [(start, end, text)] without noise, with replacements.

    Word boundaries when available (word_timestamps): more precise for merging tracks.
    """
    out = []
    for seg in segments:
        if not keep_segment(seg):
            continue
        words = seg.get("words") or []
        start = words[0]["start"] if words else seg["start"]
        end = words[-1]["end"] if words else seg["end"]
        out.append((start, end, apply_replacements(seg["text"].strip(), replacements)))
    return out


def clean_texts(texts, replacements: list) -> list:
    """Same for plain texts (onnx models, re-recognized chunks)."""
    return [apply_replacements(t.strip(), replacements) for t in texts if not is_noise(t)]


def _transcribe(audio, **kw) -> dict:
    """Test seam: the real mlx_whisper.transcribe call."""
    import mlx_whisper
    return mlx_whisper.transcribe(audio, **kw)


def ensure_backend() -> None:
    """Check that mlx-whisper imports (otherwise the engine is broken)."""
    import mlx_whisper  # noqa: F401


def whisper_with_fallback(audio, model_path: str, language, prompt: str, fallback_prompt: str = "", **kw):
    """Recognize with a prompt and a fallback.

    A long prompt of terms sometimes derails the model: looping garbage instead of speech, the
    filter cuts it, and the transcript is empty. If that happens (hallucinations in a third of the
    segments or no real ones), retry with a short prompt without terms. -> (segments, used_prompt)
    """
    src = audio if hasattr(audio, "shape") else str(audio)
    res = _transcribe(src, path_or_hf_repo=model_path, language=language, initial_prompt=prompt or None, **kw)
    segs = res["segments"]
    texts = [x["text"].strip() for x in segs]
    bad = sum(1 for t in texts if t and is_hallucination(t))
    good = sum(len(t) for t in texts if t and not is_hallucination(t))
    if prompt and prompt != fallback_prompt and bad and (bad * 3 >= len(segs) or good == 0):
        res = _transcribe(src, path_or_hf_repo=model_path, language=language,
                          initial_prompt=fallback_prompt or None, **kw)
        return res["segments"], fallback_prompt
    return segs, prompt
