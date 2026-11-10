using System.Text;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Settings;

/// <summary>The settings kept in the engine's .env. Keys the app does not manage stay in the file untouched.</summary>
public sealed record SettingsValues
{
    public const int EnvVersion = 1;
    private const string VersionKey = "SOZVON_ENV_VERSION", MeKey = "SOZVON_ME", LlmKey = "SOZVON_LLM",
        LanguageKey = "SOZVON_LANGUAGE", LangSwitchKey = "SOZVON_LANG_SWITCH", ModelKey = "SOZVON_MODEL",
        ServerUrlKey = "SOZVON_SERVER_URL", ServerPasswordKey = "SOZVON_SERVER_PASSWORD",
        SyncVoicesKey = "SOZVON_SYNC_VOICES", SyncAudioKey = "SOZVON_SYNC_AUDIO";

    public static readonly IReadOnlySet<string> ManagedKeys = new HashSet<string>
    {
        VersionKey, MeKey, LlmKey, LanguageKey, LangSwitchKey, ModelKey, ServerUrlKey, ServerPasswordKey,
        SyncVoicesKey, SyncAudioKey,
    };

    public string Name { get; set; } = "";
    public Assistant Assistant { get; set; } = Assistant.None;
    public IReadOnlyList<SpeechLanguage> Languages { get; set; } = [SpeechLanguage.Ru];
    public bool LanguageSwitch { get; set; }
    public WhisperModel Model { get; set; } = WhisperModel.Turbo;
    public string ServerUrl { get; set; } = "";
    public string ServerPassword { get; set; } = "";
    public bool SyncVoices { get; set; } = true;
    public bool SyncAudio { get; set; } = true;

    /// <summary>From .env keys. <paramref name="detect"/> picks the assistant when none is set.</summary>
    public static SettingsValues FromEnv(IReadOnlyDictionary<string, string> env, Func<Assistant>? detect = null) => new()
    {
        Name = env.GetValueOrDefault(MeKey, ""),
        Languages = SpeechLanguages.Parse(env.GetValueOrDefault(LanguageKey, "ru")),
        LanguageSwitch = env.GetValueOrDefault(LangSwitchKey) == "1",
        Model = WhisperModels.FromKey(env.GetValueOrDefault(ModelKey)) ?? WhisperModel.Turbo,
        Assistant = Assistants.FromKey(env.GetValueOrDefault(LlmKey)) ?? (detect ?? Assistants.Detect)(),
        ServerUrl = env.GetValueOrDefault(ServerUrlKey, ""),
        ServerPassword = env.GetValueOrDefault(ServerPasswordKey, ""),
        SyncVoices = env.GetValueOrDefault(SyncVoicesKey) != "0",
        SyncAudio = env.GetValueOrDefault(SyncAudioKey) != "0",
    };

    public IReadOnlyList<(string Key, string Value)> Pairs()
    {
        var pairs = new List<(string, string)> { (VersionKey, EnvVersion.ToString()) };
        var me = Name.Trim();
        if (me.Length > 0) pairs.Add((MeKey, me));
        pairs.Add((LlmKey, Assistant.Key()));
        pairs.Add((LanguageKey, SpeechLanguages.Serialize(Languages.ToList())));
        pairs.Add((LangSwitchKey, LanguageSwitch ? "1" : "0"));
        pairs.Add((ModelKey, Model.Key()));
        if (ServerUrl.Trim() is { Length: > 0 } url) pairs.Add((ServerUrlKey, url));
        if (ServerPassword.Trim() is { Length: > 0 } password) pairs.Add((ServerPasswordKey, password));
        pairs.Add((SyncVoicesKey, SyncVoices ? "1" : "0"));
        pairs.Add((SyncAudioKey, SyncAudio ? "1" : "0"));
        return pairs;
    }

    /// <summary>New .env text: the app's keys replaced, everything else kept.</summary>
    public string Render(string existing) => EnvFile.Merge(existing, Pairs(), ManagedKeys);

    /// <summary>
    /// Only the own server's keys, as Settings saves them: the wizard's answers stay as they are, and an empty address or
    /// password leaves the file.
    /// </summary>
    public static void SaveServer(string envPath, string url, string password, bool syncAudio, bool syncVoices)
    {
        var pairs = new List<(string, string)>();
        if (url.Trim() is { Length: > 0 } address) pairs.Add((ServerUrlKey, address));
        if (password.Trim() is { Length: > 0 } secret) pairs.Add((ServerPasswordKey, secret));
        pairs.Add((SyncAudioKey, syncAudio ? "1" : "0"));
        pairs.Add((SyncVoicesKey, syncVoices ? "1" : "0"));
        Directory.CreateDirectory(Path.GetDirectoryName(envPath)!);
        var text = EnvFile.Merge(SharedFile.ReadText(envPath) ?? "", pairs, [ServerUrlKey, ServerPasswordKey]);
        AtomicFile.Write(envPath, new UTF8Encoding(false).GetBytes(text));
    }

    public static SettingsValues Load(string envPath, Func<Assistant>? detect = null) =>
        FromEnv(EnvFile.ToDictionary(SharedFile.ReadText(envPath) ?? ""), detect);

    public void Save(string envPath)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(envPath)!);
        var text = Render(SharedFile.ReadText(envPath) ?? "");
        AtomicFile.Write(envPath, new UTF8Encoding(false).GetBytes(text));
    }
}
