"""MCP tools: thin wrappers over the package.

Tool descriptions are in English: any user's Claude, Codex or Cursor reads them.
Human-readable texts in responses are in the app language (SOZVON_UI_LANG).
"""
import sqlite3
import sys
import threading
from pathlib import Path

from .. import audio, calls, diarize, models, notes, paths, profiles, whisper
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
        language: Language code (ru, en, ...) or auto to detect it. Default: ru.
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
    language = language.strip().lower() if isinstance(language, str) else ""
    language = None if language in ("", "auto") else language
    vocab = vocabs.load()
    prof = profiles.load(profile)
    cleanup = None
    try:
        if ext in audio.VIDEO_EXTS:
            path = cleanup = audio.extract_audio(path)
        v = prompts.vocab_for_language(vocab, language)
        raw, _ = whisper.whisper_with_fallback(
            path, model_path, language, prompts.build_prompt(v, prof, keywords=keywords, lang=language),
            # Word times: a line starts where its speech starts, not where the silence before it does.
            prompts.base_prompt(v, prof, lang=language), word_timestamps=True)
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
    """List calls recorded by Sozvon, newest first: id (the date and time it started), topic, project, participants, duration, notes.

    Args:
        query: Optional case-insensitive filter over topic, project, participants, summary, transcript and notes.
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
        # The id already is the date; empty parts are left out.
        bits = [c.topic, project, ", ".join(c.people),
                format_timestamp(c.seconds) if c.seconds else "", state,
                t("mcp_notes_n", n=len(c.notes)) if c.notes else ""]
        lines.append(f"- {c.id}: " + " · ".join(b for b in bits if b))
    return "\n".join(lines)


def get_call(call_id: str, part: str = "summary") -> str:
    """Summary and/or transcript of a Sozvon call, followed by its notes (if any).

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
    items = notes.notes_of(calls.read_call(d))
    if items:
        out.append(notes.format_section(items, t("mcp_notes")))
    return "\n\n---\n\n".join(out)


def add_note(call_id: str, text: str, source: str = "") -> str:
    """Add a note to a call: shown in the Calls window of the Sozvon app and found by search_calls.

    The MCP tool (see build_server) passes the client name as source.
    """
    d = calls.find_call(call_id)
    try:
        notes.add(d, text, source or "assistant")
    except notes.NoteError as e:
        return t("mcp_error", msg=str(e))
    _push_notes_later(d)
    return t("mcp_note_added", id=calls.call_id(d))


def delete_note(call_id: str, note_id: str) -> str:
    """Delete a note from a Sozvon call, when the user asks for it.

    The note disappears from the Sozvon app on the user's Mac and from their own server. get_call
    lists each note as "- date time · source · note id: text".

    Args:
        call_id: Call id from list_calls or search_calls.
        note_id: The note's id from get_call.
    """
    d = calls.find_call(call_id)
    try:
        notes.delete(d, note_id)
    except notes.NoteError as e:
        return t("mcp_error", msg=str(e))
    _push_notes_later(d)
    return t("mcp_note_deleted", note=note_id.strip(), id=calls.call_id(d))


def _push_notes_later(d: Path) -> None:
    """Best effort: send the notes (and deletions) to the own server now (the next sync sends them anyway)."""
    def run():
        try:
            from .. import remote
            remote.push_notes(d)
        except Exception as e:  # noqa: BLE001  never affects the tool result
            print(f"sozvon: note not sent to the server yet: {type(e).__name__}", file=sys.stderr)
    threading.Thread(target=run, daemon=True).start()


ADD_NOTE_DOC = """Add a note (a comment) to a Sozvon call: a decision, a follow-up, a correction, context for later.

    The user sees notes under the call in the Sozvon app on their Mac; get_call shows them and
    search_calls finds them. Notes can't be edited; delete_note removes one. At most 4000
    characters per note and 200 notes per call.

    Args:
        call_id: Call id from list_calls or search_calls.
        text: The note, plain text.
    """


