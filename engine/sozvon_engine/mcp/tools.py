"""MCP tools: thin wrappers over the package.

Tool descriptions are in English: any user's Claude or Codex reads them.
Human-readable texts in responses are in the app language (SOZVON_UI_LANG).
"""
from pathlib import Path

from .. import audio, calls, diarize, models, paths, profiles, whisper
from .. import prompt as prompts
from .. import vocab as vocabs
from ..i18n import t
from ..pipeline.render import format_timestamp


def _err(key: str, **kw) -> str:
    return t("mcp_error", msg=t(key, **kw))


def transcribe(file_path: str, language: str = "ru", model: str = models.DEFAULT_MODEL,
               with_timestamps: bool = True, speakers: bool = False, profile: str = "",
               keywords: str = "") -> str:
    """Transcribe a local audio or video file on this Mac (nothing leaves the machine).

    Args:
        file_path: Absolute path to an audio or video file.
        language: Language code (ru, en, ...). Default: ru.
        model: Whisper model: turbo (default), large-v3 or small. See list_models.
        with_timestamps: Prefix each line with [MM:SS].
        speakers: Split the text by speaker (pyannote diarization, slower).
        profile: Sozvon project name (see list_profiles); its terms go into the prompt.
        keywords: Names and keywords of this recording, comma separated.

    Returns:
        The transcript text.
    """
    path = Path(file_path).expanduser()
    if not path.exists():
        return _err("mcp_file_not_found", path=path)
    if models.kind(model) != "whisper":
        return _err("mcp_unknown_model", model=model, known=", ".join(models.whisper_models()))
    model_path = models.local_whisper(paths.data_dir(), model)
    if model_path is None:
        return _err("mcp_model_missing", model=model)
    ext = path.suffix.lower()
    if ext not in audio.AUDIO_EXTS | audio.VIDEO_EXTS:
        return _err("mcp_bad_ext", ext=ext, audio=", ".join(sorted(audio.AUDIO_EXTS)),
                    video=", ".join(sorted(audio.VIDEO_EXTS)))
    vocab = vocabs.load()
    prof = profiles.load(profile)
    cleanup = None
    try:
        if ext in audio.VIDEO_EXTS:
            path = cleanup = audio.extract_audio(path)
        v = prompts.vocab_for_language(vocab, language)
        raw, _ = whisper.whisper_with_fallback(
            path, model_path, language, prompts.build_prompt(v, prof, keywords=keywords, lang=language),
            prompts.base_prompt(v, prof, lang=language), word_timestamps=False)
        segments = whisper.clean_segments(raw, vocabs.all_replacements(vocab, prof))
        if not speakers:
            if not with_timestamps:
                return " ".join(text for _, _, text in segments)
            return "\n".join(f"[{format_timestamp(s)}] {text}" for s, _, text in segments)
        try:
            labeled, _ = diarize.assign(segments, diarize.run(path))
        except Exception as e:  # noqa: BLE001
            return _err("mcp_diar_error", err=e)
        # Whisper cuts utterances into 1-3 word chunks: merge consecutive chunks of the same voice.
        paragraphs = []
        for s, _, text, voice in labeled:
            who = t("voice_unknown") if voice is None else t("voice_n", n=voice + 1)
            if paragraphs and paragraphs[-1][1] == who:
                paragraphs[-1] = (paragraphs[-1][0], who, f"{paragraphs[-1][2]} {text}")
            else:
                paragraphs.append((s, who, text))
        return "\n".join((f"[{format_timestamp(s)}] " if with_timestamps else "") + f"{who}: {text}"
                         for s, who, text in paragraphs)
    except Exception as e:  # noqa: BLE001
        return _err("mcp_transcribe_error", err=e)
    finally:
        if cleanup is not None:
            cleanup.unlink(missing_ok=True)


