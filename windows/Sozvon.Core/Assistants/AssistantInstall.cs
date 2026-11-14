using Sozvon.Core.Settings;

namespace Sozvon.Core.Assistants;

/// <summary>
/// "How to install an assistant", as on the Mac (SettingsView's AssistantInstallHelp): the command that installs each
/// missing assistant, pasted into PowerShell, and when the block opens by itself.
/// </summary>
public static class AssistantInstall
{
    /// <summary>The block's explanation (a key of the text tables).</summary>
    public const string HelpText = "«Не установлен» значит, что на этом компьютере нет программы помощника. Вставь команду в PowerShell, потом открой новое окно PowerShell, один раз запусти программу и войди в свой аккаунт. Саммари идут по твоей подписке.";

    /// <summary>Under the chosen assistant when its program is missing, instead of "doesn't answer" (a key of the text tables).</summary>
    public const string NotInstalledText = "%@ не установлен на этом компьютере, команда для установки ниже";

    /// <summary>
    /// The vendors' own Windows installers, each of which puts the program where <see cref="AssistantCli.SearchFolders"/>
    /// looks without a new PATH:
    /// Claude Code: https://code.claude.com/docs/en/setup ("Windows PowerShell"), into ~\.local\bin\claude.exe;
    /// Codex: https://github.com/openai/codex (README, "Windows"), into %LOCALAPPDATA%\Programs\OpenAI\Codex\bin\codex.exe;
    /// Cursor CLI: https://cursor.com/docs/cli/installation ("Windows"), into %LOCALAPPDATA%\cursor-agent\cursor-agent.cmd.
    /// </summary>
    public static string? Command(Assistant a) => a switch
    {
        Assistant.Claude => "irm https://claude.ai/install.ps1 | iex",
        Assistant.Codex => "powershell -ExecutionPolicy ByPass -c \"irm https://chatgpt.com/codex/install.ps1 | iex\"",
        Assistant.Cursor => "irm 'https://cursor.com/install?win32=true' | iex",
        _ => null,
    };

    /// <summary>The assistants whose program is not on this computer, in the order of the choice.</summary>
    public static IReadOnlyList<Assistant> Missing(AssistantHome home) =>
        [.. new[] { Assistant.Claude, Assistant.Codex, Assistant.Cursor }.Where(a => AssistantCli.Find(a, home) is null)];

    /// <summary>In Settings the block opens by itself when the chosen assistant is missing.</summary>
    public static bool OpenInSettings(Assistant chosen, IReadOnlyCollection<Assistant> missing) =>
        chosen != Assistant.None && missing.Contains(chosen);

    /// <summary>In the setup assistant it opens by itself when none is installed: otherwise it shares the page with the choice.</summary>
    public static bool OpenInSetup(IReadOnlyCollection<Assistant> missing) => missing.Count == 3;
}
