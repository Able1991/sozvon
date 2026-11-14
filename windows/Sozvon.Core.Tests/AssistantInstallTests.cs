using System.Text.RegularExpressions;
using Sozvon.Core.Assistants;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Tests;

/// <summary>
/// "How to install an assistant": the vendors' own Windows commands, the folders their installers put the program in
/// (searched even before a restart brings the new PATH), and when the block opens by itself.
/// </summary>
public sealed partial class AssistantInstallTests : TempFolders
{
    private string Home => Path.Combine(Root, "home");
    private string Local => Path.Combine(Home, "AppData", "Local");
    private AssistantHome Profile => new(Home, Local, Path.Combine(Home, "AppData", "Roaming"), "");

    [Fact]
    public void TheCommandsAreTheVendorsOwnPowerShellLines()
    {
        Assert.Equal("irm https://claude.ai/install.ps1 | iex", AssistantInstall.Command(Assistant.Claude));
        Assert.Equal("powershell -ExecutionPolicy ByPass -c \"irm https://chatgpt.com/codex/install.ps1 | iex\"", AssistantInstall.Command(Assistant.Codex));
        Assert.Equal("irm 'https://cursor.com/install?win32=true' | iex", AssistantInstall.Command(Assistant.Cursor));
        Assert.Null(AssistantInstall.Command(Assistant.None));
    }

    [Fact]
    public void InAnEmptyProfileNoneIsInstalled() =>
        Assert.Equal([Assistant.Claude, Assistant.Codex, Assistant.Cursor], AssistantInstall.Missing(Profile));

    [Fact]
    public void ClaudesInstallerPutsItIntoLocalBin()
    {
        WriteText(Path.Combine(Home, ".local", "bin", "claude.exe"), "");
        Assert.Equal(Path.Combine(Home, ".local", "bin", "claude.exe"), AssistantCli.Find(Assistant.Claude, Profile));
        Assert.Equal([Assistant.Codex, Assistant.Cursor], AssistantInstall.Missing(Profile));
    }

    /// <summary>install.ps1 links %LOCALAPPDATA%\Programs\OpenAI\Codex\bin to the current release and adds it to the user's PATH.</summary>
    [Fact]
    public void CodexsInstallerFolderIsSearchedWithoutPath()
    {
        var exe = Path.Combine(Local, "Programs", "OpenAI", "Codex", "bin", "codex.exe");
        WriteText(exe, "");
        Assert.Equal(exe, AssistantCli.Find(Assistant.Codex, Profile));
        Assert.Equal([exe], AssistantCli.Argv(exe, Profile));
    }

    /// <summary>
    /// Cursor's installer leaves %LOCALAPPDATA%\cursor-agent\cursor-agent.cmd, which hands over to cursor-agent.ps1, which
    /// runs the newest versions\*\index.js with the node.exe next to it. Neither cmd.exe nor PowerShell is started for it:
    /// the same node and script, directly.
    /// </summary>
    [Fact]
    public void CursorsLauncherRunsTheNewestVersionWithItsOwnNode()
    {
        var root = Path.Combine(Local, "cursor-agent");
        WriteText(Path.Combine(root, "cursor-agent.cmd"), CursorLauncher);
        WriteText(Path.Combine(root, "cursor-agent.ps1"), "");
        Assert.Null(AssistantCli.Find(Assistant.Cursor, Profile)); // no version yet: nothing to run
        foreach (var version in new[] { "2026.9.30-0a1b2c3", "2026.11.13-eacade1", "2026.10.2-ffff000" })
        {
            WriteText(Path.Combine(root, "versions", version, "node.exe"), "");
            WriteText(Path.Combine(root, "versions", version, "index.js"), "");
        }
        Directory.CreateDirectory(Path.Combine(root, "versions", "2027.1.1-staged.new"));
        var found = AssistantCli.Find(Assistant.Cursor, Profile)!;
        Assert.Equal(Path.Combine(root, "cursor-agent.cmd"), found);
        var newest = Path.Combine(root, "versions", "2026.11.13-eacade1");
        Assert.Equal([Path.Combine(newest, "node.exe"), Path.Combine(newest, "index.js")], AssistantCli.Argv(found, Profile));
        Assert.DoesNotContain(Assistant.Cursor, AssistantInstall.Missing(Profile));
    }