def list_models() -> str:
    """List the speech recognition models Sozvon knows and whether each is downloaded."""
    data = paths.data_dir()
    lines = [t("mcp_models")]
    for name, m in models.MODELS.items():
        marks = [t("mcp_default")] if name == models.DEFAULT_MODEL else []
        if not models.is_downloaded(data, name):
            marks.append(t("mcp_not_downloaded"))
        lines.append(f"  {name} ({m['kind']}) -> {m['repo']}" + (" " + " ".join(marks) if marks else ""))
    return "\n".join(lines)


def show_vocab() -> str:
    """Show the shared vocabulary: base prompt, shared terms and mishearing replacements."""
    vocab = vocabs.load()
    lines = [f"initial_prompt:\n  {vocab.get('initial_prompt', '')}", ""]
    if vocab.get("terms"):
        lines += ["terms:", "  " + ", ".join(vocab["terms"]), ""]
    lines.append(t("mcp_replacements"))
    lines += [f"  {p[0]!r} -> {p[1]!r}" for p in vocab.get("replacements", []) if vocabs.valid_pair(p)]
    return "\n".join(lines)


def add_replacement(wrong: str, right: str, profile: str = "") -> str:
    """Add a fix for a word the model systematically mishears (applies from the next transcription).

    Whole words, case-insensitive. Pass profile to apply it only to calls of one project: safer
    for words that mean something else in everyday speech.

    Args:
        wrong: What the model writes (wrong).
        right: What it should be.
        profile: Optional project name (see list_profiles).
    """
    wrong, right = wrong.strip(), right.strip()
    if not wrong or not right:
        return _err("mcp_both_fields")
    if profile:
        if not profiles.valid_slug(profile):
            return _err("mcp_no_profile", profile=profile)
        with profiles.editing(profile) as prof:
            if not prof:
                return _err("mcp_no_profile", profile=profile)
            prof["replacements"], _ = vocabs.set_replacement(prof.get("replacements", []), wrong, right)
        return t("mcp_profile_replacement", profile=profile, wrong=wrong, right=right)
    with vocabs.editing() as vocab:
        vocab["replacements"], old = vocabs.set_replacement(vocab.get("replacements", []), wrong, right)
    if old is not None:
        return t("mcp_replacement_updated", wrong=wrong, right=right, old=old)
    return t("mcp_replacement_added", wrong=wrong, right=right, n=len(vocab["replacements"]))


def remove_replacement(wrong: str) -> str:
    """Remove a replacement from the shared vocabulary by its left side (what the model hears).

    Args:
        wrong: Left side of the replacement to remove.
    """
    with vocabs.editing() as vocab:
        new, removed = vocabs.remove_replacement(vocab.get("replacements", []), wrong.strip())
        if removed:
            vocab["replacements"] = new
    if not removed:
        return t("mcp_replacement_not_found", wrong=wrong)
    return t("mcp_replacement_removed", wrong=wrong, n=len(new))


def add_terms(terms: str, profile: str = "") -> str:
    """Add terms to the Whisper prompt: proper names, products and modules the model gets wrong.

    With profile the terms go only into prompts of that project's calls (preferred). Without it they
    are shared by every transcription, and prompt space is limited (about 120 tokens), so add
    shared terms sparingly.

    Args:
        terms: One or more terms, comma separated (e.g. "Acme CRM, Bitrix24").
        profile: Optional project name (see list_profiles).
    """
    items = [x.strip() for x in terms.split(",") if x.strip()]
    if not items:
        return _err("mcp_no_terms")
    if profile:
        prof = {}
        if profiles.valid_slug(profile):
            with profiles.editing(profile) as prof:
                if prof:
                    prof["terms"], added = vocabs.merge_terms(prof.get("terms", []), items, front=True)
        if not prof:
            return _err("mcp_no_profile_list", profile=profile, known=", ".join(profiles.list_all()))
        return t("mcp_terms_profile", profile=profile, terms=", ".join(added) or t("mcp_nothing_new"))
    with vocabs.editing() as vocab:
        vocab["terms"], added = vocabs.merge_terms(vocab.get("terms", []), items)
    if not added:
        return t("mcp_terms_exist")
    return t("mcp_terms_global", terms=", ".join(added))


