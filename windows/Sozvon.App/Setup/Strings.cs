using System.Globalization;
using Sozvon.Core.Foundation;
using Sozvon.Core.Settings;

namespace Sozvon.App.Setup;

/// <summary>The wizard's text. Keys are the Russian strings, as in Sources/Sozvon/Resources/en.lproj/Localizable.strings.</summary>
internal static class Strings
{
    /// <summary>Windows' language until <see cref="Initialize"/> applies the app's "Язык интерфейса" setting.</summary>
    public static bool IsRussian { get; private set; } = SystemIsRussian;

    private static bool SystemIsRussian => CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru";

    /// <summary>
    /// The wizard is its own process and follows the app's setting from settings.json in <paramref name="dataFolder"/>;
    /// Windows' language only while the setting is "System" or the file does not exist yet, as on the first run.
    /// </summary>
    public static void Initialize(string dataFolder) =>
        IsRussian = UiLanguage.IsRussian(SharedFile.ReadText(Path.Combine(dataFolder, "settings.json")), SystemIsRussian);

    /// <summary>The value of SOZVON_UI_LANG.</summary>
    public static string EngineLanguage => IsRussian ? "ru" : "en";

    public static string L(string key, params object[] arguments)
    {
        var text = IsRussian ? key : English.GetValueOrDefault(key, key);
        foreach (var argument in arguments)
        {
            var index = text.IndexOf("%@", StringComparison.Ordinal);
            if (index < 0)
            {
                break;
            }
            text = string.Concat(text.AsSpan(0, index), argument.ToString(), text.AsSpan(index + 2));
        }
        return text;
    }

    public static string Gigabytes(double size) =>
        L("%@ ГБ", size.ToString("0.0", IsRussian ? CultureInfo.GetCultureInfo("ru-RU") : CultureInfo.InvariantCulture));

