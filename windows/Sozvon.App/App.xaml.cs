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
        _capsule = new CapsuleWindow();
        _capsule.HideRequested += (_, _) => Exit();
        _capsule.PlaceDefault();
        _capsule.ShowWithoutFocus();
        var demoState = Argument("--capsule-state");
        if (demoState.Length > 0 || Environment.GetCommandLineArgs().Contains("--capsule-demo"))
        {
            _demo = new CapsuleDemo(_capsule);
            _demo.Start(demoState);
            return;
        }
        _recording = new RecordingController(_capsule, Layout());
        _recording.Start();
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
