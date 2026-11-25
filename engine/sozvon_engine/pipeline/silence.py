"""How much of a call is silent at its start and its end, so the app can offer to trim it."""


def call_duration(meta: dict, offsets: dict) -> float:
    """Length of the call timeline: the latest end over the recorded tracks (offset + the track's seconds)."""
    ends = [float(offsets.get(k) or 0) + float(meta.get(f"{k}_seconds") or 0) for k in ("mic", "system")]
    return max(ends, default=0.0)


def head_tail(paras: list, duration: float) -> dict:
    """Seconds before the first and after the last paragraph; no paragraphs: all head."""
    if not paras:
        return {"head": round(max(duration, 0.0), 1), "tail": 0.0}
    head = min(p[0] for p in paras)
    tail = duration - max(p[1] for p in paras)
    return {"head": round(max(head, 0.0), 1), "tail": round(max(tail, 0.0), 1)}
