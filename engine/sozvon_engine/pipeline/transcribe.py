"""Распознавание одной дорожки: Whisper с подсказкой и языком дорожки или onnx-модель."""
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .. import asr_onnx, langid, whisper
from ..i18n import t

Log = Callable[[str], None]


@dataclass
class Prompts:
    """Подсказки под язык: (полная с терминами, короткая страховочная)."""
    build: Callable[[str | None], tuple[str, str]]
    replacements: list


def whisper_track(wav: Path, model_path: str, language, prompts: Prompts, log: Log) -> list:
    """-> [(start, end, text)]."""
    prompt, fallback = prompts.build(language)
    segments, used = whisper.whisper_with_fallback(
        wav, model_path, language, prompt, fallback,
        # На раздельных дорожках много тишины (пока говорит другая сторона): word_timestamps и
        # hallucination_silence_threshold пропускают тишину вместо выдумывания текста и дают
        # точные границы для склейки дорожек.
        word_timestamps=True,
        hallucination_silence_threshold=2.0,
    )
    if used != prompt:
        log(t("log_prompt_retry"))
    return whisper.clean_segments(segments, prompts.replacements)


def retranscribe(chunk, model_path: str, language: str, prompts: Prompts) -> str:
    """Перераспознать короткий кусок с другим языком (смена языка посреди речи)."""
    res = whisper._transcribe(chunk, path_or_hf_repo=model_path, language=language,
                              initial_prompt=prompts.build(language)[0] or None,
                              condition_on_previous_text=False)
    return " ".join(whisper.clean_texts([x["text"] for x in res["segments"]], prompts.replacements))


def onnx_track(wav: Path, data_dir, model: str, replacements: list) -> list:
    """GigaAM / Parakeet: фразы по VAD, тот же фильтр шума и автозамены, что у Whisper."""
    out = []
    for s, e, text in asr_onnx.transcribe(data_dir, model, langid.load_audio(wav)):
        cleaned = whisper.clean_texts([text], replacements)
        if cleaned:
            out.append((s, e, cleaned[0]))
    return out


def transcribe_tracks(tracks: dict, *, data_dir, model: str, model_path: str | None, allowed,
                      switch: bool, prompts: Prompts, log: Log) -> tuple[dict, dict]:
    """Все дорожки. -> ({ключ: сегменты}, {ключ: язык дорожки})."""
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
        langs[key] = lang
        log(t("log_transcribing", track=key))
        segs[key] = whisper_track(wav, model_path, lang, prompts, log)
        log(t("log_segments", track=key, n=len(segs[key])))
        if switch and allowed and len(allowed) > 1:
            segs[key], n = langid.relabel(
                audio, segs[key], lang, allowed, det.probs,
                lambda chunk, lg: retranscribe(chunk, model_path, lg, prompts))
            log(t("log_switched", track=key, n=n))
    return segs, langs
