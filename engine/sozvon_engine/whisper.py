"""Распознавание Whisper (mlx-whisper) и единый фильтр сегментов.

Фильтр сегментов один на всех: им пользуются и расшифровка звонка, и MCP-инструмент
transcribe, и onnx-модели. mlx_whisper импортируется только при первом распознавании:
MCP-сервер не должен грузить сотни мегабайт, пока его не попросили расшифровать.
"""
import re
import zlib

# Типовые галлюцинации Whisper на тишине (обучен на субтитрах YouTube) и пустые строки.
NOISE = re.compile(
    r"(субтитр|продолжение следует|спасибо за просмотр|подписывайтесь|"
    r"dimatorzok|редактор|корректор|amara\.org|^\W*$)",
    re.I,
)


def is_hallucination(text: str) -> bool:
    """Зацикленные повторы на тишине («ерстиерсти...»): такой текст почти не сжимается.

    Порог консервативный, чтобы не резать нормальную речь.
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
    """Заменить ослышки по целым словам, без учёта регистра."""
    for pair in replacements:
        if not isinstance(pair, (list, tuple)) or len(pair) != 2:
            continue
        wrong, right = pair
        # \b плохо ловит границы рядом с дефисом и пробелом внутри фразы: свои границы.
        pattern = r"(?<!\w)" + re.escape(wrong) + r"(?!\w)"
        text = re.sub(pattern, lambda _m, r=right: r, text, flags=re.IGNORECASE | re.UNICODE)
    return text


def keep_segment(seg: dict) -> bool:
    if is_noise(seg.get("text", "")):
        return False
    # Модель сама уверена, что речи нет, и текст маловероятен.
    return not (seg.get("no_speech_prob", 0) > 0.8 and seg.get("avg_logprob", 0) < -1.0)


def clean_segments(segments: list, replacements: list) -> list:
    """Сегменты Whisper -> [(start, end, text)] без шума, с автозаменами.

    Границы по словам, если они есть (word_timestamps): точнее для склейки дорожек.
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
    """То же для голых текстов (onnx-модели, перераспознанные куски)."""
    return [apply_replacements(t.strip(), replacements) for t in texts if not is_noise(t)]


def _transcribe(audio, **kw) -> dict:
    """Точка подмены в тестах: настоящий вызов mlx_whisper.transcribe."""
    import mlx_whisper
    return mlx_whisper.transcribe(audio, **kw)


def ensure_backend() -> None:
    """Проверить, что mlx-whisper импортируется (иначе движок повреждён)."""
    import mlx_whisper  # noqa: F401


def whisper_with_fallback(audio, model_path: str, language, prompt: str, fallback_prompt: str = "", **kw):
    """Распознать с подсказкой и страховкой.

    Длинная подсказка из терминов иногда сбивает модель: вместо речи зацикленный мусор, фильтр
    его режет, и расшифровка пустая. Если так вышло (галлюцинации в трети сегментов или ни
    одного живого), повторяем с короткой подсказкой без терминов. -> (segments, used_prompt)
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
