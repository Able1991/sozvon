"""Whisper recognition (mlx-whisper) and the shared segment filter.

One segment filter for everything: call transcription, the transcribe MCP tool and onnx
models all use it. mlx_whisper is imported only on first recognition: the MCP server
must not load hundreds of megabytes until it is asked to transcribe.
"""
import re
import zlib

# Typical Whisper hallucinations on silence (trained on YouTube subtitles) and empty lines. Subtitle credits
# are matched as credits ("Редактор субтитров А.Синецкая", "Корректор А.Егорова"), so a real sentence about
# an editor stays.
NOISE = re.compile(
    r"(субтитр|продолжение следует|спасибо за просмотр|подписывайтесь на (?:наш )?канал|"
    r"dimatorzok|(?:редактор|корректор)\s+[А-ЯЁ]\.\s?[А-ЯЁ]|amara\.org|^\W*$)",
    re.I,
)


# A whole segment that only describes a sound, as subtitles do ("ДИНАМИЧНАЯ МУЗЫКА", "[музыка]", "(смех)",
# "♪♪", "[Music]"): Whisper writes these on pauses and noise, typically on a quiet track raised before recognition.
# Only the whole segment counts and only the nominative description, so "Включи музыку." or "Очень шумно." stays.
SOUND_TAG = re.compile(
    r"^[\s\W]*(?:[\[(]?\s*)?(?:[а-яёa-z]+\s+){0,2}"
    r"(музыка|music|аплодисменты|applause|смех|laughter|laughs|тишина|silence|шум|шумы|noise|"
    r"звонок телефона|гудки|ringing|beeps?|beeping)"
    r"(?:\s*[\])])?[\s\W]*$",
    re.I,
)


# The same sound descriptions inside a segment, as subtitles write them: in capitals ("ДИНАМИЧНАЯ МУЗЫКА",
# repeated) or in brackets ("[музыка]", "(смех)"). Lowercase words in a sentence ("включи музыку") stay.
_TAG_WORDS = r"(?:МУЗЫК[А-ЯЁ]*|MUSIC|АПЛОДИСМЕНТ[А-ЯЁ]*|APPLAUSE|СМЕХ|LAUGHTER)"
_INLINE_TAG = re.compile(
    r"(?:\b(?:[А-ЯЁA-Z]{2,}\s+){0,2}" + _TAG_WORDS + r"\b[.!]?"
    r"|[\[(][^\])]{0,40}?(?i:музык|music|аплодисмент|applause|смех|laughter)[^\])]{0,40}[\])])"
)


def strip_sound_tags(text: str) -> str:
    """Remove subtitle sound descriptions from a segment's text; the rest of the speech stays."""
    return re.sub(r"\s{2,}", " ", _INLINE_TAG.sub(" ", text)).strip()


def is_sound_tag(text: str) -> bool:
    t = text.strip()
    if not t:
        return False
    if all(not c.isalnum() for c in t):  # "♪♪", "..."
        return True
    return bool(SOUND_TAG.match(t))


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
    return not t or is_hallucination(t) or is_sound_tag(t) or bool(NOISE.search(t))


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
    if is_noise(strip_sound_tags(seg.get("text", ""))):
        return False
    # The model itself is confident there is no speech, and the text is unlikely.
    return not (seg.get("no_speech_prob", 0) > 0.8 and seg.get("avg_logprob", 0) < -1.0)


SENTENCE_END = (".", "!", "?", "…")
PAUSE = 1.0  # seconds between words that end a piece even without punctuation


def sentences(seg: dict) -> list:
    """A Whisper segment -> [(start, end, text)] by sentence (and by a pause between words), from its word
    timestamps. One segment often holds the end of one person's phrase and the start of the next person's:
    split, each piece gets its own voice from diarization. Without usable words: the segment as one piece."""
    words = seg.get("words") or []
    if not words or not all(isinstance(w.get("word"), str) and "start" in w and "end" in w for w in words):
        # The outer words' times when they have them, otherwise the segment's (a word may lack "start").
        start = words[0].get("start", seg["start"]) if words else seg["start"]
        end = words[-1].get("end", seg["end"]) if words else seg["end"]
        return [(start, end, seg.get("text", ""))]
    pieces, cur = [], []
    for w in words:
        if cur and (w["start"] - cur[-1]["end"] > PAUSE or cur[-1]["word"].strip().endswith(SENTENCE_END)):
            pieces.append(cur)
            cur = []
        cur.append(w)
    pieces.append(cur)
    return [(p[0]["start"], p[-1]["end"], "".join(w["word"] for w in p)) for p in pieces]


def clean_segments(segments: list, replacements: list) -> list:
    """Whisper segments -> [(start, end, text)] by sentence, without noise, with replacements.

    Word boundaries when available (word_timestamps): more precise for merging the tracks and for
    telling the voices apart.
    """
    out = []
    for seg in segments:
        if not keep_segment(seg):
            continue
        for start, end, text in sentences(seg):
            text = strip_sound_tags(text)
            if not is_noise(text):
                out.append((start, end, apply_replacements(text, replacements)))
    return out


def clean_texts(texts, replacements: list) -> list:
    """Same for plain texts (onnx models, re-recognized chunks)."""
    texts = [strip_sound_tags(t) for t in texts]
    return [apply_replacements(t, replacements) for t in texts if not is_noise(t)]


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
