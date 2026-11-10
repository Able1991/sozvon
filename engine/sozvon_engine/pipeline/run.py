"""bin/process_call.py: transcribe a call folder (docs/CONTRACT.md, sections 3 and 5).

Everything about the call comes from call.json; command-line arguments only override fields.
Stages: call -> model -> tracks -> recognition -> echo and gaps -> voices -> voice prints -> names ->
transcript files -> summary -> status done -> listening file. The transcript is written to disk before the
summary: an assistant failure does not lose it. The listening file comes after the call is done: the call is
complete without it. Last output line: "RESULT: ok" or "RESULT: error <code> <message>".
"""
import argparse
import os
import sys
import time
import traceback
from dataclasses import dataclass, field
from enum import IntEnum
from pathlib import Path

from .. import calls, config, jsonfile, langid, llm, models, paths, profiles, remote, voices, whisper
from .. import prompt as prompts
from .. import vocab as vocabs
from ..audio import FfmpegError, FfmpegMissing
from ..i18n import t
from . import guard, render, speakers
from . import listen as listen_stage
from . import names as names_stage
from . import summary as summary_stage
from . import tracks as tracks_stage
from . import transcribe as transcribe_stage


class Exit(IntEnum):
    OK = 0
    OTHER = 1
    BAD_INPUT = 2       # no audio on any track, missing folder, broken call.json
    ENGINE_BROKEN = 3   # libraries fail to import, no ffmpeg
    MODEL_MISSING = 4
    FFMPEG = 5          # ffmpeg could not read the recording


