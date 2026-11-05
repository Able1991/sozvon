"""Имена собеседников по смыслу разговора через помощника (Claude Code или Codex CLI).

Голоса сначала безымянные («Собеседник 1»), помощник сопоставляет их с людьми по обращениям,
представлениям и роду глаголов. Не справился: имена по порядку появления голосов.
"""
import json
from pathlib import Path
from typing import Callable

from .. import i18n, llm
from ..i18n import t
from .render import transcript_lines

MAX_CHARS = 30000

PROMPT_RU = """Ниже расшифровка звонка. Голоса собеседников размечены условно: {labels}.
Я в звонке: {me}. Возможные участники: {candidates}{given}.

Определи, кто есть кто, по смыслу: обращения по имени и ответ сразу после них, как люди
представляются, кого благодарят или упоминают, грамматический род («я сделала» это женщина).
Каждое имя используй не больше одного раза. Если не уверен, ставь null: лучше «{speaker}»,
чем чужое имя. Если человек явно назвал себя, а его нет в списке, можно его имя.

Ответ строго JSON-объект без текста вокруг: {{"{example}": "Имя Фамилия" или null, ...}}

Расшифровка:
{transcript}"""

PROMPT_EN = """Below is a call transcript. The other speakers' voices are labeled generically: {labels}.
I am on the call as: {me}. Possible participants: {candidates}{given}.

Work out who is who from the content: names used to address someone and the reply right after,
how people introduce themselves, who is thanked or mentioned, grammatical gender.
Use each name at most once. If unsure, use null: "{speaker}" is better than a wrong name.
If someone clearly introduced themselves and is not in the list, you may use their name.

Answer with a JSON object only, no text around it: {{"{example}": "First Last" or null, ...}}

Transcript:
{transcript}"""

GIVEN = {"ru": ". Точно были на звонке: {names}", "en": ". Definitely on the call: {names}"}


def generic_labels(paras: list, me: str) -> list:
    return [w for w in dict.fromkeys(w for *_, w in paras) if w != me and w.startswith(t("speaker"))]


def by_order(paras: list, me: str, given: list) -> list:
    """Безымянные голоса получают известные имена по порядку появления."""
    m = {lab: given[i] for i, lab in enumerate(generic_labels(paras, me)) if i < len(given)}
    return [(s, e, text, m.get(w, w)) for s, e, text, w in paras]


def build_prompt(paras: list, labels: list, candidates: list, given: list, me: str) -> str:
    lang = i18n.lang()
    text = "\n".join(transcript_lines(paras))[:MAX_CHARS]
    return (PROMPT_RU if lang == "ru" else PROMPT_EN).format(
        labels=", ".join(labels), me=me, candidates=", ".join(candidates),
        given=GIVEN[lang].format(names=", ".join(given)) if given else "",
        speaker=t("speaker"), example=labels[0], transcript=text)


def parse_mapping(out: str):
    start, end = out.index("{"), out.rindex("}") + 1
    mapping = json.loads(out[start:end])
    if not isinstance(mapping, dict):
        raise ValueError("not an object")
    return mapping


def resolve_names(paras: list, candidates: list, given: list, me: str, cwd: Path,
                  log: Callable[[str], None] = lambda _m: None) -> list:
    """Сопоставить безымянные голоса с людьми. Любой сбой помощника: имена по порядку."""
    labels = generic_labels(paras, me)
    if not labels:
        return paras
    out, name, err = llm.run(build_prompt(paras, labels, candidates, given, me), cwd, timeout=300)
    if not out:
        log(t("log_names_failed", who=name or t("no_cli"), err=err))
        return by_order(paras, me, given)
    try:
        mapping = parse_mapping(out)
    except ValueError:
        log(t("log_names_not_json"))
        return by_order(paras, me, given)
    used, final = set(), {}
    for label in labels:
        n = mapping.get(label)
        if isinstance(n, str) and n.strip() and n.strip() not in used and n.strip().lower() != me.lower():
            final[label] = n.strip()
            used.add(n.strip())
    if final:
        log(t("log_names_ok", pairs=", ".join(f"{k} → {v}" for k, v in final.items())))
    else:
        log(t("log_names_unsure", speaker=t("speaker")))
    return [(s, e, text, final.get(w, w)) for s, e, text, w in paras]
