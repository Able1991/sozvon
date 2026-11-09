using Microsoft.UI.Xaml;
using Sozvon.App.Capsule;
using Sozvon.App.Recording;
using Sozvon.Core.Engine;

namespace Sozvon.App;

public partial class App : Application
{
    private CapsuleWindow? _capsule;
    private CapsuleDemo? _demo;
    private RecordingController? _recording;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (Setup.SetupLauncher.TryShow())
        {
            return;
        }
        Shell.AppHost.Start();
        _capsule = new CapsuleWindow();
        _capsule.PlaceDefault();
        var demoState = Argument("--capsule-state");
        if (demoState.Length > 0 || Environment.GetCommandLineArgs().Contains("--capsule-demo"))
        {
            _capsule.ShowWithoutFocus();
            _demo = new CapsuleDemo(_capsule);
            _demo.Start(demoState);
            return;
        }
        var layout = Layout();
        _recording = new RecordingController(_capsule, layout);
        Shell.AppHost.Current!.Attach(_capsule, _recording);
        _recording.Start();
        if (!layout.IsInstalled)
        {
            Shell.AppHost.Current!.OpenSetup();
        }
    }

    /// <summary>The default folders, or the ones given for a run outside the normal install.</summary>
    private static EngineLayout Layout()
    {
        var layout = EngineLayout.Default();
        return new EngineLayout(
            Environment.GetEnvironmentVariable("SOZVON_DATA_DIR") ?? layout.Data,
            Environment.GetEnvironmentVariable("SOZVON_CALLS_DIR") ?? layout.Calls);
    }

    private static string Argument(string name)
    {
        var args = Environment.GetCommandLineArgs();
        var at = Array.IndexOf(args, name);
        return at >= 0 && at + 1 < args.Length ? args[at + 1] : "";
    }
}
