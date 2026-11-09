using Sozvon.App.Strings;

namespace Sozvon.App.Calls;

/// <summary>The demo call shown only when there are no real calls: in memory, marked Demo, with no audio.</summary>
public static class DemoCall
{
    public static CallRecord Create()
    {
        var ru = Loc.IsRussian;
        return new CallRecord
        {
            Folder = "",
            Id = "demo",
            CreatedAt = DateTimeOffset.Now,
            Status = CallStatus.Done,
            IsDemo = true,
            Topic = ru ? "Acme · запуск" : "Acme · launch",
            ProjectSlug = "acme",
            ProjectTitle = "Acme",
            People = ru ? ["Анна Петрова", "Иван"] : ["Anna Petrova", "Ivan"],
            MicSeconds = 1363,
            InlineContent = ru ? Russian : English,
        };
    }

    private static readonly CallContent Russian = new(
        """
        [00:42] Я: Начнём с даты запуска.
        [00:51] Анна Петрова: Я за четверг, в пятницу у нас заморозка.
        [01:04] Иван: Тогда ключи нужны уже во вторник.
        [01:12] Анна Петрова: Выдам до конца дня понедельника.
        """,
        """
        ## Коротко
        Договорились запускать в четверг. Ключи будут готовы заранее.

        ## Решения
        - Запуск в четверг, в пятницу заморозка

        ## Задачи
        - [ ] Анна Петрова: выдать ключи до конца понедельника
        - [x] Иван: подготовить чек-лист запуска

        ## Открытые вопросы
        - Кто дежурит в выходные?
        """);

    private static readonly CallContent English = new(
        """
        [00:42] Me: Let's start with the launch date.
        [00:51] Anna Petrova: I'd go with Thursday, Friday is a freeze for us.
        [01:04] Ivan: Then we need the keys by Tuesday.
        [01:12] Anna Petrova: I'll issue them by the end of Monday.
        """,
        """
        ## Summary
        Agreed to launch on Thursday. The keys will be ready ahead of time.

        ## Decisions
        - Launch on Thursday, Friday is a freeze

        ## Action items
        - [ ] Anna Petrova: issue the keys by the end of Monday
        - [x] Ivan: prepare the launch checklist

        ## Open questions
        - Who is on call over the weekend?
        """);
}
