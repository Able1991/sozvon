<p align="center"><img src="docs/images/icon.png" width="128" alt="Sozvon"></p>

<h1 align="center">Sozvon</h1>

<p align="center">Записывает созвоны на Mac и расшифровывает их локально: кто что сказал, с таймкодами, плюс саммари с решениями и задачами.</p>

<p align="center">
<a href="https://github.com/Able1991/sozvon/actions/workflows/ci.yml"><img src="https://github.com/Able1991/sozvon/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
<a href="https://github.com/Able1991/sozvon/actions/workflows/security.yml"><img src="https://github.com/Able1991/sozvon/actions/workflows/security.yml/badge.svg" alt="Security"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT"></a>
</p>

<p align="center"><b><a href="https://github.com/Able1991/sozvon/releases/latest/download/Sozvon.dmg">Скачать для Mac</a></b> · <a href="https://able1991.github.io/sozvon/">Сайт</a> · <a href="https://able1991.github.io/sozvon/docs.html">Документация</a> · <a href="README.md">English</a></p>

<p align="center"><img src="docs/images/ru-calls.png" width="820" alt="Окно «Звонки»"></p>

## Что умеет

- **Одна кнопка.** Плавающая панель поверх всех окон (и поверх Zoom на весь экран) или значок в строке меню: «Записать», созвонился, «Стоп». Работает с Zoom, Google Meet, Telegram, TrueConf, чем угодно: пишется звук компьютера и микрофон, без виртуальных аудиодрайверов.
- **Локально.** Распознавание и разбивка по голосам идут на Apple Silicon. Звук не покидает Mac.
- **Кто что сказал.** Твой голос и собеседники на разных дорожках, собеседники разводятся по голосам, а помощник подписывает их по именам по смыслу разговора («Маша, как у тебя?»).
- **Саммари** на языке разговора: коротко, решения, задачи с исполнителями, открытые вопросы. Через Claude Code или Codex по твоей подписке, по желанию.
- **Проекты.** Люди, термины и автозамены по каждому клиенту, чтобы распознавание правильно писало имена и жаргон. Проекты можно найти автоматически по сессиям Claude Code или Codex.
- **Окно «Звонки».** Список по дням, поиск по всему, включая текст расшифровок, карточка с саммари и расшифровкой.
- **Claude и Codex видят звонки** через MCP: «что решили с клиентом на прошлой неделе?».
- **Несколько языков** в одном звонке, русский и английский интерфейс, светлая и тёмная тема.

<p align="center">
<img src="docs/images/ru-panel.png" width="300" alt="Плавающая панель">
&nbsp;
<img src="docs/images/ru-menu.png" width="250" alt="Меню">
</p>

## Установка

