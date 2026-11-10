using System.IO;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Sozvon.App.Shell;
using Sozvon.App.VoicePrints;
using Sozvon.Core.Calls;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Projects;

/// <summary>
/// A project's name, what its calls are about, its people and terms, as the Mac's project sheet; for a saved project
/// also the voices remembered for it, each with its delete. Saving writes profiles\&lt;slug&gt;.json under its lock.
/// </summary>
public sealed partial class ProjectEditorDialog : ContentDialog
{
    private readonly Project _project;
    private readonly string _profiles;
    private readonly IReadOnlyList<Project> _others;
    private readonly VoiceStore _voices;
    private readonly TextBox _title = new() { Header = L("Название"), PlaceholderText = "Acme Corp" };
    private readonly TextBlock _duplicate = new()
    {
        Text = L("Проект с таким названием уже есть"),
        Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        Visibility = Visibility.Collapsed,
    };
    private readonly TextBox _context = Multiline(L("О чём созвоны"), L("Инфраструктура видеоплатформы"), 6);
    private readonly TextBox _people = Multiline(L("Люди"), L("Анна Петрова, Иван"), 6);
    private readonly TextBox _terms = Multiline(L("Термины"), L("Kubernetes, HPA, стримкодер"), 8);
    private readonly StackPanel _voiceList = new() { Spacing = 4 };
    private readonly InfoBar _voiceProblem = new() { IsClosable = false, Severity = InfoBarSeverity.Warning };
    private readonly InfoBar _saveProblem = new() { IsClosable = false, Severity = InfoBarSeverity.Error, Title = L("Не получилось сохранить проект") };
    private readonly StackPanel _voicesSection = new() { Spacing = 8 };
    private readonly ElementTheme _theme;

    /// <param name="project">The project to change, or one with an empty slug for a new project.</param>
    /// <param name="theme">The window's theme: a dialog does not take it on by itself.</param>
    public ProjectEditorDialog(Project project, string profilesFolder, VoiceStore voices, ElementTheme theme)
    {
        _theme = theme;
        RequestedTheme = theme;
        _duplicate.Foreground = ThemeBrush.Get("SystemFillColorCautionBrush", theme);
        _project = project;
        _profiles = profilesFolder;
        _voices = voices;
        _others = Project.All(profilesFolder).Where(p => project.Slug.Length == 0 || p.Slug != project.Slug).ToList();
        // The heading is the name the project had when it opened, not the one being typed.
        Title = IsNew ? L("Новый проект") : project.Title;
        PrimaryButtonText = L("Сохранить");
        CloseButtonText = L("Отмена");
        DefaultButton = ContentDialogButton.Primary;

        _title.Text = project.Title;
        _context.Text = project.Context;
        _people.Text = string.Join(", ", project.People);
        _terms.Text = string.Join(", ", project.Terms);
        AutomationName(_title);
        AutomationName(_context);
        AutomationName(_people);
        AutomationName(_terms);
        _title.TextChanged += (_, _) => Update();

        var content = new StackPanel { Spacing = 12, MinWidth = 460 };
        content.Children.Add(_saveProblem);
        content.Children.Add(new StackPanel { Spacing = 4, Children = { _title, _duplicate } });
        content.Children.Add(_context);
        content.Children.Add(_people);
        content.Children.Add(_terms);
        content.Children.Add(Caption(L("Через запятую. Самое важное первым: в подсказку Whisper влезает около 25 слов.")));
        _voicesSection.Children.Add(new TextBlock { Text = L("Голоса"), Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        _voicesSection.Children.Add(_voiceList);
        _voicesSection.Children.Add(_voiceProblem);
        _voicesSection.Children.Add(Caption(L("Sozvon узнаёт этих людей по голосу в звонках проекта. Голос сохраняется, когда ты точно называешь собеседника в расшифровке.")));
        content.Children.Add(_voicesSection);
        Content = new ScrollViewer { Content = content, Padding = new Thickness(0, 0, 16, 0) };

        PrimaryButtonClick += OnSave;
        voices.Changed += OnVoicesChanged;
        Closed += (_, _) => voices.Changed -= OnVoicesChanged;
        voices.Refresh();
        ShowVoices();
        Update();
    }

    /// <summary>The project as saved; null until Save worked.</summary>
    public Project? Saved { get; private set; }

    private bool IsNew => _project.Slug.Length == 0;

    /// <summary>
    /// Grows with its text from two lines up to <paramref name="lines"/> lines, then scrolls. The heights include the
    /// header above the box (about 28 DIP) and the box's padding and border (about 16 DIP).
    /// </summary>
    private static TextBox Multiline(string header, string placeholder, int lines)
    {
        const double Chrome = 44, Line = 20;
        var box = new TextBox
        {
            Header = header,
            PlaceholderText = placeholder,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = Chrome + 2 * Line,
            MaxHeight = Chrome + lines * Line,
        };
        ScrollViewer.SetVerticalScrollBarVisibility(box, ScrollBarVisibility.Auto);
        return box;
    }

    private static void AutomationName(TextBox box) =>
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, (string)box.Header);

    private TextBlock Caption(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        Foreground = ThemeBrush.Get("TextFillColorSecondaryBrush", _theme),
    };

    private void Update()
    {
        var problem = Project.TitleProblem(_title.Text, _project.Slug, _others);
        _duplicate.Visibility = problem == ProjectTitleProblem.Duplicate ? Visibility.Visible : Visibility.Collapsed;
        IsPrimaryButtonEnabled = problem is null;
    }

    private void OnSave(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        if (Project.TitleProblem(_title.Text, _project.Slug, _others) is not null)
        {
            args.Cancel = true;
            return;
        }
        try
        {
            var project = _project.WithForm(_title.Text, _context.Text, _people.Text, _terms.Text, _profiles);
            project.Save(_profiles);
            Saved = project;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or Sozvon.Core.Foundation.FileLockTimeoutException)
        {
            // A second dialog cannot open over this one: the reason shows in it and the form stays.
            args.Cancel = true;
            _saveProblem.Message = e.Message;
            _saveProblem.IsOpen = true;
        }
    }

    private void OnVoicesChanged(object? sender, EventArgs e) => ShowVoices();

    /// <summary>Voice prints saved for this project's people, each with its delete; nothing for a new project.</summary>
    private void ShowVoices()
    {
        var voices = IsNew ? [] : Sozvon.Core.Calls.Voices.ForProfile(_voices.Records, _project.Slug);
        _voicesSection.Visibility = voices.Count > 0 || _voiceProblem.IsOpen ? Visibility.Visible : Visibility.Collapsed;
        _voiceList.Children.Clear();
        foreach (var voice in voices)
        {
            _voiceList.Children.Add(ProjectVoiceRow.Create(voice, !_voices.IsBusy, () => Delete(voice)));
        }
    }

    private async void Delete(VoiceRecord voice)
    {
        var outcome = await _voices.DeleteAsync(voice);
        _voiceProblem.Title = outcome.IsOk ? "" : L("Не получилось удалить голос");
        _voiceProblem.Message = outcome.IsOk ? "" : outcome.Message;
        _voiceProblem.IsOpen = !outcome.IsOk;
        ShowVoices();
    }
}