def client_name(ctx) -> str:
    """MCP client name from the request context: clientInfo, otherwise the User-Agent header."""
    try:
        params = ctx.session.client_params
        if params is not None and params.clientInfo.name:
            return params.clientInfo.name
    except Exception:  # noqa: BLE001
        pass
    try:
        return ctx.request_context.request.headers.get("user-agent", "")
    except Exception:  # noqa: BLE001
        return ""


def _substring_search(queries: list[str], limit: int) -> str:
    """Fallback when the index can't work: case-insensitive substring over transcript.txt lines."""
    qs = [q.lower() for q in queries]
    hits = []
    for c in calls.list_calls():
        f = c.path / "transcript.txt"
        if not f.exists():
            continue
        for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
            if any(q in line.lower() for q in qs):
                hits.append(f"{c.id}: {line[:300]}")
                if len(hits) >= limit:
                    return "\n".join(hits)
    return "\n".join(hits) if hits else t("mcp_nothing_found")


def _trim(text: str, n: int = 300) -> str:
    return text if len(text) <= n else text[:n - 1].rstrip() + "…"


def search_calls(text: str, limit: int = 20, also: list[str] | None = None) -> str:
    """Search all Sozvon call transcripts, summaries and notes, best matches first.

    Ranked full-text search: words match by stem in Russian and English ("budgets" finds "budget"),
    and lines that contain more of the query words rank higher. Speech is transcribed as spoken,
    so pass also: 2-3 alternative phrasings of how the answer was likely said (the other language,
    synonyms, colloquial wording, product or people names). All phrasings are searched and fused.

    Each line: call id: [timestamp] speaker: utterance (call topic · project). Summary lines show
    the summary section instead of a timestamp and speaker, note lines the date and who added the note.
    Open a call with get_call(call_id).

    Args:
        text: What to look for: keywords, a phrase or a short question.
        limit: Maximum number of lines.
        also: Optional 2-3 alternative phrasings of the same query.
    """
    # Bounded input: an assistant may paste a whole document as the query.
    queries = [q.strip()[:500] for q in [text, *(also or [])[:5]] if isinstance(q, str) and q.strip()]
    if not text.strip():
        return t("mcp_empty_query")
    limit = max(1, min(int(limit), 200))
    try:
        from .. import search
        hits = search.search(queries[0], also=queries[1:], limit=limit)
    except (ImportError, sqlite3.Error, OSError) as e:
        print(f"sozvon: search index unavailable, substring search: {e}", file=sys.stderr)
        return _substring_search(queries, limit)
    if not hits:
        return t("mcp_nothing_found")
    titles: dict[str, str] = {}
    lines = []
    for h in hits:
        if h.profile not in titles:
            titles[h.profile] = _project_title(h.profile)
        if h.kind == "summary":
            where = f"[{t('mcp_has_summary')}] {h.speaker}".strip()
        elif h.kind == "note":
            where = f"[{t('mcp_note')} {h.ts}] {h.speaker}".strip()
        else:
            where = (f"[{h.ts}] " if h.ts else "") + h.speaker
        about = " · ".join(b for b in (h.topic, titles[h.profile]) if b)
        lines.append(f"{h.call_id}: " + (f"{where.strip()}: " if where else "") + _trim(h.text)
                     + (f" ({about})" if about else ""))
    return "\n".join(lines)


TOOLS = [transcribe, list_models, show_vocab, add_replacement, remove_replacement, add_terms,
         list_profiles, preview_prompt, list_calls, get_call, search_calls]


def build_server(**kwargs):
    """FastMCP with all Sozvon tools."""
    from mcp.server.fastmcp import Context, FastMCP
    server = FastMCP("sozvon", **kwargs)
    for fn in TOOLS:
        server.tool()(fn)

    def add_note_tool(call_id: str, text: str, ctx: Context) -> str:
        return add_note(call_id, text, source=notes.source_name(client_name(ctx)))
    add_note_tool.__doc__ = ADD_NOTE_DOC
    server.tool(name="add_note")(add_note_tool)
    server.tool(name="delete_note")(delete_note)
    return server
