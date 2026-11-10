using Sozvon.Core.Settings;

namespace Sozvon.Core.Calls;

/// <summary>
/// The user's own voice sample, as on the Mac: a short text read aloud in a call language (not the interface's:
/// the voice print should hear the language spoken on calls), at least 10 s and at most 25 s of recording.
/// </summary>
public static class VoiceSample
{
    public static readonly TimeSpan MinDuration = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan MaxDuration = TimeSpan.FromSeconds(25);

    /// <summary>The pace the texts are written for: about twenty seconds of reading.</summary>
    public static readonly TimeSpan ReadDuration = TimeSpan.FromSeconds(20);

    /// <summary>Simple words on purpose. Other languages get no text: the user speaks freely.</summary>
    public static string? Text(SpeechLanguage language) => language switch
    {
        SpeechLanguage.Ru => "Привет. Я работаю каждый день. Утром я пью кофе и читаю почту. Потом у меня созвоны с командой. Мы говорим о работе, сроках и деньгах. Днём я много пишу и читаю. Вечером я иду домой. Я люблю гулять, читать книги и смотреть фильмы. В выходные я встречаюсь с друзьями. Я люблю лето и море.",
        SpeechLanguage.En => "Hello. I work every day. In the morning I drink coffee and read my email. Then I have calls with my team. We talk about work, time and money. In the afternoon I write and read a lot. In the evening I go home. I like to walk, read books and watch films. On the weekend I meet my friends. I like summer and the sea.",
        _ => null,
    };

    /// <summary>The call languages from Settings; none picked ("detect automatically") means Russian and English.</summary>
    public static List<SpeechLanguage> Languages(IEnumerable<SpeechLanguage> callLanguages)
    {
        var real = callLanguages.Where(l => l != SpeechLanguage.Auto).Distinct().ToList();
        return real.Count == 0 ? [SpeechLanguage.Ru, SpeechLanguage.En] : real;
    }

    /// <summary>How many words of the text are due after <paramref name="elapsed"/> of reading; all when not recording.</summary>
    public static int WordsRead(string text, TimeSpan elapsed, bool recording)
    {
        var words = text.Split(' ').Length;
        if (!recording) return words;
        return (int)(words * Math.Min(1, Math.Max(0, elapsed / ReadDuration)));
    }

    /// <summary>The meter's 0…1 from the RMS of the last samples (−50 dB and below is 0), as AVAudioRecorder's average power.</summary>
    public static double Level(double rms)
    {
        if (rms <= 0) return 0;
        var db = 20 * Math.Log10(rms);
        return Math.Clamp((db + 50) / 50, 0, 1);
    }

    /// <summary>"0:07".</summary>
    public static string Clock(TimeSpan t)
    {
        var s = (int)t.TotalSeconds;
        return $"{s / 60}:{s % 60:00}";
    }
}
