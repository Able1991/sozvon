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


def transcript_lines(paras: list) -> list:
    return [f"[{format_timestamp(s)}] {who}: {text}" for s, _, text, who in paras]


def render_txt(paras: list) -> str:
    return "\n".join(transcript_lines(paras)) + "\n"


def people(paras: list) -> list:
    return list(dict.fromkeys(who for *_, who in paras))


def render_md(call_id: str, paras: list, project: str = "", topic: str = "", summary: str | None = None) -> str:
    """transcript.md: title, duration and participants, summary (if any), transcript."""
    duration = max((e for _, e, _, _ in paras), default=0)
    title = f"# {t('call')} {call_id}" + (f" · {project}" if project else "") + (f" · {topic}" if topic else "")
    md = [title, "", f"{t('duration')}: {format_timestamp(duration)} · {t('people')}: {', '.join(people(paras))}", ""]
    if summary:
        md += [summary, "", "---", "", f"## {t('transcript')}", ""]
    md += [f"**[{format_timestamp(s)}] {who}:** {text}\n" for s, _, text, who in paras]
    return "\n".join(md)