def list_profiles() -> str:
    """List Sozvon projects (per-project vocabularies of people, terms and replacements)."""
    profs = profiles.list_all()
    if not profs:
        return t("mcp_no_profiles")
    return t("mcp_profiles") + "\n" + "\n".join(f"  {k}: {v}" for k, v in profs.items())


def preview_prompt(profile: str = "", names: str = "", keywords: str = "") -> str:
    """Show the Whisper prompt a call with these parameters would get, and its token count.

    Args:
        profile: Project name.
        names: Participants, comma separated.
        keywords: Call keywords, comma separated.
    """
    nm = [n.strip() for n in names.split(",") if n.strip()]
    p = prompts.build_prompt(vocabs.load(), profiles.load(profile), nm, keywords)
    return f"{p}\n\n" + t("mcp_prompt_tokens", n=prompts.count_tokens(p), max=prompts.PROMPT_MAX_TOKENS)


def _project_title(slug: str) -> str:
    return profiles.load(slug).get("title", slug) if slug else ""


def list_calls(query: str = "", limit: int = 20) -> str:
    """List calls recorded by Sozvon, newest first: id, date, topic, project, participants, duration.

    Args:
        query: Optional case-insensitive filter over topic, project, participants, summary and transcript.
        limit: Maximum number of calls.
    """
    q = query.strip().lower()
    rows = []
    for c in calls.list_calls():
        project = _project_title(c.profile)
        if q:
            hay = " ".join([c.id, c.topic, project, " ".join(c.people)]).lower()
            if q not in hay and q not in c.text().lower():
                continue
        rows.append((c, project))
        if len(rows) >= limit:
            break
    if not rows:
        return t("mcp_no_calls")
    lines = []
    for c, project in rows:
        state = (t("mcp_has_summary") if c.has_summary else
                 t("mcp_has_transcript") if c.has_transcript else t("mcp_no_transcript"))
        bits = [c.date, c.topic or t("mcp_no_topic"), project, ", ".join(c.people),
                format_timestamp(c.seconds) if c.seconds else "", state]
        lines.append(f"- {c.id}: " + " · ".join(b for b in bits if b))
    return "\n".join(lines)


def get_call(call_id: str, part: str = "summary") -> str:
    """Summary and/or transcript of a Sozvon call.

    Args:
        call_id: Call id from list_calls (the "YYYY-MM-DD HH-MM" date the recording started;
            a second recording in the same minute gets a "-2" suffix).
        part: summary, transcript or both.
    """
    d = calls.find_call(call_id)
    out = []
    if part in ("summary", "both"):
        f = d / "summary.md"
        out.append(f.read_text(encoding="utf-8") if f.exists() else t("mcp_no_summary_file"))
    if part in ("transcript", "both"):
        f = d / "transcript.txt"
        out.append(f.read_text(encoding="utf-8") if f.exists() else t("mcp_no_transcript_file"))
    return "\n\n---\n\n".join(out)


def search_calls(text: str, limit: int = 20) -> str:
    """Find a phrase in all Sozvon call transcripts. Returns matching lines with timestamps and call ids.

    Args:
        text: Phrase to look for (case-insensitive).
        limit: Maximum number of lines.
    """
    q = text.strip().lower()
    if not q:
        return t("mcp_empty_query")
    hits = []
    for c in calls.list_calls():
        f = c.path / "transcript.txt"
        if not f.exists():
            continue
        for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
            if q in line.lower():
                hits.append(f"{c.id}: {line[:300]}")
                if len(hits) >= limit:
                    return "\n".join(hits)
    return "\n".join(hits) if hits else t("mcp_nothing_found")


TOOLS = [transcribe, list_models, show_vocab, add_replacement, remove_replacement, add_terms,
         list_profiles, preview_prompt, list_calls, get_call, search_calls]


def build_server(**kwargs):
    """FastMCP with all Sozvon tools."""
    from mcp.server.fastmcp import FastMCP
    server = FastMCP("sozvon", **kwargs)
    for fn in TOOLS:
        server.tool()(fn)
    return server
