"""Recognition of one track: Whisper with the track's prompt and language, or an onnx model."""
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .. import asr_onnx, langid, vad, whisper
from ..i18n import t

Log = Callable[[str], None]


@dataclass
class Prompts:
    """Language-specific prompts: (full with terms, short fallback)."""
    build: Callable[[str | None], tuple[str, str]]
    replacements: list


def whisper_track(wav: Path, model_path: str, language, prompts: Prompts, log: Log) -> list:
    """-> [(start, end, text)]."""
    prompt, fallback = prompts.build(language)
    segments, used = whisper.whisper_with_fallback(
        wav, model_path, language, prompt, fallback,
        # Separate tracks contain a lot of silence (while the other side talks): word_timestamps and
        # hallucination_silence_threshold skip silence instead of inventing text and give
        # precise boundaries for merging the tracks.
        word_timestamps=True,
        hallucination_silence_threshold=2.0,
    )
    if used != prompt:
        log(t("log_prompt_retry"))
    return whisper.clean_segments(segments, prompts.replacements)


# Word times and the detector's edges disagree by a few tenths of a second: a line this close to a voice is speech.
HEARD_PAD = 0.5


def drop_unheard(pieces: list, spans: list) -> tuple[list, int]:
    """Lines with no voice under them (Whisper on silence) go. -> (kept, dropped)."""
    kept = [p for p in pieces
            if any(p[0] < e + HEARD_PAD and p[1] > s - HEARD_PAD for s, e in spans)]
    return kept, len(pieces) - len(kept)


def retranscribe(chunk, model_path: str, language: str, prompts: Prompts) -> str:
    """Re-recognize a short chunk with another language (language switch mid-speech)."""
    res = whisper._transcribe(chunk, path_or_hf_repo=model_path, language=language,
                              initial_prompt=prompts.build(language)[0] or None,
                              condition_on_previous_text=False)
    return " ".join(whisper.clean_texts([x["text"] for x in res["segments"]], prompts.replacements))


def onnx_track(wav: Path, data_dir, model: str, replacements: list) -> list:
    """GigaAM / Parakeet: phrases by VAD, the same noise filter and replacements as Whisper."""
    out = []
    for s, e, text in asr_onnx.transcribe(data_dir, model, langid.load_audio(wav)):
        cleaned = whisper.clean_texts([text], replacements)
        if cleaned:
            out.append((s, e, cleaned[0]))
    return out


def transcribe_tracks(tracks: dict, *, data_dir, model: str, model_path: str | None, allowed,
                      switch: bool, prompts: Prompts, log: Log, ru_model: str | None = None) -> tuple[dict, dict]:
    """All tracks. -> ({key: segments}, {key: track language}). ru_model: Russian tracks go to it (an onnx model),
    the others stay on Whisper."""
    segs, langs = {}, {}
    if asr_onnx.is_onnx(model):
        log(t("log_onnx_no_prompt", model=model))
        if model == "gigaam" and allowed and any(lang != "ru" for lang in allowed):
            log(t("log_gigaam_ru_only"))
        for key, wav in tracks.items():
            log(t("log_transcribing_model", track=key, model=model))
            segs[key] = onnx_track(wav, data_dir, model, prompts.replacements)
            log(t("log_segments", track=key, n=len(segs[key])))
        return segs, langs

    det = langid.Detector(model_path)
    for key, wav in tracks.items():
        audio = None
        if allowed and len(allowed) == 1:
            lang = allowed[0]
        else:
            audio = langid.load_audio(wav)
            lang, share = langid.detect_track(audio, allowed, det.probs)
            log(t("log_track_lang", track=key, lang=lang, share=share,
                  allowed=",".join(allowed) if allowed else t("all_languages")))
            if not (switch and allowed and len(allowed) > 1):
                audio = None   # only relabel needs it again; Whisper decodes the file itself
        langs[key] = lang
        if ru_model and lang == "ru":
            log(t("log_transcribing_model", track=key, model=ru_model))
            segs[key] = onnx_track(wav, data_dir, ru_model, prompts.replacements)
            log(t("log_segments", track=key, n=len(segs[key])))
            continue
        log(t("log_transcribing", track=key))
        segs[key] = whisper_track(wav, model_path, lang, prompts, log)
        if vad.available(data_dir):
            segs[key], dropped = drop_unheard(segs[key], vad.speech_spans(data_dir, wav))
            if dropped:
                log(t("log_unheard", track=key, n=dropped))
        log(t("log_segments", track=key, n=len(segs[key])))
        if switch and allowed and len(allowed) > 1:
            segs[key], n = langid.relabel(
                audio, segs[key], lang, allowed, det.probs,
                lambda chunk, lg: retranscribe(chunk, model_path, lg, prompts))
            log(t("log_switched", track=key, n=n))
    return segs, langs
