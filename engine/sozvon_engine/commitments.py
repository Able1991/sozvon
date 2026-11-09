"""Commitments and people across calls: the action items of the summaries, by person.

Nothing is stored: the summaries are read each time. The action item rules are the app's (ActionItems.swift).
"""
import re
from dataclasses import dataclass

from . import voices

HEADINGS = {"задачи", "action items", "tasks"}
SELF_WORDS = {"я", "вы", "you", "me"}
_SPLIT = re.compile(r",|/|&| и | and ", re.IGNORECASE)
_DOMAIN = re.compile(r"\.[^\W\d_]{2,}")


@dataclass
class Item:
    owner: str
    task: str
    done: bool = False


def _is_owner(owner: str, rest: str) -> bool:
    """A name or a few names before ": ", not a sentence or a link that happens to contain a colon."""
    if not rest[:1] in (" ", "\t") or not owner or len(owner) > 60 or len(owner.split()) > 4:
        return False
    if any(c.isdigit() or c in "/@" for c in owner):
        return False
    return not _DOMAIN.search(owner)


def _item(line: str) -> Item | None:
    if not line.startswith(("- ", "* ")):
        return None
    s = line[2:].lstrip(" ")
    done = False
    if s[:3] in ("[ ]", "[x]", "[X]"):
        done = s[:3] != "[ ]"
        s = s[3:].lstrip(" ")
    text = s.strip()
    if not text:
        return None
    if ":" in text:
        head, after = text.split(":", 1)
        owner = head.replace("*", "").strip()
        if after.startswith("**"):  # "**Anna:** task"
            after = after[2:]
        task = after.replace("**", "").strip()
        if _is_owner(owner, after) and task:
            return Item(owner, task, done)
    return Item("", text.replace("**", ""), done)


def parse(summary: str) -> list:
    """Items of the action items section, in order. Other sections are ignored."""
    inside, out = False, []
    for raw in summary.split("\n"):
        line = raw.strip()
        if line.startswith("#"):
            inside = line.lstrip("#").strip().strip(":").lower() in HEADINGS
            continue
        if not inside:
            continue
        if line == "---":
            inside = False
            continue
        item = _item(line)
        if item:
            out.append(item)
    return out


def _parts(owner: str) -> list:
    return [p.strip() for p in _SPLIT.split(owner) if p.strip()]


def _same(part: str, who: str) -> bool:
    if voices.same_name(part, who):
        return True
    a, b = part.split(), who.split()
    return (len(a) == 1 or len(b) == 1) and bool(a) and bool(b) and voices.same_name(a[0], b[0])


def same_person(owner: str, who: str) -> bool:
    """Whether this owner or participant is the person: any alphabet, a first name matches a full name.
    "Anna, Борис" counts for both."""
    return any(_same(p, who) for p in _parts(owner))


def is_owner_of(owner: str, who: str, mine: bool) -> bool:
    """`mine`: the person asked about is the user, so "Вы", "Я", "You" and "Me" are theirs too."""
    return same_person(owner, who) or (mine and any(p.lower() in SELF_WORDS for p in _parts(owner)))
