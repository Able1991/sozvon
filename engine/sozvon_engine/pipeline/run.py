"""bin/process_call.py: расшифровка папки звонка (docs/CONTRACT.md, разделы 3 и 5).

Всё о звонке берётся из call.json; аргументы командной строки только переопределяют поля.
Этапы: звонок -> модель -> дорожки -> распознавание -> эхо и пропуски -> голоса -> имена ->
файлы расшифровки -> саммари. Расшифровка пишется на диск до саммари: сбой помощника её
не теряет. Последняя строка вывода: «RESULT: ok» или «RESULT: error <код> <сообщение>».
"""
import argparse
import sys
import time
import traceback
from dataclasses import dataclass, field
from enum import IntEnum
from pathlib import Path

from .. import calls, config, jsonfile, langid, llm, models, paths, profiles, whisper
from .. import prompt as prompts
from .. import vocab as vocabs
from ..audio import FfmpegError, FfmpegMissing
from ..i18n import t
from . import names as names_stage
from . import render, speakers
from . import summary as summary_stage
from . import tracks as tracks_stage
from . import transcribe as transcribe_stage


class Exit(IntEnum):
    OK = 0
    OTHER = 1
    BAD_INPUT = 2       # нет звука ни на одной дорожке, нет папки, битый call.json
    ENGINE_BROKEN = 3   # не импортируются библиотеки, нет ffmpeg
    MODEL_MISSING = 4
    FFMPEG = 5          # ffmpeg не смог прочитать запись


