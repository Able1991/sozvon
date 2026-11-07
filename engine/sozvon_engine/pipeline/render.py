"""Merging utterances into paragraphs and transcript files. Pure functions, no I/O.

Paragraph: (start, end, text, who). transcript.txt format: "[MM:SS] Name: text".
"""
from ..i18n import t


def format_timestamp(seconds: float) -> str:
    seconds = max(0.0, float(seconds))
    h, m, s = int(seconds // 3600), int((seconds % 3600) // 60), int(seconds % 60)
    return f"{h:02d}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def merge(items: list, gap: float = 30.0, max_chars: int = 700, max_dur: float = 90.0) -> list:
    """Merge consecutive utterances of one person into a paragraph.

    A paragraph breaks on a pause longer than gap, and when it exceeds max_chars characters or
    max_dur seconds: otherwise a monologue turns into one unreadable wall of text.
    """
    paras = []
    for s, e, text, who in sorted(items, key=lambda x: x[0]):
        if paras:
            ps, pe, pt, pw = paras[-1]
            if pw == who and s - pe <= gap and len(pt) < max_chars and s - ps < max_dur:
                paras[-1] = (ps, e, f"{pt} {text}", who)
                continue
        paras.append((s, e, text, who))
    return paras


def parse_txt(text: str) -> list:
    """transcript.txt back to paragraphs. A paragraph ends where the next one starts (the last one: +5 s)."""
    import re
    line = re.compile(r"^\[(\d+:\d{2}(?::\d{2})?)\]\s(\S.*?):\s?(.*)$")
    rows = []
    for raw in text.splitlines():
        m = line.match(raw.strip())
        if not m:
            continue
        parts = [int(p) for p in m.group(1).split(":")]
        start = sum(p * 60 ** i for i, p in enumerate(reversed(parts)))
        rows.append((float(start), m.group(3), m.group(2)))
    return [(s, rows[i + 1][0] if i + 1 < len(rows) else s + 5.0, text, who)
            for i, (s, text, who) in enumerate(rows)]


def transcript_lines(paras: list) -> list:
    return [f"[{format_timestamp(s)}] {who}: {text}" for s, _, text, who in paras]


def render_txt(paras: list) -> str:
    return "\n".join(transcript_lines(paras)) + "\n"


def people(paras: list) -> list:
    return list(dict.fromkeys(who for *_, who in paras))


STAR = " \u2b50"


def marked(paras: list, marks) -> set:
    """Indexes of the paragraphs the "important" marks fall on: the paragraph spoken at that second,
    otherwise the last one that started before it (the mark is pressed right after the words)."""
    out = set()
    for m in marks:
        hit = next((i for i, (s, e, _, _) in enumerate(paras) if s <= m <= e), None)
        if hit is None:
            before = [i for i, (s, _, _, _) in enumerate(paras) if s <= m]
            hit = before[-1] if before else (0 if paras else None)
        if hit is not None:
            out.add(hit)
    return out


def render_md(call_id: str, paras: list, project: str = "", topic: str = "", summary: str | None = None,
              marked: set = frozenset()) -> str:
    """transcript.md: title, duration and participants, summary (if any), transcript. A marked paragraph ends
    with a star, so the "[MM:SS] Name: text" format every reader parses stays the same."""
    duration = max((e for _, e, _, _ in paras), default=0)
    title = f"# {t('call')} {call_id}" + (f" · {project}" if project else "") + (f" · {topic}" if topic else "")
    md = [title, "", f"{t('duration')}: {format_timestamp(duration)} · {t('people')}: {', '.join(people(paras))}", ""]
    if summary:
        md += [summary, "", "---", "", f"## {t('transcript')}", ""]
    md += [f"**[{format_timestamp(s)}] {who}:** {text}{STAR if i in marked else ''}\n"
           for i, (s, _, text, who) in enumerate(paras)]
    return "\n".join(md)