    private static readonly Dictionary<string, string> English = new()
    {
        ["Настройка Sozvon"] = "Sozvon setup",
        ["Шаг %@ из %@"] = "Step %@ of %@",
        ["Назад"] = "Back",
        ["Продолжить"] = "Continue",
        ["Пропустить"] = "Skip",
        ["Готово"] = "Done",
        ["%@ ГБ"] = "%@ GB",
        ["Не нашёл файлы движка. Переустанови Sozvon."] = "The engine files were not found. Reinstall Sozvon.",

        ["Добро пожаловать в Sozvon"] = "Welcome to Sozvon",
        ["Нажал значок в области уведомлений, созвонился, остановил. Дальше расшифровка и саммари на этом компьютере."] = "Click the icon in the notification area, take the call, stop. Transcript and summary follow, on this PC.",
        ["Одна кнопка"] = "One button",
        ["Запись включается в плавающей капсуле или значком в области уведомлений. Когда приложение для звонков включает микрофон, Sozvon предлагает записать: по умолчанию он только спрашивает и сам ничего не пишет."] = "Start recording from the floating capsule or the notification area icon. When a call app turns on the microphone, Sozvon offers to record: by default it only asks and never records on its own.",
        ["Локально"] = "Private",
        ["Расшифровка идёт на компьютере. Ничего не покидает его, пока ты не включишь саммари через ассистента."] = "Transcription runs on your PC. Nothing leaves it until you turn on summaries by an assistant.",
        ["Кто что сказал"] = "Who said what",
        ["Реплики разбиваются по голосам. Запомни голоса один раз, и имена подставятся сами."] = "Lines are split by voice. Remember voices once, and names fill in by themselves.",
        ["Саммари"] = "Summary",
        ["Коротко, решения и задачи через ассистента. Потом можно спросить его о любом звонке."] = "Summary, decisions and action items by an assistant. Later, ask it about any call.",

        ["Помощник для саммари"] = "Summary assistant",
        ["Кто будет писать «Коротко», «Решения» и «Задачи». Текст звонка уходит в сервис помощника, аудио остаётся на компьютере."] = "Who writes the Summary, Decisions and Action items. The call text goes to the assistant's service, the audio stays on your PC.",
        ["установлен"] = "installed",
        ["не найден"] = "not found",
        ["Без саммари"] = "No summary",
        ["Текст уходит в Anthropic. Потом можно спрашивать о звонках прямо в терминале."] = "Text goes to Anthropic. Later, ask about your calls right in the terminal.",
        ["Текст уходит в OpenAI. Потом можно спрашивать о звонках в Codex."] = "Text goes to OpenAI. Later, ask about your calls in Codex.",
        ["Текст уходит в Cursor и к выбранной там модели. Потом можно спрашивать о звонках в Cursor."] = "Text goes to Cursor and the model chosen there. Later, ask about your calls in Cursor.",
        ["Только расшифровка. Ничего не покидает компьютер. Можно включить позже в Настройках."] = "Transcripts only. Nothing leaves your PC. You can turn summaries on later in Settings.",
        ["Не проверено на Windows"] = "Not verified on Windows",
        ["Язык саммари"] = "Summary language",
        ["Как в разговоре"] = "Same as the conversation",
        ["Этот ассистент не проверялся на Windows с настоящей программой, его песочница тоже. Текст звонка уходит выбранному ассистенту."] = "This assistant has not been verified on Windows with the real CLI, nor has its sandbox. The text of the call goes to the chosen assistant.",
        ["Этот ассистент не проверялся на Windows с настоящей программой, его песочница тоже. Текст звонка уходит выбранному ассистенту. У Cursor на Windows может не быть файловой песочницы."] = "This assistant has not been verified on Windows with the real CLI, nor has its sandbox. The text of the call goes to the chosen assistant. Cursor may have no file sandbox on Windows.",

        ["Пара деталей"] = "A few details",
        ["Имя пишется в расшифровке рядом с твоими репликами. Языки помогают модели не путать слова."] = "Your name appears in the transcript next to your lines. Languages keep the model from mixing up words.",
        ["Как тебя подписывать"] = "Your name",
        ["Аня"] = "Anna",
        ["Языки звонков"] = "Call languages",
        ["Русский"] = "Russian",
        ["Українська"] = "Ukrainian",
        ["Определять сам"] = "Detect automatically",
        ["Расшифровка уступает твоим программам: при звонке она не мешает Zoom и браузеру."] = "Transcription yields to your apps: during a call it does not slow down Zoom or the browser.",
        ["Папка звонков"] = "Calls folder",
        ["Сменить папку…"] = "Change folder…",
        ["Выбрать"] = "Choose",
        ["Сейчас идёт запись или расшифровка"] = "A recording or transcription is running",
        ["Папку звонков можно сменить, когда они закончатся."] = "You can change the calls folder when it’s done.",
        ["Эта папка не подходит"] = "This folder won’t work",
        ["Перенести звонки в «%@»?"] = "Move your calls to “%@”?",
        ["Звонков: %@. Они переедут из «%@» вместе с аудио и заметками. Если не переносить, Sozvon будет показывать только звонки из новой папки, а старые останутся на месте."] = "Calls: %@. They move from “%@” with their audio and notes. If you don’t move them, Sozvon shows only the calls in the new folder and the old ones stay where they are.",
        ["Перенести"] = "Move",
        ["Не переносить"] = "Don’t move",
        ["Отмена"] = "Cancel",
        ["OK"] = "OK",
        ["Переношу звонки…"] = "Moving calls…",
        ["Переношу звонки: %@ из %@"] = "Moving calls: %@ of %@",
        ["В новой папке уже есть звонки с такими же именами: %@. Ничего не перенесено."] = "The new folder already has calls with the same names: %@. Nothing was moved.",
        ["Копия звонка «%@» не совпала с оригиналом. Оригинал остался на месте, папка не сменилась."] = "The copy of “%@” didn’t match the original. The original stayed, and the folder didn’t change.",
        ["Не получилось перенести звонки"] = "Couldn’t move the calls",
        ["Она внутри нынешней папки звонков. Выбери папку рядом или в другом месте."] = "It’s inside the current calls folder. Pick a folder next to it or elsewhere.",
        ["Нынешняя папка звонков лежит внутри неё. Выбери другую папку."] = "The current calls folder is inside it. Pick another folder.",
        ["Это папка движка Sozvon: при переустановке звонки пропали бы. Выбери другую."] = "This is the Sozvon engine folder: a reinstall would take the calls with it. Pick another one.",

        ["Модель распознавания"] = "Speech model",
        ["Модель скачается один раз и будет работать на этом компьютере. Точнее обычно значит медленнее."] = "The model is downloaded once and runs on this PC. More accurate usually means slower.",
        ["рекомендуем"] = "recommended",
        ["скачана"] = "downloaded",
        ["Быстро и точно."] = "Fast and accurate.",
        ["Самая точная, примерно в 2 раза медленнее Turbo."] = "Most accurate, about 2× slower than Turbo.",
        ["Лёгкая: для компьютеров с 8 ГБ памяти и экономии места. Точность ниже."] = "Lightweight: for PCs with 8 GB of memory or to save space. Less accurate.",
        ["Только русский, от Сбера. Лёгкая и быстрая, но без словаря проектов."] = "Russian only, by Sber. Light and fast, but no project vocabulary.",
        ["25 европейских языков, от NVIDIA. Очень быстрая, но без словаря проектов."] = "25 European languages, by NVIDIA. Very fast, but no project vocabulary.",
        ["Русские разговоры через GigaAM"] = "Russian conversations with GigaAM",
        ["Ещё %@. Whisper определит язык каждой дорожки, русскую расшифрует GigaAM."] = "%@ more. Whisper detects each track’s language, GigaAM transcribes the Russian ones.",
        ["Ускорить на видеокарте NVIDIA"] = "Accelerate with an NVIDIA GPU",
        ["Найдена %@. Скачается ещё несколько ГБ. Без ускорения всё работает на процессоре, только медленнее."] = "Found %@. Several more GB will be downloaded. Without it, everything works on the processor, only slower.",
        ["Скачать и продолжить"] = "Download and continue",

        ["Установка движка"] = "Install the engine",
        ["Python, модель Whisper и разбивка по голосам скачаются один раз, 2-4 ГБ. Обычно 5-10 минут."] = "Python, the Whisper model and speaker separation are downloaded once, 2-4 GB. Usually 5-10 minutes.",
        ["Движок установлен"] = "Engine installed",
        ["Python, модель и разбивка по голосам на месте. Первая расшифровка займёт чуть дольше: модель прогревается."] = "Python, the model and speaker separation are in place. The first transcription takes a bit longer while the model warms up.",
        ["Начинаю установку…"] = "Starting the installation…",
        ["Подробности"] = "Details",
        ["Что-то пошло не так."] = "Something went wrong.",
        ["Лог лежит в setup.log в папке данных."] = "See setup.log in the data folder.",
        ["Открыть журнал"] = "Open log",
        ["Продолжить установку"] = "Resume install",
        ["Повторить"] = "Try again",
        ["Установка остановлена. Скачанное сохранится, продолжить можно в любой момент."] = "Install stopped. What's downloaded is kept; you can resume anytime.",
        ["Своя копия внутри Sozvon, системный Python не трогается"] = "Its own copy inside Sozvon, the system Python is not touched",
        ["%@, скачана и проверена"] = "%@, downloaded and verified",
        ["Разбивка по голосам"] = "Speaker separation",
        ["pyannote, работает на этом компьютере"] = "pyannote, runs on this PC",
        ["Модели не скачались, расшифровка будет без разбивки по голосам"] = "The models were not downloaded, transcripts will have no speaker separation",
        ["Проверяю, отвечает ли ассистент…"] = "Checking that the assistant answers…",
        ["Отвечает"] = "Answers",
        ["не найден %@"] = "%@ not found",
        ["%@ не ответил: %@"] = "%@ did not answer: %@",
        ["%@ не ответил. Подробности в assistant.log"] = "%@ did not answer. Details are in assistant.log",
        ["%@ не ответил за %@ с"] = "%@ did not answer in %@ s",

        ["Разрешения"] = "Permissions",
        ["Без микрофона звонок не записать. Звук компьютера разрешения не требует."] = "Without the microphone a call can't be recorded. The computer's sound needs no permission.",
        ["Микрофон"] = "Microphone",
        ["Твой голос"] = "Your voice",
        ["Разрешено"] = "Allowed",
        ["Запрещено"] = "Blocked",
        ["Открыть настройки"] = "Open Settings",
        ["Микрофон заблокирован."] = "Microphone blocked.",
        ["Разреши его в Параметрах: Конфиденциальность и защита > Микрофон."] = "Allow it in Settings: Privacy & security > Microphone.",
        ["Пробная запись"] = "Test recording",
        ["Три секунды с микрофона, в память. Ничего не сохраняется"] = "Three seconds from the microphone, in memory. Nothing is saved",
        ["Пишу три секунды…"] = "Recording three seconds…",
        ["Микрофон записывается"] = "Your microphone is recording",
        ["Проверить"] = "Check",
        ["Ещё раз"] = "Try again",
        ["Получилось"] = "Works",
        ["Запись запустилась, но микрофон не прислал звук. Проверь, какой микрофон выбран в Параметрах Windows: Система > Звук."] = "The recording started, but the microphone sent no sound. Check which microphone is selected in Windows Settings: System > Sound.",
        ["Не удалось открыть микрофон (код %@). Проверь разрешение и выбранный микрофон в Параметрах Windows."] = "Couldn't open the microphone (code %@). Check the permission and the selected microphone in Windows Settings.",
        ["Согласие собеседников на запись на тебе."] = "Getting the other participants' consent to record is up to you.",

        ["Проекты"] = "Projects",
        ["Проект это команда и её слова: имена, продукты, термины. С ними расшифровка точнее, а саммари знает, о ком речь."] = "A project is a team and its words: names, products, terms. With them the transcript is more accurate, and the summary knows who is who.",
        ["Найти проекты через ассистента"] = "Find projects with an assistant",
        ["Пока недоступно на Windows"] = "Not available on Windows yet",
        ["Проекты можно завести позже: страница «Проекты» в главном окне."] = "You can add projects later on the Projects page in the main window.",
        ["Значок может быть скрыт"] = "The icon may be hidden",
        ["Windows 11 может спрятать новый значок. Нажми стрелку рядом с часами и перетащи Sozvon в область уведомлений."] = "Windows 11 may hide new icons. Click the arrow next to the clock and drag Sozvon into the notification area.",
    };
}
