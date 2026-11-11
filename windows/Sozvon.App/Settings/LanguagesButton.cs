using Microsoft.UI.Xaml.Controls;
using Sozvon.Core.Settings;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Settings;

/// <summary>A drop-down checklist of call languages; "Detect automatically" is the empty list.</summary>
public sealed partial class LanguagesButton : DropDownButton
{
    private readonly Dictionary<SpeechLanguage, CheckBox> _boxes = [];
    private IReadOnlyList<SpeechLanguage> _languages = [];

    public LanguagesButton()
    {
        var list = new StackPanel();
        foreach (var language in SpeechLanguages.Real.Append(SpeechLanguage.Auto))
        {
            var box = new CheckBox { Content = Title(language) };
            box.Click += (_, _) =>
            {
                Languages = SpeechLanguages.Toggling(language, _languages);
                LanguagesChanged?.Invoke(this, EventArgs.Empty);
            };
            _boxes[language] = box;
            list.Children.Add(box);
        }
        Flyout = new Flyout { Content = list };
        Render();
    }

    /// <summary>The user changed the selection.</summary>
    public event EventHandler? LanguagesChanged;

    public IReadOnlyList<SpeechLanguage> Languages
    {
        get => _languages;
        set
        {
            _languages = value;
            Render();
        }
    }

    private void Render()
    {
        Content = _languages.Count == 0 ? Title(SpeechLanguage.Auto) : string.Join(" + ", _languages.Select(Title));
        foreach (var (language, box) in _boxes)
        {
            box.IsChecked = language == SpeechLanguage.Auto ? _languages.Count == 0 : _languages.Contains(language);
        }
    }

    internal static string Title(SpeechLanguage language) => language switch
    {
        SpeechLanguage.Ru => L("Русский"),
        SpeechLanguage.En => "English",
        SpeechLanguage.Uk => L("Українська"),
        SpeechLanguage.De => "Deutsch",
        SpeechLanguage.Es => "Español",
        _ => L("Определять сам"),
    };
}
