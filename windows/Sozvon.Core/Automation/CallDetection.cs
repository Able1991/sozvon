namespace Sozvon.Core.Automation;

// "A call is on. Record?": notice that a call app started using the microphone while Sozvon is idle, as the Mac app
// does (SozvonCore CallDetection.swift). The caller reads who captures audio (WASAPI sessions) and passes the time.

/// <summary>A process capturing audio input right now.</summary>
/// <param name="ProcessName">The executable's name without ".exe"; empty when only the package is known.</param>
/// <param name="ImagePath">Full path of the executable, when it could be read.</param>
/// <param name="ParentName">The parent process's executable name, for shared helpers such as WebView2.</param>
/// <param name="Package">The package family name of a Store app seen only through the privacy store.</param>
public sealed record MicClient(int Pid, string ProcessName, string? ImagePath = null, string? ParentName = null, string? Package = null);

/// <summary>A call app as the user knows it: Chrome and its helpers are one app.</summary>
public sealed record CallApp(string Name);

public static class CallApps
{
    /// <summary>
    /// Executable name to app name. Only these trigger the prompt: dictation, voice recorders and anything unknown never
    /// do. Browsers are here for Meet and other web calls.
    /// </summary>
    private static readonly Dictionary<string, string> ByProcess = new(StringComparer.OrdinalIgnoreCase)
    {
        ["zoom"] = "Zoom",
        ["ms-teams"] = "Microsoft Teams",
        ["msteams"] = "Microsoft Teams",
        ["teams"] = "Microsoft Teams",
        ["telegram"] = "Telegram",
        ["discord"] = "Discord",
        ["skype"] = "Skype",
        ["skypeapp"] = "Skype",
        ["slack"] = "Slack",
        ["whatsapp"] = "WhatsApp",
        ["whatsapp.root"] = "WhatsApp",
        ["chrome"] = "Chrome",
        ["msedge"] = "Edge",
        ["firefox"] = "Firefox",
        ["brave"] = "Brave",
        ["opera"] = "Opera",
        ["arc"] = "Arc",
        ["trueconf"] = "TrueConf",
        ["ciscocollabhost"] = "Webex",
        ["webexmta"] = "Webex",
        ["atmgr"] = "Webex",
    };

    /// <summary>Store apps seen only in the privacy store, by package family name prefix.</summary>
    private static readonly (string Prefix, string Name)[] ByPackage =
    [
        ("MSTeams_", "Microsoft Teams"),
        ("MicrosoftTeams_", "Microsoft Teams"),
        ("5319275A.WhatsAppDesktop_", "WhatsApp"),
        ("TelegramMessengerLLP.TelegramDesktop_", "Telegram"),
        ("Microsoft.SkypeApp_", "Skype"),
        ("91750D7E.Slack_", "Slack"),
        ("Zoom.Zoom_", "Zoom"),
    ];

    /// <summary>Yandex Browser's executable has a generic name: only its folder tells it apart.</summary>
    private const string YandexProcess = "browser";

    /// <summary>
    /// WebView2 runs the audio of many apps (Teams, WhatsApp, widgets): like the Mac's shared WebKit GPU process, it
    /// counts only as the known app that started it, otherwise it is ignored.
    /// </summary>
    private const string WebView = "msedgewebview2";

    public static CallApp? App(MicClient client)
    {
        if (client.Package is { Length: > 0 } package)
        {
            var hit = ByPackage.FirstOrDefault(p => package.StartsWith(p.Prefix, StringComparison.OrdinalIgnoreCase));
            return hit.Name is null ? null : new CallApp(hit.Name);
        }
        string name = Strip(client.ProcessName);
        if (name.Equals(WebView, StringComparison.OrdinalIgnoreCase))
        {
            return client.ParentName is { } parent && !Strip(parent).Equals(WebView, StringComparison.OrdinalIgnoreCase)
                ? App(new MicClient(client.Pid, parent))
                : null;
        }
        if (name.Equals(YandexProcess, StringComparison.OrdinalIgnoreCase))
        {
            return client.ImagePath?.Contains("Yandex", StringComparison.OrdinalIgnoreCase) == true ? new CallApp("Yandex Browser") : null;
        }
        return ByProcess.TryGetValue(name, out var app) ? new CallApp(app) : null;
    }

    private static string Strip(string processName) =>
        processName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? processName[..^4] : processName;
}

/// <summary>The prompt rules, without clocks or WASAPI: the caller passes the time and the clients.</summary>
public sealed class CallDetector(int ownPid)
{
    /// <summary>A call app must hold the microphone this long: a quick mic test or a voice message is not a call.</summary>
    public static readonly TimeSpan Debounce = TimeSpan.FromSeconds(5);

    /// <summary>When each call app started holding the mic (continuously).</summary>
    private readonly Dictionary<CallApp, DateTimeOffset> _since = [];

    /// <summary>Apps that get no prompt until they release the mic ("Not now", or the call was recorded).</summary>
    private readonly HashSet<CallApp> _suppressed = [];

    /// <summary>The app to offer recording for, or null.</summary>
    public CallApp? Prompt { get; private set; }

    /// <summary>Call apps holding the microphone right now, whether or not they passed the debounce.</summary>
    public IReadOnlySet<CallApp> OnMic { get; private set; } = new HashSet<CallApp>();

    /// <summary>
    /// The new state of the world. <paramref name="busy"/>: Sozvon is recording or can't record: no prompt, and the apps
    /// on the mic right now stay quiet until they release it, so stopping a recording mid-call doesn't nag.
    /// </summary>
    public CallApp? Update(IEnumerable<MicClient> clients, DateTimeOffset now, bool busy)
    {
        var apps = clients.Where(c => c.Pid != ownPid).Select(CallApps.App).OfType<CallApp>().ToHashSet();
        OnMic = apps;
        // Released the mic: forget it, including "Not now".
        foreach (var gone in _since.Keys.Where(a => !apps.Contains(a)).ToList()) _since.Remove(gone);
        _suppressed.IntersectWith(apps);
        foreach (var app in apps) _since.TryAdd(app, now);
        if (busy)
        {
            _suppressed.UnionWith(apps);
            Prompt = null;
            return null;
        }
        // Keep the current prompt while it is valid; otherwise the app that has held the mic longest.
        if (Prompt is { } current && apps.Contains(current) && !_suppressed.Contains(current)) return current;
        Prompt = _since.Where(p => !_suppressed.Contains(p.Key) && now - p.Value >= Debounce)
            .OrderBy(p => p.Value).ThenBy(p => p.Key.Name, StringComparer.Ordinal)
            .Select(p => p.Key).FirstOrDefault();
        return Prompt;
    }

    /// <summary>"Not now": no prompt for this app until it releases the mic.</summary>
    public void Dismiss()
    {
        if (Prompt is { } app) _suppressed.Add(app);
        Prompt = null;
    }
}