class EngineError(Exception):
    def __init__(self, code: Exit, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def one_line(error, limit: int = 160) -> str:
    """A failure for call.json "warnings": the first line only, short. Never transcript text: it is the
    assistant's or the exception's message, not the prompt."""
    lines = str(error).strip().splitlines()
    return (lines[0].strip() if lines else "")[:limit] or "unknown error"


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


@dataclass
class CallSpec:
    """What to transcribe and how: call.json, arguments on top of it, on top of engine settings."""
    dir: Path
    id: str
    me: str
    model: str = models.DEFAULT_MODEL
    profile: str = ""
    names: list = field(default_factory=list)
    topic: str = ""
    terms: str = ""
    languages: str = "ru"
    speakers: int | None = None
    # The user set that number (not worked out from the names or the last transcript): diarization has to keep it.
    speakers_given: bool = False
    switch: bool = False
    diarize: bool = True
    summary: bool = True
    # call.json "kind": "reflection": the user alone, thinking out loud. One speaker, its own kind of summary.
    reflection: bool = False
    # call.json "speaker_tracks" of this run (speakers.track_labels), None when the mic holds only the user.
    speaker_tracks: dict | None = None
    smart_names: bool = True
    # "Important" marks from the recording panel: seconds on the transcript timeline (call.json "marks").
    marks: list = field(default_factory=list)
    # Steps that failed on this run, for call.json "warnings" (add with warn()).
    warnings: list = field(default_factory=list)

    def warn(self, step: str, error) -> None:
        self.warnings.append({"step": step, "error": one_line(error)})

    @property
    def allowed(self):
        return langid.parse_languages(self.languages)

    @property
    def keywords(self) -> str:
        return ", ".join(x for x in (self.topic, self.terms) if x)


def parse_args(argv=None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Sozvon: расшифровать папку звонка (настройки из call.json)")
    ap.add_argument("dir", help="папка звонка с mic.m4a, system.m4a и call.json")
    ap.add_argument("--me", default=None, help="как подписывать меня (иначе SOZVON_ME)")
    ap.add_argument("--language", default=None, help="языки речи: ru, ru,en или auto")
    ap.add_argument("--speakers", type=int, default=None, help="число собеседников без меня")
    ap.add_argument("--names", default=None, help="имена собеседников через запятую")
    ap.add_argument("--profile", default=None, help="проект из profiles/")
    ap.add_argument("--topic", default=None, help="тема звонка")
    ap.add_argument("--terms", default=None, help="ключевые слова звонка через запятую")
    ap.add_argument("--switch", action="store_true", default=None,
                    help="определять язык каждой фразы (медленнее)")
    ap.add_argument("--no-diarize", action="store_true", help="без разбивки собеседников по голосам")
    ap.add_argument("--no-summary", action="store_true", help="без саммари (текст не покидает Mac)")
    ap.add_argument("--summary-only", action="store_true",
                    help="только заново сделать саммари по transcript.txt (после правок расшифровки)")
    return ap.parse_args(argv)


def _names(value) -> list:
    if isinstance(value, list):
        return [str(n).strip() for n in value if str(n).strip()]
    return [n.strip() for n in str(value or "").split(",") if n.strip()]


def _str(value) -> str:
    return value.strip() if isinstance(value, str) else ""


def overrides(args: argparse.Namespace) -> dict:
    """call.json fields set by arguments (we write them back: the transcript was made with them)."""
    out = {}
    for key in ("profile", "topic", "terms"):
        if getattr(args, key) is not None:
            out[key] = getattr(args, key).strip()
    if args.names is not None:
        out["names"] = _names(args.names)
    if args.language is not None:
        out["languages"] = args.language
    if args.no_summary:
        out["summary"] = False
    return out


def build_spec(d: Path, call: dict, args: argparse.Namespace, settings: config.Settings) -> CallSpec:
    merged = {**call, **overrides(args)}
    names = _names(merged.get("names"))
    me = _str(args.me) or settings.me or t("me")
    speakers_n = args.speakers if args.speakers is not None else merged.get("speakers")
    speakers_given = isinstance(speakers_n, int) and speakers_n > 0
    if not speakers_given:
        speakers_n = max(len([n for n in names if not names_stage.is_generic(n, me)]), _voices_heard(d, me, merged.get("speaker_tracks"))) or None
    profile = _str(merged.get("profile"))
    if profile and not profiles.valid_slug(profile):
        log(t("log_bad_profile", profile=profile))
        profile = ""
    return CallSpec(
        dir=d, id=call["id"],
        me=me,
        model=settings.model,
        profile=profile, names=names,
        topic=_str(merged.get("topic")), terms=_str(merged.get("terms")),
        languages=_str(merged.get("languages")) or settings.languages,
        speakers=speakers_n,
        speakers_given=speakers_given,
        switch=bool(args.switch) or settings.lang_switch,
        diarize=not args.no_diarize and call.get("kind") != "reflection",
        summary=merged.get("summary", True) is not False,
        reflection=call.get("kind") == "reflection",
        smart_names=settings.smart_names,
        marks=_marks(call.get("marks")),
    )


def _voices_heard(d: Path, me: str, tracks: dict | None = None) -> int:
    """How many other people the call's current transcript.txt has (a transcription again): call.json names
    list only the typed ones, and diarization told to expect fewer voices would merge two people into one.
    Only labels that stand for a voice count (names_stage.is_voice): a plain "Speaker" from a run without
    diarization would otherwise pin the next run to one remote voice. The count is for the system track, so people at the
    microphone (tracks: call.json "speaker_tracks") are left out. -> 0 when none is left."""
    f = Path(d) / "transcript.txt"
    if not f.is_file():
        return 0
    labels = {" ".join(w.split()).casefold()
              for *_, w in render.parse_txt(f.read_text(encoding="utf-8", errors="replace"))
              if names_stage.is_voice(w, me)}
    if isinstance(tracks, dict):
        labels -= {" ".join(str(w).split()).casefold() for w, track in tracks.items() if track == "mic"}
    return len(labels)


def _check_remote_voices(items: list, first: int, system, spec, typed: list, log, recognized: set) -> list:
    """The other side's lines checked one by one against the saved voices of the people who can be on the call
    (voices.refine_by_print). With typed names, only their voices. Any failure keeps the labels."""
    try:
        records = voices.candidates(spec.profile, False, log)
        if typed:
            wanted = {n.casefold() for n in typed}
            records = [r for r in records if r["name"].casefold() in wanted]
        remote = voices.refine_by_print(system, items[first:], records, log)
    except Exception as ex:  # noqa: BLE001  labels from diarization are still a transcript
        log(t("log_voice_refine_failed", err=ex))
        return items
    recognized.update(w for *_, w in remote if any(w == r["name"] for r in records))
    return items[:first] + remote


def _marks(v) -> list:
    if not isinstance(v, list):
        return []
    return sorted(float(x) for x in v if isinstance(x, (int, float)) and not isinstance(x, bool) and x >= 0)


def check_model(model: str, data: Path) -> str | None:
    """The model is in the manifest and downloaded. -> path to the Whisper model (None for onnx)."""
    if model not in models.MODELS:
        raise EngineError(Exit.BAD_INPUT, t("err_unknown_model", model=model, known=", ".join(models.MODELS)))
    if not models.is_downloaded(data, model):
        raise EngineError(Exit.MODEL_MISSING, t("err_model_missing", model=model))
    return models.local_whisper(data, model)


def process(spec: CallSpec, settings: config.Settings, data: Path) -> list:
    """Transcribe a call: transcript files, the summary, status done, then the listening file. -> call.json "participants"."""
    d = spec.dir
    files = tracks_stage.track_files(d)
    if not files:
        raise EngineError(Exit.BAD_INPUT, t("err_no_audio"))
    model_path = check_model(spec.model, data)
    onnx = models.is_onnx(spec.model)

    vocab = vocabs.load()
    prof = profiles.load(spec.profile)
    added = profiles.learn_people(spec.profile, prof, spec.names, spec.me)
    if added:
        log(t("log_people_learned", profile=spec.profile, names=", ".join(added)))

    def build(lang):
        v = prompts.vocab_for_language(vocab, lang)
        return (prompts.build_prompt(v, prof, spec.names, spec.keywords, lang=lang),
                prompts.base_prompt(v, prof, spec.names, lang=lang))

    prompt_set = transcribe_stage.Prompts(build, vocabs.all_replacements(vocab, prof))
    allowed = spec.allowed
    try:
        meta = calls.audio_meta(d, calls.read_call(d))
        offsets = tracks_stage.delays(meta)
        gains = {}
        tracks = tracks_stage.prepare(files, offsets, d, log, spec.warn, gains)
        if not tracks:
            raise EngineError(Exit.BAD_INPUT, t("err_no_audio"))
        if not onnx:
            whisper.ensure_backend()
            first = build(allowed[0] if allowed else None)[0]
            log(t("log_profile", profile=spec.profile or "-", names=", ".join(spec.names) or "-",
                  tokens=prompts.count_tokens(first)))

        segs, langs = transcribe_stage.transcribe_tracks(
            tracks, data_dir=data, model=spec.model, model_path=model_path, allowed=allowed,
            switch=spec.switch, prompts=prompt_set, log=log)
        paras = arrange(spec, prof, tracks, segs, settings)
        people = names_stage.participants(paras, spec.me, spec.names)
        (d / "transcript.txt").write_text(render.render_txt(paras), encoding="utf-8")
        write_md(spec, paras, prof)

        if spec.summary and paras and llm.backend(settings)[0]:
            # Summary language: the conversation language (my track, else the others', else the configured one).
            lang = langs.get("mic") or langs.get("system") or (allowed[0] if allowed else None)
            try:
                summarize(spec, prof, paras, lang, people)
            except Exception as ex:  # noqa: BLE001  an assistant failure does not lose the transcript
                log(t("log_summary_failed", who=type(ex).__name__, err=ex))
                spec.warn("summary", f"{type(ex).__name__}: {ex}")
        complete(spec, people)
        # Last, while the working wavs are still here, and after the call is done: its outcome cannot change the call.
        listen_stage.render(d, files, offsets, tracks, gains, log)
    finally:
        tracks_stage.cleanup(d)
    log(t("log_done", path=d / "transcript.md", n=len(paras)))
    return people


def complete(spec: CallSpec, people: list) -> None:
    """The call is finished: status done, and its text on the own server. Only the optional listening file comes after."""
    # "warnings": the steps that failed on this run; "speaker_tracks": where each label's lines came from.
    # Nothing to say: an old value goes away.
    optional = {"warnings": spec.warnings, "speaker_tracks": spec.speaker_tracks}
    calls.update_call(spec.dir, status="done", participants=people,
                      engine={"version": paths.engine_version(), "model": spec.model},
                      drop=tuple(k for k, v in optional.items() if not v), **{k: v for k, v in optional.items() if v})
    remote.push_after_transcription(spec.dir, log)  # own server, if set up: a failure is only a warning


def write_md(spec: CallSpec, paras: list, prof: dict, summary: str | None = None) -> Path:
    out = spec.dir / "transcript.md"
    out.write_text(render.render_md(spec.id, paras, prof.get("title", ""), spec.topic, summary,
                                    marked=render.marked(paras, spec.marks)), encoding="utf-8")
    return out


def summarize(spec: CallSpec, prof: dict, paras: list, lang, people: list) -> str | None:
    """Summary through the assistant; on success summary.md is written and transcript.md gets it.
    Paragraphs at an "important" mark are shown with a leading star. -> the summary or None."""
    marked = render.marked(paras, spec.marks)
    shown = [("\u2b50 " + ln if i in marked else ln) for i, ln in enumerate(render.transcript_lines(paras))]
    log(t("log_summary_start"))
    text = summary_stage.summarize("\n".join(shown), spec.me, spec.dir,
                                   summary_stage.context_for(prof, spec.topic, spec.terms), lang,
                                   marks=[render.format_timestamp(m) for m in spec.marks], log=log, people=people,
                                   reflection=spec.reflection,
                                   warn=lambda m: spec.warn("summary", m))
    if text:
        (spec.dir / "summary.md").write_text(text + "\n", encoding="utf-8")
        write_md(spec, paras, prof, text)
    return text


def resummarize(spec: CallSpec, settings: config.Settings) -> list:
    """A new summary from the (edited) transcript.txt, no speech recognition: summary.md and transcript.md
    (rebuilt from transcript.txt with the new summary) are rewritten, transcript.txt never.
    -> call.json "participants", from the edited transcript."""
    txt = spec.dir / "transcript.txt"
    if not txt.is_file():
        raise EngineError(Exit.BAD_INPUT, t("err_no_transcript"))
    paras = render.parse_txt(txt.read_text(encoding="utf-8"))
    if not paras:
        raise EngineError(Exit.BAD_INPUT, t("err_no_transcript"))
    if not llm.backend(settings)[0]:
        raise EngineError(Exit.BAD_INPUT, t("err_no_assistant"))
    allowed = spec.allowed
    people = names_stage.participants(paras, spec.me, spec.names)
    # One call language: the summary is in it. Several or auto: None, and summary.build_prompt falls back to
    # the app's language (the detected language of the tracks is not kept after a transcription).
    lang = allowed[0] if allowed and len(allowed) == 1 else None
    try:
        text = summarize(spec, profiles.load(spec.profile), paras, lang, people)
    except Exception as ex:  # noqa: BLE001  the run fails, and the call keeps the reason
        spec.warn("summary", f"{type(ex).__name__}: {ex}")
        calls.update_call(spec.dir, warnings=spec.warnings)
        raise
    if not text:
        calls.update_call(spec.dir, warnings=spec.warnings)
        raise EngineError(Exit.OTHER, t("log_summary_failed", who="-", err="-"))
    log(t("log_done", path=spec.dir / "transcript.md", n=len(paras)))
    return people


def arrange(spec: CallSpec, prof: dict, tracks: dict, segs: dict, settings: config.Settings) -> list:
    """Track segments -> labeled paragraphs: echo, system audio gaps, voices, names."""
    mic, system = segs.get("mic", []), segs.get("system", [])
    if mic and system:
        mic, dropped = tracks_stage.drop_echo(mic, system)
        if dropped:
            log(t("log_echo", n=dropped))
    # System audio may drop out mid-call (output device switch): then the other side
    # is heard only in the microphone.
    mic_dead = []
    if "system" in tracks:
        spans = tracks_stage.dead_spans(tracks["system"])
        if spans:
            mic, mic_dead = tracks_stage.split_dead(mic, spans)
            if mic_dead:
                log(t("log_dead_system", sec=sum(de - ds for ds, de in spans)))

    # Typed names never include the user (a remote voice must not get the user's name).
    typed = [n for n in spec.names if not names_stage.is_generic(n, spec.me)]
    # With the assistant, voices start unnamed, then it matches them to people by content. Project people
    # whose name is the user's, or starts with it ("Борис" in "Борис Иванов"), are the user.
    me_key = spec.me.casefold()
    candidates = list(dict.fromkeys(typed + [p for p in prof.get("people", []) if p.strip()
                                             and me_key not in (p.casefold(), p.split()[0].casefold())]))
    # Only for a call whose text the user agreed to send to the assistant (the summary is on).
    smart = spec.summary and spec.smart_names and bool(candidates) and not spec.reflection and llm.backend(settings)[0] is not None
    # Voice prints first: a voice heard before gets its stored name, final. On a single-track recording
    # (imported) the user's own voice is among the remote ones, so the "me" print is matched too.
    recognized: set = set()
    embedded: dict = {}  # each voice of this run is embedded once

    def name_voices(track, diar):
        found = voices.identify(track, diar, spec.profile, spec.me if "mic" not in tracks else None, log, embedded)
        recognized.update(name for name, _ in found.values())
        return found

    def mic_people(diarize_mic, system_diar):
        diar, people = voices.mic_people(tracks["mic"], diarize_mic, tracks.get("system"), system_diar, spec.profile, log,
                                         embedded)
        recognized.update(name for name in people.values() if name)
        return diar, people
    items = speakers.assign_speakers(
        mic=mic, mic_dead=mic_dead, system=system, tracks=tracks, me=spec.me,
        names=[] if smart else typed, speakers=spec.speakers, diarize_on=spec.diarize,
        single_name=spec.me if spec.reflection else typed[0] if len(typed) == 1 and not smart else None, log=log,
        name_voices=name_voices, mic_people=None if spec.reflection or "mic" not in tracks else mic_people,
        same_voice=None if spec.speakers_given else lambda diar: voices.merge_same_voice(tracks["system"], diar, log, embedded))
    if spec.diarize and not spec.reflection and "system" in tracks:
        items = _check_remote_voices(items, len(mic) + len(mic_dead), tracks["system"], spec, typed, log, recognized)
    paras = render.merge(items)
    unnamed = paras
    known = {n.casefold() for n in recognized}
    given = [n for n in typed if n.casefold() not in known]
    candidates = [n for n in candidates if n.casefold() not in known]
    if smart and candidates:
        try:
            paras = names_stage.resolve_names(paras, candidates, given, spec.me, spec.dir, log=log, taken=recognized,
                                            warn=lambda m: spec.warn("names", m))
        except Exception as ex:  # noqa: BLE001  an assistant timeout or failure does not lose the transcript
            log(t("log_names_error", err=ex))
            spec.warn("names", f"{type(ex).__name__}: {ex}")
            paras = names_stage.by_order(paras, spec.me, given)
    elif smart:
        paras = names_stage.by_order(paras, spec.me, given)
    # Naming keeps the paragraphs in place, so the two lists line up.
    renamed = {before[3]: after[3] for before, after in zip(unnamed, paras)}
    spec.speaker_tracks = speakers.track_labels(items, len(mic) + len(mic_dead), renamed, spec.me)
    return paras


def finish(code: int, message: str = "") -> int:
    """Last output line for the app (single line)."""
    if code == Exit.OK:
        print("RESULT: ok", flush=True)
    else:
        msg = " ".join(str(message).split())
        log(msg)
        print(f"RESULT: error {int(code)} {msg}", flush=True)
    return int(code)


def main(argv=None) -> int:
    if argv is None:  # a real launch: tests and in-process callers pass arguments and start no thread
        guard.watch_parent()
        guard.exit_on_sigterm()
    args = parse_args(argv)
    lock = None
    try:
        d = Path(args.dir).expanduser()
        if not d.is_dir():
            raise EngineError(Exit.BAD_INPUT, t("err_no_dir", path=d))
        lock = guard.lock_call(d, on_wait=lambda: log(t("log_waiting_for_run")))
        try:
            call = calls.read_call(d, strict=True)
        except jsonfile.JsonFileError as e:
            raise EngineError(Exit.BAD_INPUT, t("err_bad_call", err=e)) from e
        settings = config.load()
        spec = build_spec(d, call, args, settings)
        if args.summary_only:
            # "names" stay what the user typed; the derived list goes to "participants" (CONTRACT.md 4).
            # Naming did not run again: its earlier warning stays, only the summary's is renewed.
            spec.warnings.extend(w for w in call.get("warnings") or [] if isinstance(w, dict) and w.get("step") == "names")
            people = resummarize(spec, settings)
            calls.update_call(d, participants=people,
                              **({"warnings": spec.warnings} if spec.warnings else {"drop": ("warnings",)}))
            remote.push_after_transcription(d, log)
            return finish(Exit.OK)
        calls.update_call(d, status="processing", **overrides(args))
        process(spec, settings, paths.data_dir())
        return finish(Exit.OK)
    except EngineError as e:
        return finish(e.code, e.message)
    except FfmpegError as e:
        return finish(Exit.FFMPEG, t("err_ffmpeg", file=e.file.name, err=e.detail))
    except (ImportError, FfmpegMissing) as e:
        traceback.print_exc()
        return finish(Exit.ENGINE_BROKEN, t("err_engine", err=e))
    except Exception as e:  # noqa: BLE001
        traceback.print_exc()
        return finish(Exit.OTHER, f"{type(e).__name__}: {e}")
    finally:
        if lock is not None:
            os.close(lock)