    [Fact]
    public void ANewerVersionWithABuildTimeWins()
    {
        var root = Path.Combine(Local, "cursor-agent");
        WriteText(Path.Combine(root, "cursor-agent.cmd"), CursorLauncher);
        foreach (var version in new[] { "2026.11.13-eacade1", "2026.11.13-09-15-00-bbbb111", "2026.11.13-18-40-12-aaaa000" })
        {
            WriteText(Path.Combine(root, "versions", version, "node.exe"), "");
            WriteText(Path.Combine(root, "versions", version, "index.js"), "");
        }
        Assert.Equal(Path.Combine(root, "versions", "2026.11.13-18-40-12-aaaa000", "node.exe"), AssistantCli.Argv(Path.Combine(root, "cursor-agent.cmd"), Profile)![0]);
    }

    [Fact]
    public void AnotherBatchFileNamedLikeCursorIsNotStarted()
    {
        var root = Path.Combine(Local, "cursor-agent");
        WriteText(Path.Combine(root, "cursor-agent.cmd"), "@echo off\r\ndel /q *\r\n");
        WriteText(Path.Combine(root, "versions", "2026.11.13-eacade1", "node.exe"), "");
        WriteText(Path.Combine(root, "versions", "2026.11.13-eacade1", "index.js"), "");
        Assert.Null(AssistantCli.Find(Assistant.Cursor, Profile));
    }

    [Fact]
    public void TheBlockOpensByItselfOnlyWhenItIsNeeded()
    {
        Assert.True(AssistantInstall.OpenInSettings(Assistant.Codex, [Assistant.Codex, Assistant.Cursor]));
        Assert.False(AssistantInstall.OpenInSettings(Assistant.Claude, [Assistant.Codex, Assistant.Cursor]));
        Assert.False(AssistantInstall.OpenInSettings(Assistant.None, [Assistant.Codex, Assistant.Cursor]));
        Assert.True(AssistantInstall.OpenInSetup([Assistant.Claude, Assistant.Codex, Assistant.Cursor]));
        Assert.False(AssistantInstall.OpenInSetup([Assistant.Codex, Assistant.Cursor]));
    }

    /// <summary>The Mac's sentences name a Mac and Terminal; the Windows ones this computer and PowerShell, in both tables.</summary>
    [Theory]
    [InlineData("windows/Sozvon.App/Strings/windows-en.strings")]
    [InlineData("windows/Sozvon.App/Setup/Strings.cs")]
    public void TheWindowsWordingIsTranslated(string path)
    {
        var text = File.ReadAllText(Path.Combine(Repo.Root(), path));
        // The wizard shows no chosen-but-missing assistant: its radio is disabled.
        var keys = path.EndsWith(".strings") ? new[] { AssistantInstall.HelpText, AssistantInstall.NotInstalledText } : [AssistantInstall.HelpText];
        foreach (var key in keys)
        {
            Assert.DoesNotContain("Mac", key);
            var entry = Regex.Match(text, "\"" + Regex.Escape(key) + "\"\\s*(?:=|\\]\\s*=)\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
            Assert.True(entry.Success, $"{path} has no English for «{key}»");
            Assert.DoesNotContain("Mac", entry.Groups[1].Value);
            Assert.Contains("computer", entry.Groups[1].Value);
        }
        Assert.Contains("PowerShell", AssistantInstall.HelpText);
    }

    private const string CursorLauncher = "@echo off\r\nsetlocal enabledelayedexpansion\r\nset \"CURSOR_INVOKED_AS=%~nx0\"\r\n\r\n"
        + "REM Get the directory of this script\r\nset \"SCRIPT_DIR=%~dp0\"\r\nREM Remove trailing backslash\r\n"
        + "if \"%SCRIPT_DIR:~-1%\"==\"\\\" set \"SCRIPT_DIR=%SCRIPT_DIR:~0,-1%\"\r\n\r\n"
        + "%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%SCRIPT_DIR%\\cursor-agent.ps1\" %*\r\n";
}
