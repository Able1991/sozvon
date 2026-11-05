"""Who is speaking: utterance labels by track and splitting the other side by voice.

The microphone is "me", system audio is the other side. Voice splitting (pyannote) is only needed
to separate SEVERAL remote participants within the system track. If system audio dropped out
mid-call, the other side is heard only in the microphone: voices there are split on their own.
"""
from typing import Callable

from .. import diarize
from ..i18n import t

Log = Callable[[str], None]


def system_label(voice, n_voices: int, names: list) -> str:
    """Label for a remote voice: name in order of appearance, else "Speaker N"."""
    if voice is None:
        return t("speaker")
    if voice < len(names):
        return names[voice]
    return t("speaker") if n_voices <= 1 else t("speaker_n", n=voice + 1)


def label_system(segs: list, diar: list, names: list) -> tuple[list, int]:
    """-> (labeled utterances, number of voices)."""
    labeled, n = diarize.assign(segs, diar)
    return [(s, e, text, system_label(v, n, names)) for s, e, text, v in labeled], n


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
                    run_diarization=None) -> list:
    """All utterances with labels. A splitting failure does not lose text: labels become generic.

    single_name: how to label the other side without splitting (the only known name or None).
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
                labeled, n = label_system(system, run_diarization(tracks["system"], speakers), names)
                items += labeled
                log(t("log_diar_count", n=n))
                done = True
            except Exception as ex:  # noqa: BLE001
                log(t("log_diar_failed", err=ex))
        if not done:
            them = single_name or t("speaker")
            items += [(s, e, text, them) for s, e, text in system]
    return items
