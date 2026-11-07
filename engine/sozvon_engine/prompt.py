"""Whisper prompt (initial_prompt) for a specific call.

The model has ~224 tokens of prompt context; it silently drops the excess and degrades near
the limit: at 196 tokens a short utterance turned into garbage "ru, c'f-5,2,0,0,0...".
Hence a 120-token budget and this priority: base, project, participants, call keywords,
then project people and terms and common terms, while they fit.
"""
PROMPT_MAX_TOKENS = 120

# A Russian base pulls Whisper toward Russian: other languages get their own base or none.
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
    """Whisper tokens (mlx-whisper multilingual tokenizer, without loading the model)."""
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
    """Short prompt without terms: the start of every prompt and the fallback retry."""
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
                continue  # skip a keyword that is too long, try the rest
            break
        seen.add(it.lower())
        picked.append(it)
    return (head + (f" {lb['terms']}: " + ", ".join(picked) + "." if picked else "")).strip()
