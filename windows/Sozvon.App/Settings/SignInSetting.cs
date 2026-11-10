using System.Security;
using CommunityToolkit.Mvvm.ComponentModel;
using Sozvon.App.Strings;
using Sozvon.Core.Settings;

namespace Sozvon.App.Settings;

/// <summary>
/// "Open at sign-in" for the Settings row and the tray menu: the state is Windows' own (the Run value), read each time,
/// never a copy in settings.json, as SMAppService on the Mac. Nothing is written until the user flips the switch.
/// </summary>
public sealed partial class SignInSetting : ObservableObject
{
    /// <summary>A test run points this at a scratch key; the real Run key is used otherwise.</summary>
    public const string KeyVariable = "SOZVON_SIGNIN_KEY";

    private readonly SignInLaunch _launch;
    private readonly string _exe;

    public SignInSetting(string exe)
    {
        _exe = exe;
        _launch = Environment.GetEnvironmentVariable(KeyVariable) is { Length: > 0 } key
            ? new SignInLaunch(key + @"\Run", key + @"\StartupApproved\Run")
            : new SignInLaunch();
    }

    public SignInState State => Read();

    public bool IsOn
    {
        get => State == SignInState.On;
        set
        {
            if (value != IsOn)
            {
                try
                {
                    if (value)
                    {
                        _launch.Enable(_exe);
                    }
                    else
                    {
                        _launch.Disable(_exe);
                    }
                    Error = "";
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException or SecurityException)
                {
                    Error = Loc.L("Не получилось изменить автозапуск: %@", e.Message);
                }
            }
            OnPropertyChanged();
            OnPropertyChanged(nameof(State));
            OnPropertyChanged(nameof(Description));
        }
    }

    /// <summary>Under the switch: why it is off although the value is there, or why the change failed.</summary>
    public string Description => Error.Length > 0 ? Error
        : State == SignInState.OffInTaskManager ? Loc.L("Выключено в диспетчере задач. Если включить здесь, Sozvon снова будет запускаться.")
        : "";

    [ObservableProperty] public partial string Error { get; private set; } = "";

    private SignInState Read()
    {
        try
        {
            return _launch.State(_exe);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or SecurityException)
        {
            return SignInState.Off;
        }
    }
}
