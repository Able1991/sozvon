"""Call summary via the assistant (Claude Code, Codex CLI or Cursor CLI, the user's subscription).

The transcript text goes to the chosen assistant's cloud. The summary is written in the
conversation language, or in the app language when the conversation language is unknown.
"""
from pathlib import Path
from typing import Callable

from .. import i18n, llm
from ..i18n import t

PROMPT_RU = """Ниже расшифровка звонка (локальная транскрибация Whisper, возможны ослышки).
Я в звонке: {me}.{people}{context}
Сделай краткое саммари на русском в Markdown, строго такими разделами:

## Коротко
2-4 предложения: о чём звонок и чем закончился.
{marks}
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
I am on the call as: {me}.{people}{context}
Write a short summary in {language} in Markdown, with exactly these sections:

## Summary
2-4 sentences: what the call was about and how it ended.
{marks}
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


MARKS_RU = """
## Важные моменты
Во время звонка я отметил важные моменты: {times} (в расшифровке такие реплики начинаются с \u2b50).
Для каждого строка «- MM:SS: что там сказали или решили», 1-2 предложения по репликам около этого времени.
"""

MARKS_EN = """
## Key Moments
During the call I marked important moments: {times} (such lines in the transcript start with \u2b50).
For each, a line "- MM:SS: what was said or decided there", 1-2 sentences from the lines around that time.
"""


def build_prompt(transcript: str, me: str, context: str = "", lang: str | None = None, marks=(),
                 people=()) -> str:
    """people: the other participants by name (call.json "participants"), so tasks are assigned to real names."""
    lang = lang or i18n.lang()
    times = ", ".join(marks)
    ru = lang == "ru"
    label = "Контекст (для понимания, не пересказывай его)" if ru else "Context (for understanding, do not retell it)"
    others = "Другие участники" if ru else "Other participants"
    fields = {"me": me, "transcript": transcript, "context": f"\n{label}: {context}" if context else "",
              "people": f"\n{others}: {', '.join(people)}." if people else ""}
    if ru:
        return PROMPT_RU.format(**fields, marks=MARKS_RU.format(times=times) if marks else "")
    return PROMPT_EN.format(**fields, language=LANG_NAMES.get(lang, "the language of the conversation"),
                            marks=MARKS_EN.format(times=times) if marks else "")


def strip_dashes(text: str) -> str:
    return text.replace(f" {EM} ", ", ").replace(f" {EN} ", ", ").replace(EM, ", ").replace(EN, "-")


def context_for(prof: dict, topic: str, terms: str) -> str:
    parts = [prof.get("context", ""), f"{t('topic')}: {topic}." if topic else "",
             f"{t('keywords')}: {terms}." if terms else ""]
    return " ".join(p for p in parts if p)


def summarize(transcript: str, me: str, cwd: Path, context: str = "", lang: str | None = None, marks=(),
              log: Callable[[str], None] = lambda _m: None, people=()) -> str | None:
    out, name, err = llm.run(build_prompt(transcript, me, context, lang, marks, people), cwd)
    if not out:
        log(t("log_summary_failed", who=name or t("no_cli"), err=err))
        return None
    log(t("log_summary_ok", name=name, vendor=llm.vendor(name)))
    return strip_dashes(out)
