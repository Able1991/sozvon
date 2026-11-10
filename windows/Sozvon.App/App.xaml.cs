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
        // The shape is still being chosen; --capsule-style shows the other variants.
        _capsule = new CapsuleWindow(CapsuleStyle.Named(Argument("--capsule-style")));
        _capsule.PlaceDefault();
        var demoState = Argument("--capsule-state");
        if (demoState.Length > 0 || Environment.GetCommandLineArgs().Contains("--capsule-demo"))
        {
            Shell.AppHost.Current!.AttachDemo(_capsule);
            _capsule.ShowWithoutFocus();
            if (Environment.GetCommandLineArgs().Contains("--capsule-hover-cycle"))
            {
                // For looking at the hover transition frame by frame: the pointer "enters" and "leaves" every 1.5 s.
                var hovered = false;
                var cycle = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
                cycle.Tick += (_, _) => _capsule.SetHovered(hovered = !hovered);
                cycle.Start();
            }
            else if (Environment.GetCommandLineArgs().Contains("--capsule-hover"))
            {
                _capsule.ShowAsHovered();
            }
            _demo = new CapsuleDemo(_capsule);
            _demo.Start(demoState);
            return;
        }
        var layout = Layout();
        _recording = new RecordingController(_capsule, layout, Shell.AppHost.Current!.Settings, Shell.AppHost.Current.EngineSettings);
        Shell.AppHost.Current!.Attach(_capsule, _recording);
        _recording.Start();
        if (!layout.IsInstalled)
        {
            Shell.AppHost.Current!.OpenSetup();
        }
    }

    /// <summary>The default folders, or the ones given for a run outside the normal install.</summary>
    private static EngineLayout Layout() => new(Shell.AppPaths.DataDir, Shell.AppPaths.CallsDir);

    private static string Argument(string name)
    {
        var args = Environment.GetCommandLineArgs();
        var at = Array.IndexOf(args, name);
        return at >= 0 && at + 1 < args.Length ? args[at + 1] : "";
    }
}
