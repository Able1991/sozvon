"""Who is speaking: utterance labels by track and splitting the other side by voice.

The microphone is "me", system audio is the other side. Voice splitting (pyannote) is only needed
to separate SEVERAL remote participants within the system track. If system audio dropped out
mid-call, the other side is heard only in the microphone: voices there are split on their own.
Someone next to the user is told apart from the user by the user's voice print (split_mic).
"""
from typing import Callable

from .. import diarize, voices
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
                    run_diarization=None, name_voices=None, mic_people=None) -> list:
    """All utterances with labels. A splitting failure does not lose text: labels become generic.

    single_name: how to label the other side without splitting (the only known name or None).
    name_voices(track, diar) -> {raw label: (name, score)}: voices recognized by voice print. Any failure
    there is logged and the call goes on exactly as without voice prints.
    mic_people(diarize_mic, system_diar) -> (diar, {raw label: name or None}): others at the user's microphone.
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
    system_diar: list | None = None if system else []
    system_voices = 0
    if system:
        done = False
        if can:
            try:
                diar = run_diarization(tracks["system"], speakers)
                labeled, n = label_system(system, diar, names, recognize(name_voices, tracks["system"], diar, system, log))
                items += labeled
                log(t("log_diar_count", n=n))
                done = True
                system_diar, system_voices = diar, n
            except Exception as ex:  # noqa: BLE001
                log(t("log_diar_failed", err=ex))
        if not done:
            them = single_name or t("speaker")
            items += [(s, e, text, them) for s, e, text in system]
    # With system audio gaps the mic was diarized above for another purpose, and label_mic has labeled it.
    if can and mic_people and not mic_dead and system_diar is not None \
            and sum(e - s for s, e, _ in mic) >= voices.MIN_MIC_PERSON:
        items[:len(mic)] = split_mic(mic, me, mic_people, lambda: run_diarization(tracks["mic"], None), system_diar,
                                     system_voices, log)
    return items


def split_mic(mic: list, me: str, mic_people, diarize_mic, system_diar: list, system_voices: int, log: Log) -> list:
    """Microphone utterances with labels: the user, or another person at the microphone.

    An unknown person gets a generic label numbered after the system track's voices, so the numbers never collide
    and the assistant can name them from the conversation. Any failure: everything is the user, as without this.
    """
    mine = [(s, e, text, me) for s, e, text in mic]
    try:
        diar, people = mic_people(diarize_mic, system_diar)
    except Exception as ex:  # noqa: BLE001  no model, no pyannote, a broken track: the transcription is never lost
        log(t("log_mic_failed", err=ex))
        return mine
    labels: dict = {}
    unnamed = 0
    out = []
    for s, e, text in mic:
        raw = _max_overlap(s, e, diar)
        if raw not in people:
            out.append((s, e, text, me))
            continue
        if raw not in labels:
            if people[raw] is None:
                unnamed += 1
            labels[raw] = people[raw] or t("speaker_n", n=system_voices + unnamed)
        out.append((s, e, text, labels[raw]))
    if labels:
        log(t("log_mic_people", names=", ".join(labels.values())))
    return out


def track_labels(items: list, mic_items: int, renamed: dict, me: str) -> dict | None:
    """call.json "speaker_tracks": {final label: "mic", "system" or "both"}; None when the microphone holds only the user.

    items: as assign_speakers returns them, the first mic_items of them from the microphone.
    renamed: {label in items: final label} after the assistant named the voices.
    """
    on_mic = {renamed.get(w, w) for *_, w in items[:mic_items]}
    on_system = {renamed.get(w, w) for *_, w in items[mic_items:]}
    if on_mic <= {me}:
        return None
    return {w: "both" if w in on_mic and w in on_system else "mic" if w in on_mic else "system" for w in on_mic | on_system}


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
