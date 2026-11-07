"""Speaker names from the conversation content via the assistant (Claude Code or Codex CLI).

Voices start unnamed ("Speaker 1"); the assistant matches them to people by forms of address,
introductions and verb gender. If it fails: names in order of voice appearance.
"""
import json
import re
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


# Labels that name nobody, in either language (the app's Voices.isGenericLabel is the same rule):
# "Собеседник", "Speaker 2", "Спикер ?", "Я", "Me", "Борис + собеседники".
_GENERIC = re.compile(r"^(собеседник|спикер|speaker)([ _]*([0-9]+|\?|n))?$", re.I)
# A generic label with a number ("Speaker 2") still stands for one distinct voice.
_NUMBERED = re.compile(r"^(собеседник|спикер|speaker)[ _]*[0-9]+$", re.I)


def is_generic(name: str, me: str = "") -> bool:
    """A label that is not a person's name, or the user's own label."""
    n = " ".join(str(name).split())
    low = n.casefold()
    if not n or low in ("я", "me") or (me.strip() and low == me.strip().casefold()):
        return True
    return low.endswith("+ собеседники") or low.endswith("+ others") or bool(_GENERIC.match(n))


def is_voice(label: str, me: str = "") -> bool:
    """A transcript label that stands for one other person's voice: a name or a numbered generic label
    ("Speaker 2"). The plain "Speaker" (no diarization, or a phrase no voice matched), the user and
    "<me> + others" are not: counting them would merge or split people on the next transcription."""
    n = " ".join(str(label).split())
    return not is_generic(n, me) or bool(_NUMBERED.match(n))


def participants(paras: list, me: str, typed: list) -> list:
    """call.json "participants", derived from the transcript (never fed back as typed names): everyone
    named in the transcript in the order they first speak, then the names the user typed ("names") that
    never spoke, in their order. Never the user, never a generic label, each name once (ignoring case).
    A typed first name that a fuller speaking name starts with ("Anna" and "Anna Petrova") is the same
    person and is not listed twice. The app's CallParticipants.derived is the same rule; both are tested
    against Tests/Fixtures/participants.json."""
    out, seen = [], set()
    for name in [who for *_, who in paras] + list(typed):
        name = " ".join(str(name).split())
        if is_generic(name, me) or name.casefold() in seen:
            continue
        seen.add(name.casefold())
        out.append(name)
    spoken = {" ".join(str(w).split()).casefold() for *_, w in paras}

    def folded(name):  # a typed name that never spoke but is the first word of exactly one speaking name
        low = name.casefold()
        if low in spoken or " " in name:
            return False
        return sum(1 for n in out if n.casefold() in spoken and n.casefold().split()[0] == low) == 1
    return [n for n in out if not folded(n)]


def generic_labels(paras: list, me: str) -> list:
    return [w for w in dict.fromkeys(w for *_, w in paras) if w != me and w.startswith(t("speaker"))]


def by_order(paras: list, me: str, given: list) -> list:
    """Unnamed voices get the known names in order of appearance."""
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
                  log: Callable[[str], None] = lambda _m: None, taken=()) -> list:
    """Match unnamed voices to people. Any assistant failure: names in order.
    taken: names already given by voice print, never given again."""
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
    used, final = {n.casefold() for n in taken}, {}
    for label in labels:
        n = mapping.get(label)
        n = " ".join(n.split()) if isinstance(n, str) else ""
        if n and not is_generic(n, me) and n.casefold() not in used:
            final[label] = n
            used.add(n.casefold())
    if final:
        log(t("log_names_ok", pairs=", ".join(f"{k} → {v}" for k, v in final.items())))
    else:
        log(t("log_names_unsure", speaker=t("speaker")))
    return [(s, e, text, final.get(w, w)) for s, e, text, w in paras]
