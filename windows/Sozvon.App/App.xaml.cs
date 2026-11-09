using Microsoft.UI.Xaml;
using Sozvon.App.Capsule;

namespace Sozvon.App;

public partial class App : Application
{
    private CapsuleWindow? _capsule;
    private CapsuleDemo? _demo;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _capsule = new CapsuleWindow();
        _capsule.HideRequested += (_, _) => Exit();
        _capsule.PlaceDefault();
        _capsule.ShowWithoutFocus();
        _demo = new CapsuleDemo(_capsule);
        _demo.Start(Argument("--capsule-state"));
    }

    private static string Argument(string name)
    {
        var args = Environment.GetCommandLineArgs();
        var at = Array.IndexOf(args, name);
        return at >= 0 && at + 1 < args.Length ? args[at + 1] : "";
    }
}