1. Скачай `Sozvon.dmg` со страницы [Releases](https://github.com/Able1991/sozvon/releases/latest) и перетащи Sozvon в «Программы». Приложение подписано и нотаризовано Apple.
2. Запусти. Мастер спросит имя, язык звонков, модель распознавания и помощника для саммари, затем сам поставит движок: 5-10 минут, 1-4 ГБ в зависимости от модели. Токены и регистрации не нужны.
3. Разреши «Микрофон» и «Запись экрана и системного аудио». Видео не записывается, только звук.

**Требования:** Mac на Apple Silicon (M1 и новее), macOS 15 Sequoia или новее. Для саммари и поиска проектов: установленный [Claude Code](https://claude.com/code) или [Codex CLI](https://github.com/openai/codex), необязательно.

<p align="center">
<img src="docs/images/ru-setup-model.png" width="360" alt="Выбор модели">
&nbsp;
<img src="docs/images/ru-callinfo.png" width="360" alt="После звонка">
</p>

## Модели распознавания

| Модель | Размер | Языки | Особенности |
|---|---|---|---|
| **Whisper Turbo** (рекомендуем) | 1,6 ГБ | 99 | Быстро и точно, понимает словарь проекта |
| Whisper Large v3 | 3,1 ГБ | 99 | Самая точная, примерно в 2 раза медленнее |
| Whisper Small | 0,5 ГБ | 99 | Для Mac с 8 ГБ памяти |
| GigaAM v3 (Сбер) | 0,2 ГБ | русский | Лёгкая и быстрая, без словаря проектов |
| Parakeet v3 (NVIDIA) | 0,7 ГБ | 25 европейских | Очень быстрая, без словаря проектов |

Разбивка по голосам: [pyannote](https://github.com/pyannote/pyannote-audio) (31 МБ, ставится вместе с приложением). Модель меняется в «Настройки → Распознавание». Там же «Не мешать работе»: расшифровка уступает другим программам.

## Claude Code и Codex (MCP)

«Настройки → Claude и Codex → Подключить». Sozvon держит один общий MCP-сервер на `127.0.0.1` для всех сессий (около 40 МБ), пока запущен. Ассистент получает инструменты:

| Инструмент | Что делает |
|---|---|
| `list_calls` | список звонков: дата, тема, проект, люди, длительность; фильтр по любому тексту |
| `get_call` | саммари и/или расшифровка звонка |
| `search_calls` | поиск фразы по всем расшифровкам, с таймкодами |
| `transcribe` | расшифровать любой аудио- или видеофайл |
| `list_profiles`, `add_terms`, `add_replacement` | проекты, термины и автозамены |

Подключить вручную и все подробности: [документация](https://able1991.github.io/sozvon/docs.html#mcp). Сервер требует пароль из `~/Library/Application Support/Sozvon/.mcp-token`.

## Что уходит в сеть

| Что | Куда | Когда |
|---|---|---|
| Запись, расшифровка, разбивка по голосам | никуда, только `~/Documents/Calls` | всегда |
| Python-окружение, модели | PyPI, huggingface.co | один раз при установке |
| Бинарник uv (если его нет), CPython для `uv sync`, запасной архив моделей разбивки (релиз `models-v1`) | github.com | один раз при установке |
| Текст расшифровки для саммари и имён | Anthropic (Claude Code) или OpenAI (Codex) | только если выбран помощник |
| То, что читает ассистент через MCP | Anthropic или OpenAI | только когда ты его спрашиваешь |
| Поиск проектов: названия папок проектов, заметки памяти в `~/.claude` (или сессии в `~/.codex`), ответы открытых сессий. Claude ограничен чтением внутри `~/.claude`. Codex запускается в песочнице `read-only`: она запрещает запись, но не чтение, и что он прочитает, решает сама модель | Anthropic или OpenAI | только по кнопке «Найти проекты» |
| Проверка новой версии | api.github.com | раз в сутки, отключается |

Никакой телеметрии и своих серверов. Выбери «Только локально», и ничего, кроме проверки обновлений, не покинет Mac. Каждый коммит проверяют [Gitleaks](https://github.com/gitleaks/gitleaks), [Semgrep](https://semgrep.dev) и [CodeQL](https://codeql.github.com).

## Устройство

```
Package.swift       SwiftPM: SozvonCore (логика, покрыта тестами) + Sozvon (приложение)
Sources/SozvonCore/ состояние записи, очередь расшифровки, запуск движка, call.json, настройки
Sources/Sozvon/     строка меню, запись (ScreenCaptureKit), панель, окна на SwiftUI, MCP-сервер
Tests/              XCTest для SozvonCore
engine/
  sozvon_engine/    движок: распознавание, pyannote, языки, словари, проекты, саммари, MCP
  bin/              process_call.py (полный цикл), discover_projects.py (поиск проектов)
  server.py         MCP-сервер (stdio или общий HTTP)
  models.json       модели с закреплёнными версиями
  setup.sh          установка движка в ~/Library/Application Support/Sozvon
docs/               сайт (GitHub Pages), CONTRACT.md (договор приложения и движка), SIGNING.md
build.sh            сборка .app и .dmg, подпись, нотаризация
```

После «Стоп»: дорожки выравниваются → распознавание с подсказкой из проекта → удаление эха собеседника из микрофона → разбивка по голосам → имена по смыслу → `transcript.md`, `summary.md`.

## Сборка и тесты

```bash
git clone https://github.com/Able1991/sozvon && cd sozvon
./test.sh              # Python, Swift, проверка переводов
SLOW=1 ./test.sh       # плюс сквозные тесты на настоящем Whisper
./build.sh install     # ~/Applications/Sozvon.app
./build.sh dmg         # build/Sozvon.dmg
```

Нужны Xcode Command Line Tools и [uv](https://docs.astral.sh/uv/). Подпись и релизы: [docs/SIGNING.md](docs/SIGNING.md).

## Лицензия

MIT. Модели: Whisper (MIT), pyannote (MIT, CC BY 4.0), GigaAM (MIT), Parakeet (CC BY 4.0).
