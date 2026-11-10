using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Sozvon.App.Settings;
using Sozvon.Core.Calls;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.VoicePrints;

/// <summary>
/// The "Твой голос" row, in Settings and on the Voices page as on the Mac: whether the own sample is recorded, and
/// Record, or Add a language and Record again. The buttons wait while a voice.py run goes on.
/// </summary>
public sealed class MyVoice(VoiceStore store, string dataDir, EngineSettings engine)
{
    public VoiceStore Store => store;

    /// <summary>"Не записан", or "Записан 5 ноября, 24 с речи".</summary>
    public static string Status(VoiceRecord? me)
    {
        if (me is null)
        {
            return L("Не записан");
        }
        var seconds = L("%@ с речи", (int)Math.Round(me.Seconds));
        if (!DateTimeOffset.TryParse(me.UpdatedAt, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at))
        {
            return seconds;
        }
        var day = at.ToLocalTime().ToString(IsRussian ? "d MMMM" : "MMMM d", Culture);
        return L("Записан %@, %@", day, seconds);
    }

    /// <summary>Fills the row and keeps it up to date while it is on screen.</summary>
    public void Attach(SettingsRow row)
    {
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Action = buttons;
        void Show()
        {
            row.Description = Status(store.Me);
            buttons.Children.Clear();
            if (store.Me is null)
            {
                buttons.Children.Add(Button(row, L("Записать…"), add: false));
            }
            else
            {
                var add = Button(row, L("Добавить язык…"), add: true);
                ToolTipService.SetToolTip(add, L("Добавить образец на другом языке звонков"));
                buttons.Children.Add(add);
                buttons.Children.Add(Button(row, L("Записать заново…"), add: false));
            }
        }
        void OnChanged(object? sender, EventArgs e) => Show();
        row.Loaded += (_, _) =>
        {
            store.Changed += OnChanged;
            store.Refresh();
            Show();
        };
        row.Unloaded += (_, _) => store.Changed -= OnChanged;
        Show();
    }

    private Button Button(FrameworkElement row, string text, bool add)
    {
        var button = new Button { Content = text, IsEnabled = !store.IsBusy };
        button.Click += async (_, _) => await RecordAsync(row.XamlRoot, add);
        return button;
    }

    /// <summary>The recording dialog; a new recording replaces the voice print, <paramref name="add"/> merges one more sample.</summary>
    public async Task RecordAsync(XamlRoot root, bool add)
    {
        var name = engine.Name.Trim();
        var dialog = new VoiceSampleDialog(store, dataDir, name.Length > 0 ? name : L("Я"), engine.Languages, add, Shell.Dialogs.ThemeOf(root)) { XamlRoot = root };
        await dialog.ShowAsync();
    }
}
