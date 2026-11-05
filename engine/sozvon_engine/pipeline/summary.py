"""Саммари звонка через помощника (Claude Code или Codex CLI, подписка пользователя).

Текст расшифровки уходит в облако выбранного помощника. Саммари пишется на языке разговора,
без языка разговора на языке приложения.
"""
from pathlib import Path
from typing import Callable

from .. import i18n, llm
from ..i18n import t

PROMPT_RU = """Ниже расшифровка звонка (локальная транскрибация Whisper, возможны ослышки).
Я в звонке: {me}.{context}
Сделай краткое саммари на русском в Markdown, строго такими разделами:

## Коротко
2-4 предложения: о чём звонок и чем закончился.

## Решения
Маркированный список принятых решений. Нет решений: «не зафиксированы».

## Задачи
Чек-лист «- [ ] кто: что, срок». Срок только если прозвучал.

## Открытые вопросы
Что осталось нерешённым или требует уточнения. Нет: раздел не выводи.

Правила: не выдумывай, только то, что есть в тексте. Цифры, суммы, даты, названия переноси точно.
Не используй длинное тире (символы \u2014 и \u2013): вместо него запятая, двоеточие или точка.
Не пиши вступлений и заключений, сразу разделы.

Расшифровка:
{transcript}"""

PROMPT_EN = """Below is a call transcript (local Whisper transcription, may contain mishearings).
I am on the call as: {me}.{context}
Write a short summary in {language} in Markdown, with exactly these sections:

## Summary
2-4 sentences: what the call was about and how it ended.

## Decisions
Bulleted list of decisions made. If none: "none recorded".

## Action Items
Checklist "- [ ] who: what, due date". Due date only if it was mentioned.

## Open Questions
What remains unresolved or needs clarification. If nothing: omit this section.

Rules: do not invent anything, only what is in the text. Copy numbers, amounts, dates and names exactly.
Do not use em or en dashes (\u2014, \u2013): use a comma, colon or period instead.
No intro or outro, start with the sections.

Transcript:
{transcript}"""

LANG_NAMES = {"ru": "Russian", "en": "English", "uk": "Ukrainian", "de": "German", "es": "Spanish",
              "fr": "French", "it": "Italian", "pt": "Portuguese", "pl": "Polish"}
EM, EN = "\u2014", "\u2013"


def build_prompt(transcript: str, me: str, context: str = "", lang: str | None = None) -> str:
    lang = lang or i18n.lang()
    if lang == "ru":
        label = "Контекст (для понимания, не пересказывай его)"
        return PROMPT_RU.format(me=me, transcript=transcript, context=f"\n{label}: {context}" if context else "")
    label = "Context (for understanding, do not retell it)"
    return PROMPT_EN.format(me=me, transcript=transcript, context=f"\n{label}: {context}" if context else "",
                            language=LANG_NAMES.get(lang, "the language of the conversation"))


def strip_dashes(text: str) -> str:
    return text.replace(f" {EM} ", ", ").replace(f" {EN} ", ", ").replace(EM, ", ").replace(EN, "-")


def context_for(prof: dict, topic: str, terms: str) -> str:
    parts = [prof.get("context", ""), f"{t('topic')}: {topic}." if topic else "",
             f"{t('keywords')}: {terms}." if terms else ""]
    return " ".join(p for p in parts if p)


def summarize(transcript: str, me: str, cwd: Path, context: str = "", lang: str | None = None,
              log: Callable[[str], None] = lambda _m: None) -> str | None:
    out, name, err = llm.run(build_prompt(transcript, me, context, lang), cwd)
    if not out:
        log(t("log_summary_failed", who=name or t("no_cli"), err=err))
        return None
    log(t("log_summary_ok", name=name, vendor=llm.vendor(name)))
    return strip_dashes(out)