class EngineError(Exception):
    def __init__(self, code: Exit, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


@dataclass
class CallSpec:
    """Что и как расшифровывать: call.json, поверх него аргументы, поверх настроек движка."""
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
    switch: bool = False
    diarize: bool = True
    summary: bool = True
    smart_names: bool = True

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
    return ap.parse_args(argv)


def _names(value) -> list:
    if isinstance(value, list):
        return [str(n).strip() for n in value if str(n).strip()]
    return [n.strip() for n in str(value or "").split(",") if n.strip()]


def _str(value) -> str:
    return value.strip() if isinstance(value, str) else ""


def overrides(args: argparse.Namespace) -> dict:
    """Поля call.json, которые задали аргументами (их записываем: с ними и расшифровано)."""
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
    speakers_n = args.speakers if args.speakers is not None else merged.get("speakers")
    if not isinstance(speakers_n, int) or speakers_n <= 0:
        speakers_n = len(names) or None
    profile = _str(merged.get("profile"))
    if profile and not profiles.valid_slug(profile):
        log(t("log_bad_profile", profile=profile))
        profile = ""
    return CallSpec(
        dir=d, id=call["id"],
        me=_str(args.me) or settings.me or t("me"),
        model=settings.model,
        profile=profile, names=names,
        topic=_str(merged.get("topic")), terms=_str(merged.get("terms")),
        languages=_str(merged.get("languages")) or settings.languages,
        speakers=speakers_n,
        switch=bool(args.switch) or settings.lang_switch,
        diarize=not args.no_diarize,
        summary=merged.get("summary", True) is not False,
        smart_names=settings.smart_names,
    )


def check_model(model: str, data: Path) -> str | None:
    """Модель есть в манифесте и скачана. -> путь к модели Whisper (None для onnx)."""
    if model not in models.MODELS:
        raise EngineError(Exit.BAD_INPUT, t("err_unknown_model", model=model, known=", ".join(models.MODELS)))
    if not models.is_downloaded(data, model):
        raise EngineError(Exit.MODEL_MISSING, t("err_model_missing", model=model))
    return models.local_whisper(data, model)


def process(spec: CallSpec, settings: config.Settings, data: Path) -> Path:
    """Расшифровать звонок. -> путь к transcript.md."""
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
        tracks = tracks_stage.prepare(files, tracks_stage.delays(meta), d, log)
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
        lines = render.transcript_lines(paras)
        project = prof.get("title", "")
        (d / "transcript.txt").write_text(render.render_txt(paras), encoding="utf-8")
        out = d / "transcript.md"
        out.write_text(render.render_md(spec.id, paras, project, spec.topic), encoding="utf-8")

        if spec.summary and paras and llm.backend(settings)[0]:
            log(t("log_summary_start"))
            text = None
            try:
                ctx = summary_stage.context_for(prof, spec.topic, spec.terms)
                # Язык саммари: язык разговора (моя дорожка, иначе собеседников, иначе заданный).
                lang = langs.get("mic") or langs.get("system") or (allowed[0] if allowed else None)
                text = summary_stage.summarize("\n".join(lines), spec.me, d, ctx, lang, log=log)
            except Exception as ex:  # noqa: BLE001  сбой помощника не теряет расшифровку
                log(t("log_summary_failed", who=type(ex).__name__, err=ex))
            if text:
                (d / "summary.md").write_text(text + "\n", encoding="utf-8")
                out.write_text(render.render_md(spec.id, paras, project, spec.topic, text), encoding="utf-8")
    finally:
        tracks_stage.cleanup(d)
    log(t("log_done", path=out, n=len(paras)))
    return out


def arrange(spec: CallSpec, prof: dict, tracks: dict, segs: dict, settings: config.Settings) -> list:
    """Сегменты дорожек -> абзацы с подписями: эхо, пропуски системного звука, голоса, имена."""
    mic, system = segs.get("mic", []), segs.get("system", [])
    if mic and system:
        mic, dropped = tracks_stage.drop_echo(mic, system)
        if dropped:
            log(t("log_echo", n=dropped))
    # Системный звук мог отвалиться посреди звонка (смена устройства вывода): там собеседники
    # слышны только в микрофоне.
    mic_dead = []
    if "system" in tracks:
        spans = tracks_stage.dead_spans(tracks["system"])
        if spans:
            mic, mic_dead = tracks_stage.split_dead(mic, spans)
            if mic_dead:
                log(t("log_dead_system", sec=sum(de - ds for ds, de in spans)))

    # С помощником голоса сначала безымянные, потом он сопоставляет их с людьми по смыслу.
    me_key = spec.me.lower()
    candidates = list(dict.fromkeys(spec.names + [p for p in prof.get("people", [])
                                                  if p.strip() and p.split()[0].lower() != me_key]))
    smart = spec.smart_names and bool(candidates) and llm.backend(settings)[0] is not None
    items = speakers.assign_speakers(
        mic=mic, mic_dead=mic_dead, system=system, tracks=tracks, me=spec.me,
        names=[] if smart else spec.names, speakers=spec.speakers, diarize_on=spec.diarize,
        single_name=spec.names[0] if len(spec.names) == 1 and not smart else None, log=log)
    paras = render.merge(items)
    if smart:
        try:
            paras = names_stage.resolve_names(paras, candidates, spec.names, spec.me, spec.dir, log=log)
        except Exception as ex:  # noqa: BLE001  таймаут или сбой помощника не теряет расшифровку
            log(t("log_names_error", err=ex))
            paras = names_stage.by_order(paras, spec.me, spec.names)
    return paras


def finish(code: int, message: str = "") -> int:
    """Последняя строка вывода для приложения (одной строкой)."""
    if code == Exit.OK:
        print("RESULT: ok", flush=True)
    else:
        msg = " ".join(str(message).split())
        log(msg)
        print(f"RESULT: error {int(code)} {msg}", flush=True)
    return int(code)


def main(argv=None) -> int:
    args = parse_args(argv)
    try:
        d = Path(args.dir).expanduser()
        if not d.is_dir():
            raise EngineError(Exit.BAD_INPUT, t("err_no_dir", path=d))
        try:
            call = calls.read_call(d, strict=True)
        except jsonfile.JsonFileError as e:
            raise EngineError(Exit.BAD_INPUT, t("err_bad_call", err=e)) from e
        settings = config.load()
        spec = build_spec(d, call, args, settings)
        calls.update_call(d, status="processing", **overrides(args))
        process(spec, settings, paths.data_dir())
        calls.update_call(d, status="done", engine={"version": paths.engine_version(), "model": spec.model})
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
