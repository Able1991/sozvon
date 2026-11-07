"""Who is speaking: utterance labels by track and splitting the other side by voice.

The microphone is "me", system audio is the other side. Voice splitting (pyannote) is only needed
to separate SEVERAL remote participants within the system track. If system audio dropped out
mid-call, the other side is heard only in the microphone: voices there are split on their own.
"""
from typing import Callable

from .. import diarize
from ..i18n import t

Log = Callable[[str], None]


def label_system(segs: list, diar: list, names: list, known: dict | None = None) -> tuple[list, int]:
    """-> (labeled utterances, number of voices).

    known: {raw label: name} recognized by voice print; those names are final. The other voices get the
    given names in order of appearance (skipping names a voice print took), else "Speaker N".
    """
    labeled, order = diarize.assign_order(segs, diar)
    n = len(order)
    known = known or {}
    by_voice = {v: known[raw] for raw, v in order.items() if raw in known}
    taken = {n_.casefold() for n_ in by_voice.values()}
    rest = [n_ for n_ in names if n_.casefold() not in taken]
    unnamed = [v for v in sorted(order.values()) if v not in by_voice]
    label = {v: rest[i] for i, v in enumerate(unnamed) if i < len(rest)}
    label.update(by_voice)

    def who(v):
        if v is None:
            return t("speaker")
        if v in label:
            return label[v]
        return t("speaker") if n <= 1 else t("speaker_n", n=v + 1)
    return [(s, e, text, who(v)) for s, e, text, v in labeled], n


def _max_overlap(s: float, e: float, diar: list):
    best, raw = 0.0, None
    for ds, de, sp in diar:
        ov = min(e, de) - max(s, ds)
        if ov > best:
            best, raw = ov, sp
    return raw


def label_mic(segs: list, diar: list, ref: list, me: str, names: list) -> tuple[list, int]:
    """Voices in the microphone while system audio was missing.

    My voice: the one that best matches my utterances where system audio was
    present (ref); without those, the one with the most speech. The rest in order of appearance.
    """
    if not diar:
        return [(s, e, text, me) for s, e, text in segs], 0

    def overlap(spans, raw):
        return sum(max(0.0, min(e, de) - max(s, ds)) for s, e, *_ in spans for ds, de, sp in diar if sp == raw)

    raws = list(dict.fromkeys(sp for *_, sp in diar))
    if ref:
        mine = max(raws, key=lambda r: overlap(ref, r))
    else:
        mine = max(raws, key=lambda r: sum(e - s for s, e, sp in diar if sp == r))
    others: dict = {}
    out = []
    for s, e, text in segs:
        raw = _max_overlap(s, e, diar)
        if raw is None or raw == mine:
            out.append((s, e, text, me))
            continue
        if raw not in others:
            i = len(others)
            others[raw] = names[i] if i < len(names) else t("speaker_n", n=i + 1)
        out.append((s, e, text, others[raw]))
    return out, len(others)


def assign_speakers(*, mic: list, mic_dead: list, system: list, tracks: dict, me: str, names: list,
                    speakers, diarize_on: bool, single_name: str | None, log: Log,
                    run_diarization=None, name_voices=None) -> list:
    """All utterances with labels. A splitting failure does not lose text: labels become generic.

    single_name: how to label the other side without splitting (the only known name or None).
    name_voices(track, diar) -> {raw label: (name, score)}: voices recognized by voice print. Any failure
    there is logged and the call goes on exactly as without voice prints.
    """
    run_diarization = run_diarization or diarize.run
    can = diarize_on and diarize.available()
    items = [(s, e, text, me) for s, e, text in mic]
    if mic_dead:
        done = False
        if can:
            try:
                k = (speakers + 1) if speakers else None
                labeled, n = label_mic(mic_dead, run_diarization(tracks["mic"], k), mic, me, names)
                items += labeled
                log(t("log_diar_mic_count", n=n))
                done = True
            except Exception as ex:  # noqa: BLE001
                log(t("log_diar_mic_failed", err=ex))
        if not done:
            items += [(s, e, text, t("me_plus", me=me)) for s, e, text in mic_dead]
    if system:
        done = False
        if can:
            try:
                diar = run_diarization(tracks["system"], speakers)
                labeled, n = label_system(system, diar, names, recognize(name_voices, tracks["system"], diar, system, log))
                items += labeled
                log(t("log_diar_count", n=n))
                done = True
            except Exception as ex:  # noqa: BLE001
                log(t("log_diar_failed", err=ex))
        if not done:
            them = single_name or t("speaker")
            items += [(s, e, text, them) for s, e, text in system]
    return items


def recognize(name_voices, track, diar: list, segs: list, log: Log) -> dict:
    """{raw label: name} from voice prints; {} when there are none or embeddings fail."""
    if not name_voices or not diar:
        return {}
    try:
        found = name_voices(track, diar) or {}
    except Exception as ex:  # noqa: BLE001  no model, no pyannote, a broken track: names as without voice prints
        log(t("log_voice_failed", err=ex))
        return {}
    _, order = diarize.assign_order(segs, diar)  # "Speaker N" as the transcript would number it
    for raw, (name, score) in sorted(found.items(), key=lambda kv: order.get(kv[0], 0)):
        n = order.get(raw, 0) + 1
        log(t("log_voice_match", speaker=t("speaker_n", n=n), name=name, score=score))
    return {raw: name for raw, (name, _score) in found.items()}
