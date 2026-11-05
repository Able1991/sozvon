"""Подсказка Whisper (initial_prompt) под конкретный звонок.

У модели ~224 токена контекста подсказки, лишнее она молча отбрасывает, а у края
деградирует: на 196 токенах короткая реплика превратилась в мусор "ru, c'f-5,2,0,0,0...".
Поэтому бюджет 120 токенов и приоритет: база, проект, собеседники, ключевые слова звонка,
затем люди и термины проекта и общие термины, пока влезает.
"""
PROMPT_MAX_TOKENS = 120

# Русская база тянет Whisper в русский: для других языков своя база или пустая.
RU_BASE_PREFIX = "Деловой созвон на русском"
BASE_PROMPTS = {
    "en": "A business call in English.",
    "uk": "Діловий дзвінок українською мовою.",
    "de": "Ein Geschäftsgespräch auf Deutsch.",
    "es": "Una llamada de negocios en español.",
}
LABELS = {
    "ru": {"project": "Проект", "people": "Участники", "terms": "Термины"},
    "en": {"project": "Project", "people": "Participants", "terms": "Terms"},
}

_tokenizer = None


def count_tokens(text: str) -> int:
    """Токены Whisper (мультиязычный токенизатор mlx-whisper, без загрузки модели)."""
    global _tokenizer
    if _tokenizer is None:
        from mlx_whisper.tokenizer import get_tokenizer
        _tokenizer = get_tokenizer(multilingual=True, num_languages=100, language="ru", task="transcribe")
    return len(_tokenizer.encode(" " + text))


def vocab_for_language(vocab: dict, lang) -> dict:
    if lang != "ru" and (vocab.get("initial_prompt") or "").startswith(RU_BASE_PREFIX):
        return {**vocab, "initial_prompt": BASE_PROMPTS.get(lang or "", "")}
    return vocab


def _labels(lang) -> dict:
    return LABELS["ru" if lang in (None, "ru") else "en"]


def base_prompt(vocab: dict, prof: dict, names=(), lang="ru") -> str:
    """Короткая подсказка без терминов: начало любой подсказки и страховочный повтор."""
    lb = _labels(lang)
    head = (vocab.get("initial_prompt") or "").strip()
    if prof.get("title"):
        head += f" {lb['project']}: {prof['title']}."
    if names:
        head += f" {lb['people']}: " + ", ".join(names) + "."
    return head.strip()


def split_keywords(keywords: str) -> list:
    return [k.strip() for k in (keywords or "").replace(";", ",").split(",") if k.strip()]


def build_prompt(vocab: dict, prof: dict, names=(), keywords: str = "", lang="ru",
                 max_tokens: int = PROMPT_MAX_TOKENS, count=None) -> str:
    count = count or count_tokens
    lb = _labels(lang)
    head = base_prompt(vocab, prof, names, lang)
    kw = split_keywords(keywords)
    items = kw + [x for x in prof.get("people", []) if x not in names] + list(prof.get("terms", []))
    items += list(vocab.get("terms", []))
    seen, picked = set(), []
    for it in items:
        if not isinstance(it, str) or not it.strip() or it.lower() in seen:
            continue
        cand = f"{head} {lb['terms']}: " + ", ".join(picked + [it]) + "."
        if count(cand) > max_tokens:
            if it in kw:
                continue  # слишком длинное ключевое слово пропускаем, остальные пробуем
            break
        seen.add(it.lower())
        picked.append(it)
    return (head + (f" {lb['terms']}: " + ", ".join(picked) + "." if picked else "")).strip()
