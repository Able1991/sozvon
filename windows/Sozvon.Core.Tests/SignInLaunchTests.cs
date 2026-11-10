using Microsoft.Win32;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Tests;

/// <summary>
/// Open at sign-in against a scratch key, HKCU\Software\Sozvon-test\&lt;guid&gt;, created and deleted by each test. The real
/// Run key is never opened here.
/// </summary>
public sealed class SignInLaunchTests : IDisposable
{
    private const string Parent = @"Software\Sozvon-test";
    private const string Exe = @"C:\Program Files\Sozvon\Sozvon.exe";
    private readonly string _root = $@"{Parent}\{Guid.NewGuid():N}";

    private string Run => _root + @"\Run";
    private string Approved => _root + @"\StartupApproved\Run";
    private SignInLaunch Launch => new(Run, Approved);

    [Fact]
    public void TheRealKeysAreNotTheOnesUnderTest()
    {
        Assert.NotEqual(SignInLaunch.RunKey, Run);
        Assert.StartsWith(Parent, Run);
    }

    [Fact]
    public void OnWritesTheQuotedExecutableAndOffRemovesIt()
    {
        Assert.Equal(SignInState.Off, Launch.State(Exe));
        Launch.Enable(Exe);
        Assert.Equal(SignInState.On, Launch.State(Exe));
        using (var key = Registry.CurrentUser.OpenSubKey(Run)!)
        {
            Assert.Equal("\"C:\\Program Files\\Sozvon\\Sozvon.exe\"", key.GetValue("Sozvon"));
            Assert.Equal(RegistryValueKind.String, key.GetValueKind("Sozvon"));
        }
        Launch.Disable(Exe);
        Assert.Equal(SignInState.Off, Launch.State(Exe));
        using var run = Registry.CurrentUser.OpenSubKey(Run)!;
        Assert.Null(run.GetValue("Sozvon"));
    }

    [Fact]
    public void AnotherCopysValueIsLeftAlone()
    {
        const string other = @"C:\Users\x\AppData\Local\Programs\Sozvon\Sozvon.exe";
        Launch.Enable(other);
        Assert.Equal(SignInState.Off, Launch.State(Exe));
        Launch.Disable(Exe);
        Assert.Equal(SignInState.On, Launch.State(other));
    }

    [Fact]
    public void TaskManagersSwitchIsReadAndClearedOnRequest()
    {
        Launch.Enable(Exe);
        using (var approved = Registry.CurrentUser.CreateSubKey(Approved))
            approved.SetValue("Sozvon", new byte[] { 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, RegistryValueKind.Binary);
        Assert.Equal(SignInState.OffInTaskManager, Launch.State(Exe));
        Launch.Enable(Exe);
        Assert.Equal(SignInState.On, Launch.State(Exe));
        using (var approved = Registry.CurrentUser.CreateSubKey(Approved))
            approved.SetValue("Sozvon", new byte[] { 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, RegistryValueKind.Binary);
        Assert.Equal(SignInState.On, Launch.State(Exe));
    }

    [Theory]
    [InlineData("\"C:\\Program Files\\Sozvon\\Sozvon.exe\"", true)]
    [InlineData("\"c:\\program files\\sozvon\\SOZVON.EXE\" --tray", true)]
    [InlineData("C:\\Program Files\\Sozvon\\Sozvon.exe --tray", true)]
    [InlineData("\"C:\\Other\\Sozvon.exe\"", false)]
    [InlineData("", false)]
    public void TheCommandsExecutableIsCompared(string command, bool same) => Assert.Equal(same, SignInLaunch.SameExecutable(command, Exe));

    public void Dispose()
    {
        Registry.CurrentUser.DeleteSubKeyTree(_root, throwOnMissingSubKey: false);
        using var parent = Registry.CurrentUser.OpenSubKey(Parent);
        if (parent is { SubKeyCount: 0, ValueCount: 0 })
        {
            parent.Dispose();
            Registry.CurrentUser.DeleteSubKey(Parent, throwOnMissingSubKey: false);
        }
    }
}
