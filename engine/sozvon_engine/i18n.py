"""Engine texts in the app language (SOZVON_UI_LANG: ru or en).

Transcription log, RESULT lines, labels in transcript files, MCP tool responses,
installation and project discovery progress. MCP tool descriptions do not live here: any
user's assistant reads them, so they are always in English (mcp/tools.py).
"""
import os

MESSAGES = {
    # Labels in transcript files
    "speaker": ("Собеседник", "Speaker"),
    "speaker_n": ("Собеседник {n}", "Speaker {n}"),
    "me_plus": ("{me} + собеседники", "{me} + others"),
    "me": ("Я", "Me"),
    "call": ("Звонок", "Call"),
    "duration": ("Длительность", "Duration"),
    "people": ("Участники", "Participants"),
    "transcript": ("Расшифровка", "Transcript"),
    "topic": ("Тема звонка", "Call topic"),
    "keywords": ("Ключевые слова", "Keywords"),
    "voice_n": ("Спикер {n}", "Speaker {n}"),
    "voice_unknown": ("Спикер ?", "Speaker ?"),

    # Transcription log
    "log_profile": ("профиль: {profile}; собеседники: {names}; подсказка {tokens} ток.",
                    "project: {profile}; participants: {names}; prompt {tokens} tokens"),
    "log_bad_profile": ("недопустимое имя проекта {profile!r}, расшифровка без проекта",
                        "invalid project name {profile!r}, transcribing without a project"),
    "log_people_learned": ("в проект {profile} добавлены участники: {names}",
                           "added to project {profile}: {names}"),
    "log_track_speech": ("{file}: речи ~{sec:.0f} с", "{file}: ~{sec:.0f} s of speech"),
    "log_onnx_no_prompt": ("модель {model}: без подсказки Whisper, термины проекта не используются, только автозамены",
                           "model {model}: no Whisper prompt, project terms are not used, only replacements"),
    "log_gigaam_ru_only": ("GigaAM понимает только русский: нерусская речь распознается плохо",
                           "GigaAM understands only Russian: other languages will be recognized poorly"),
    "log_transcribing": ("транскрибация {track} …", "transcribing {track} …"),
    "log_transcribing_model": ("транскрибация {track} ({model}) …", "transcribing {track} ({model}) …"),
    "log_segments": ("{track}: {n} сегментов", "{track}: {n} segments"),
    "log_track_lang": ("{track}: язык {lang} ({share:.0%} среди {allowed})",
                       "{track}: language {lang} ({share:.0%} among {allowed})"),
    "all_languages": ("всех", "all"),
    "log_prompt_retry": ("подсказка с терминами сбила модель, повтор с короткой подсказкой",
                         "the prompt with terms confused the model, retrying with a short prompt"),
    "log_switched": ("{track}: фраз на другом языке: {n}", "{track}: phrases in another language: {n}"),
    "log_echo": ("эхо из динамиков: выкинуто {n} сегментов микрофона",
                 "speaker echo: dropped {n} microphone segments"),
    "log_dead_system": ("системный звук пропадал на {sec:.0f} с, там собеседники разводятся по микрофону",
                        "system audio was missing for {sec:.0f} s, separating speakers on the microphone there"),
    "log_diar_count": ("диаризация: собеседников {n}", "diarization: {n} speakers"),
    "log_diar_mic_count": ("диаризация микрофона: собеседников {n}", "microphone diarization: {n} speakers"),
    "log_diar_failed": ("диаризация не удалась, собеседники без разбивки: {err}",
                        "diarization failed, other speakers are not separated: {err}"),
    "log_diar_mic_failed": ("диаризация микрофона не удалась: {err}", "microphone diarization failed: {err}"),
    "log_summary_start": ("саммари …", "summary …"),
    "log_summary_failed": ("саммари не получилось ({who}): {err}", "summary failed ({who}): {err}"),
    "log_summary_ok": ("саммари: {name} ({vendor})", "summary: {name} ({vendor})"),
    "log_names_failed": ("имена собеседников не определены ({who}): {err}",
                         "speaker names not resolved ({who}): {err}"),
    "log_names_not_json": ("имена собеседников: помощник ответил не JSON",
                           "speaker names: the assistant did not answer with JSON"),
    "log_names_ok": ("имена собеседников: {pairs}", "speaker names: {pairs}"),
    "log_names_unsure": ("имена собеседников: не уверен, оставляю «{speaker}»",
                         "speaker names: not sure, keeping “{speaker}”"),
    "log_names_error": ("имена собеседников: ошибка помощника ({err}), имена по порядку",
                        "speaker names: assistant error ({err}), names in order of appearance"),
    "log_done": ("готово: {path} ({n} реплик)", "done: {path} ({n} paragraphs)"),
    "no_cli": ("нет CLI", "no CLI"),

    # RESULT: error <code> <message>
    "err_no_dir": ("нет папки звонка: {path}", "call folder not found: {path}"),
    "err_bad_call": ("call.json не читается: {err}", "call.json is unreadable: {err}"),
    "err_no_audio": ("в записи нет звука ни на одной дорожке (проверь разрешения на микрофон и запись экрана)",
                     "the recording has no sound on any track (check microphone and screen recording permissions)"),
    "err_unknown_model": ("неизвестная модель {model}; есть: {known}", "unknown model {model}; available: {known}"),
    "err_model_missing": ("модель {model} не скачана", "model {model} is not downloaded"),
    "err_ffmpeg": ("ffmpeg не смог прочитать {file}: {err}", "ffmpeg could not read {file}: {err}"),
    "err_engine": ("движок повреждён: {err}", "the engine is broken: {err}"),

    # MCP tool responses
    "mcp_error": ("ОШИБКА: {msg}", "ERROR: {msg}"),
    "mcp_file_not_found": ("файл не найден: {path}", "file not found: {path}"),
    "mcp_unknown_model": ("неизвестная модель '{model}'. Доступны: {known}", "unknown model '{model}'. Available: {known}"),
    "mcp_model_missing": ("модель '{model}' не скачана, скачай её в настройках Sozvon",
                          "model '{model}' is not downloaded, download it in Sozvon settings"),
    "mcp_bad_ext": ("неподдерживаемое расширение '{ext}'. Аудио: {audio}; видео: {video}",
                    "unsupported extension '{ext}'. Audio: {audio}; video: {video}"),
    "mcp_diar_error": ("диаризация не удалась: {err}", "diarization failed: {err}"),
    "mcp_transcribe_error": ("транскрибация не удалась: {err}", "transcription failed: {err}"),
    "mcp_models": ("Доступные модели:", "Available models:"),
    "mcp_default": ("(по умолчанию)", "(default)"),
    "mcp_not_downloaded": ("(не скачана)", "(not downloaded)"),
    "mcp_replacements": ("replacements (слышит -> правильно):", "replacements (heard -> correct):"),
    "mcp_both_fields": ("оба поля должны быть непустыми.", "both fields must be non-empty."),
    "mcp_no_profile": ("нет профиля '{profile}'.", "no project '{profile}'."),
    "mcp_no_profile_list": ("нет профиля '{profile}'. Есть: {known}", "no project '{profile}'. Available: {known}"),
    "mcp_profile_replacement": ("Профиль {profile}: '{wrong}' -> '{right}'.", "Project {profile}: '{wrong}' -> '{right}'."),
    "mcp_replacement_updated": ("Обновлено: '{wrong}' -> '{right}' (было '{old}').",
                                "Updated: '{wrong}' -> '{right}' (was '{old}')."),
    "mcp_replacement_added": ("Добавлено: '{wrong}' -> '{right}'. Всего замен: {n}.",
                              "Added: '{wrong}' -> '{right}'. Replacements: {n}."),
    "mcp_replacement_not_found": ("Не найдено замены для '{wrong}'.", "No replacement for '{wrong}'."),
    "mcp_replacement_removed": ("Удалено: '{wrong}'. Осталось замен: {n}.", "Removed: '{wrong}'. Replacements left: {n}."),
    "mcp_no_terms": ("не переданы термины.", "no terms given."),
    "mcp_terms_profile": ("Добавлено в профиль {profile}: {terms}.", "Added to project {profile}: {terms}."),
    "mcp_nothing_new": ("ничего нового", "nothing new"),
    "mcp_terms_exist": ("Все термины уже есть.", "All terms are already there."),
    "mcp_terms_global": ("Добавлено в общие термины: {terms}.", "Added to shared terms: {terms}."),
    "mcp_no_profiles": ("Профилей нет.", "No projects."),
    "mcp_profiles": ("Профили:", "Projects:"),
    "mcp_prompt_tokens": ("({n} токенов из {max})", "({n} of {max} tokens)"),
    "mcp_no_calls": ("Звонков не найдено.", "No calls found."),
    "mcp_no_topic": ("(без темы)", "(no topic)"),
    "mcp_has_summary": ("саммари", "summary"),
    "mcp_has_transcript": ("расшифровка", "transcript"),
    "mcp_no_transcript": ("без расшифровки", "no transcript"),
    "mcp_no_summary_file": ("(саммари нет)", "(no summary)"),
    "mcp_no_transcript_file": ("(расшифровки нет)", "(no transcript)"),
    "mcp_empty_query": ("Пустой запрос.", "Empty query."),
    "mcp_nothing_found": ("Ничего не найдено.", "Nothing found."),
    "no_call": ("нет звонка {id}", "no call {id}"),
    "bad_profile_name": ("недопустимое имя проекта: {name!r}", "invalid project name: {name!r}"),
    "mcp_no_token": ("SOZVON_MCP_TOKEN не задан: без токена сервер не запускаем",
                     "SOZVON_MCP_TOKEN is not set: refusing to start without a token"),

    # Project discovery (STATUS: …)
    "discover_start": ("Запускаю {name}…", "Starting {name}…"),
    "discover_agents": ("Смотрю открытые сессии", "Looking at open sessions"),
    "discover_ask": ("Спрашиваю сессию «{who}» ({n})", "Asking session “{who}” ({n})"),
    "discover_read": ("Читаю заметки: {what} ({n})", "Reading notes: {what} ({n})"),
    "discover_search": ("Ищу по истории проектов", "Searching project history"),
    "discover_done": ("Собираю проекты…", "Putting projects together…"),
    "discover_no_cli": ("Не найден ни Claude Code, ни Codex CLI.", "Neither Claude Code nor Codex CLI was found."),
    "discover_failed": ("Не получилось: {err}", "Failed: {err}"),
    "discover_no_list": ("Не вернулся список проектов: {out}", "No project list returned: {out}"),
    "discover_new": ("Новых проектов: {n}", "New projects: {n}"),
    "discover_updated": (". Дополнено: {n}", ". Updated: {n}"),

    # Installation (the app parses "==> …" lines)
    "install_model": ("Скачиваю модель {model} (один раз)", "Downloading the {model} model (once)"),
    "install_pyannote": ("Скачиваю модели разбивки по голосам (31 МБ)", "Downloading speaker separation models (31 MB)"),
    "install_no_diarization": ("ВНИМАНИЕ: модели разбивки по голосам не скачались, расшифровка будет без неё.",
                               "WARNING: speaker separation models failed to download; transcripts will not separate speakers."),
    "install_done": ("Готово", "Done"),
}

LANGS = ("ru", "en")


def lang() -> str:
    """ru if the app is in Russian; otherwise en."""
    return "ru" if (os.environ.get("SOZVON_UI_LANG") or "ru").lower().startswith("ru") else "en"


def t(key: str, **kw) -> str:
    ru, en = MESSAGES[key]
    return (ru if lang() == "ru" else en).format(**kw)
