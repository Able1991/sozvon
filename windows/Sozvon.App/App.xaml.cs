using Microsoft.UI.Xaml;
using Sozvon.App.Capsule;

namespace Sozvon.App;

public partial class App : Application
{
    private CapsuleWindow? _capsule;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _capsule = new CapsuleWindow();
        _capsule.ShowWithoutFocus();
    }
}
