"""Whisper recognition (mlx-whisper) and the shared segment filter.

One segment filter for everything: call transcription, the transcribe MCP tool and onnx
models all use it. mlx_whisper is imported only on first recognition: the MCP server
must not load hundreds of megabytes until it is asked to transcribe.
"""
import re
import zlib

from . import platform_support

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


# MLX keeps freed buffers for reuse and by default never gives them back: after Whisper on a 75-minute
# track the process held 9.7 GB of cache next to a 1.5 GB model, until the end of the call. A small cache
# keeps reuse for the decoding loop; what is left is cleared after each track.
MLX_CACHE_LIMIT = 512 * 2**20
MEL_FRAMES = 6000          # one minute of audio per piece of the spectrogram


def log_mel(audio, n_mels: int = 80, padding: int = 0):
    """mlx_whisper.audio.log_mel_spectrogram, the same values, built a minute at a time.

    The library transforms the whole track in one expression: every 10 ms frame laid out as 400 samples, its
    spectrum, the magnitudes and the mel bands are all alive at once, about 12 times the audio (3.5 GB for a
    75-minute track, at the start of every transcription). Only the result has to be whole.
    """
    import mlx.core as mx
    from mlx_whisper import audio as wa
    if isinstance(audio, str):
        audio = wa.load_audio(audio)
    elif not isinstance(audio, mx.array):
        audio = mx.array(audio)
    if padding > 0:
        audio = mx.pad(audio, (0, padding))
    half = wa.N_FFT // 2
    x = mx.concatenate([audio[1:half + 1][::-1], audio, audio[-(half + 1):-1][::-1]])   # reflect, as the library pads
    mx.eval(x)
    del audio
    frames = (x.size - wa.N_FFT + wa.HOP_LENGTH) // wa.HOP_LENGTH - 1                    # the library drops the last
    window, filters = wa.hanning(wa.N_FFT), wa.mel_filters(n_mels)
    pieces = []
    for a in range(0, frames, MEL_FRAMES):
        n = min(MEL_FRAMES, frames - a)
        piece = x[a * wa.HOP_LENGTH:(a + n - 1) * wa.HOP_LENGTH + wa.N_FFT]
        piece = mx.as_strided(piece, shape=[n, wa.N_FFT], strides=[wa.HOP_LENGTH, 1])
        piece = mx.maximum(mx.fft.rfft(piece * window).abs().square() @ filters.T, 1e-10).log10()
        mx.eval(piece)
        pieces.append(piece)
    del x
    spec = mx.concatenate(pieces) if pieces else mx.zeros((0, n_mels))
    del pieces
    spec = (mx.maximum(spec, spec.max() - 8.0) + 4.0) / 4.0
    mx.eval(spec)
    return spec


SEED = 0


def _transcribe(audio, **kw) -> dict:
    """Test seam: the real mlx_whisper.transcribe call, with the MLX cache kept small and cleared after
    (faster-whisper on Windows, which keeps no cache of its own)."""
    if platform_support.SYSTEM == "win32":
        from . import whisper_ct2
        return whisper_ct2.transcribe(audio, **kw)
    import sys

    import mlx.core as mx
    import mlx_whisper
    mx.set_cache_limit(MLX_CACHE_LIMIT)
    # An unsure piece is decoded again with random sampling: a fixed seed makes reprocessing a call give the
    # same text (the quality does not change, only which of the guesses is taken).
    mx.random.seed(SEED)
    # mlx_whisper.transcribe is the function; the module of that name holds the spectrogram it calls.
    sys.modules["mlx_whisper.transcribe"].log_mel_spectrogram = log_mel
    try:
        return mlx_whisper.transcribe(audio, **kw)
    finally:
        mx.clear_cache()


def release_model() -> None:
    """Drop the Whisper model mlx-whisper keeps for the next call (1.5 GB): the rest of a call (diarization,
    voice prints) does not need it, and a later transcription loads it again in a second or two.
    On Windows the faster-whisper models, and the card's memory with them; the device choice stays."""
    if platform_support.SYSTEM == "win32":
        from . import whisper_ct2
        whisper_ct2.release()
        return
    import gc
    import sys
    mod = sys.modules.get("mlx_whisper.transcribe")
    if mod is None:                      # Whisper was never loaded in this process
        return
    try:
        mod.ModelHolder.model = None
        mod.ModelHolder.model_path = None
        gc.collect()
        import mlx.core as mx
        mx.clear_cache()
    except Exception:  # noqa: BLE001 - memory only: never fail the call over it
        pass


def ensure_backend() -> None:
    """Check that mlx-whisper imports (otherwise the engine is broken)."""
    if platform_support.SYSTEM == "win32":
        from . import whisper_ct2
        whisper_ct2.ensure_backend()
        return
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
