using System.ComponentModel;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Sozvon.App.Calls;
using Sozvon.App.Capsule;
using Sozvon.App.Settings;
using Sozvon.App.Shell;
using Sozvon.Core.Calls;
using Sozvon.Core.Engine;
using Sozvon.Core.Foundation;
using Sozvon.Core.Settings;
using Windows.System;
using WinRT.Interop;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Recording;

/// <summary>One line of the project box: a project, "no project", or the "new project" command.</summary>
public sealed record ProjectChoice(string Slug, string Title, Brush? Dot = null)
{
    public Visibility DotVisibility => Dot is null ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>The name a screen reader announces for the closed box.</summary>
    public override string ToString() => Title;
}

/// <summary>"What was the call about?": an ordinary window. Closing it never loses the recording.</summary>
public sealed partial class CallInfoWindow : Window
{
    private const int LogicalWidth = 620;
    private const string NewProjectSlug = "\0new";

    private readonly CallInfoRequest _request;
    private readonly EngineLayout _layout;
    private readonly EngineSettings _engine;
    private readonly AppSettings _settings;
    private readonly TaskCompletionSource<CallInfoAnswer> _answer = new();
    private readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly List<Project> _projects;
    private readonly CallInfo _shown;
    private IReadOnlyList<Call> _pastCalls = [];
    private ProjectChoice? _selected;
    private int? _countdown;
    private bool _fillingModels;
    private Windows.Graphics.PointInt32? _placed;

    internal CallInfoWindow(CallInfoRequest request, EngineLayout layout, EngineSettings engine, AppSettings settings)
    {
        _request = request;
        _layout = layout;
        _engine = engine;
        _settings = settings;
        _projects = Project.All(layout.Profiles);
        InitializeComponent();
        ConfigureWindow();

        Heading.Text = Title = request.Title;
        OkButton.Content = request.OkTitle;
        LaterButton.Visibility = request.AllowLater ? Visibility.Visible : Visibility.Collapsed;
        CancelButton.Content = L(request.AllowLater ? "Не расшифровывать" : "Отмена");
        ToolTipService.SetToolTip(CancelButton, request.AllowLater ? L("Оставить запись без расшифровки") : null);

        var assistant = engine.Assistant;
        SummaryBox.IsEnabled = assistant != Core.Settings.Assistant.None;
        SummaryBox.Content = SummaryBox.IsEnabled
            ? L("Через %@, текст уйдёт в %@", AssistantTitle(assistant), AssistantVendor(assistant))
            : L("Помощник не выбран в настройках");

        var initial = request.Initial with { Summary = request.Initial.Summary && SummaryBox.IsEnabled };
        // The project's language comes with the project (guessed or kept from the last call), unless the call already has its own.
        if (initial.Languages.SequenceEqual(engine.Languages))
        {
            initial = initial with { Languages = Project.CallLanguages(_projects.FirstOrDefault(p => p.Slug == initial.Profile), initial.Languages) };
        }
        Show(initial);
        _shown = Typed();
        Root.Loaded += OnLoaded;
        Closed += OnClosed;
        _settings.PropertyChanged += OnSettingChanged;
        LanguagesBox.LanguagesChanged += (_, _) =>
        {
            FillModels(SelectedModel);
            StopCountdownIfEdited();
        };
        _clock.Tick += (_, _) => Tick();
    }

    /// <summary>Set once. Closing the window answers Later with nothing new when Later is offered, otherwise Cancel.</summary>
    public Task<CallInfoAnswer> Answer => _answer.Task;

    private void ConfigureWindow()
    {
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBarArea);
        AppWindow.SetIcon(AppPaths.Asset("Sozvon.ico"));
        AppIcon.Source = new BitmapImage(new Uri(AppPaths.Asset("Sozvon.ico")));
        // A fixed form: Windows drops the maximize button only when minimize is off as well; with it, Maximize still
        // stretched the form over the screen.
        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        // Sozvon has no active window of its own (the capsule never takes the focus), so Windows refuses to bring a new
        // window to the front: the question would open behind the call app. On top it is seen; it is small and short-lived.
        presenter.IsAlwaysOnTop = true;
        AppWindow.SetPresenter(presenter);
        WindowTheme.Apply(this, Root, _settings.Theme);
        var scale = Scale();
        var screen = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.ResizeClient(new((int)(LogicalWidth * scale), Math.Min((int)(480 * scale), screen.Height)));
        Centre();
    }

    /// <summary>In the middle of the work area; remembered, so a later fit keeps it there unless the user moved it.</summary>
    private void Centre()
    {
        var screen = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        _placed = new(screen.X + (screen.Width - AppWindow.Size.Width) / 2, screen.Y + (screen.Height - AppWindow.Size.Height) / 2);
        AppWindow.Move(_placed.Value);
    }

    private double Scale() => NativeWindow.GetDpiForWindow(WindowNative.GetWindowHandle(this)) / 96.0;

    private void Show(CallInfo info)
    {
        KindChoice.SelectedIndex = info.Reflection ? 1 : 0;
        TopicBox.Text = info.Topic;
        NamesBox.Text = info.Names;
        TermsBox.Text = info.Terms;
        LanguagesBox.Languages = info.Languages;
        SummaryBox.IsChecked = info.Summary;
        FillModels(info.Model);
        FillProjects(info.Profile);
    }

    private CallInfo Typed() => _request.Initial with
    {
        Profile = (_selected?.Slug is { } slug && slug != NewProjectSlug) ? slug : "",
        Topic = TopicBox.Text,
        Names = NamesBox.Text,
        Terms = TermsBox.Text,
        Languages = LanguagesBox.Languages,
        Summary = SummaryBox.IsChecked == true,
        Reflection = KindChoice.SelectedIndex == 1,
        Model = SelectedModel,
    };

    /// <summary>The model picked by hand for this call; null: Auto.</summary>
    private WhisperModel? SelectedModel => (ModelBox.SelectedItem as ComboBoxItem)?.Tag as WhisperModel?;

    /// <summary>
    /// "Auto" names the model the call will get from its language (and the settings' model for Russian); then the downloaded
    /// models to pick by hand, which call.json "model" keeps. Built again when the languages change: Auto's name follows them.
    /// </summary>
    private void FillModels(WhisperModel? chosen)
    {
        _fillingModels = true;
        ModelBox.Items.Clear();
        ModelBox.Items.Add(new ComboBoxItem { Content = WhisperModels.AutoTitle(LanguagesBox.Languages, _engine.Model, _engine.ModelRu, L) });
        foreach (var model in Enum.GetValues<WhisperModel>().Where(m => m.IsDownloaded(_layout.Data) || m == chosen))
        {
            ModelBox.Items.Add(new ComboBoxItem { Content = model.Title(), Tag = model });
        }
        ModelBox.SelectedIndex = Math.Max(0, ModelBox.Items.Cast<ComboBoxItem>().ToList().FindIndex(i => i.Tag as WhisperModel? == chosen && chosen is not null));
        _fillingModels = false;
    }

    private void OnModelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_fillingModels)
        {
            StopCountdownIfEdited();
        }
    }

    private void FillProjects(string profile)
    {
        var choices = new List<ProjectChoice> { new("", L("Без проекта")) };
        // A call may name a project whose file is gone: keep it selectable so the box shows it.
        if (profile.Length > 0 && _projects.All(p => p.Slug != profile))
        {
            choices.Add(new ProjectChoice(profile, profile));
        }
        choices.AddRange(_projects.Select(p => new ProjectChoice(p.Slug, p.Title, CallsPage.ProjectBrush(p.Slug))));
        choices.Add(new ProjectChoice(NewProjectSlug, L("Новый проект…")));
        _selected = choices.First(c => c.Slug == profile);
        ProjectBox.ItemsSource = choices;
        ProjectBox.SelectedItem = _selected;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        Body.SizeChanged += (_, _) => FitToContent();
        FitToContent();
        StartCountdown();
        try
        {
            _pastCalls = await Task.Run(() => Call.All(_layout.Calls));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            AppHost.Log(error);
        }
        ShowSuggestions();
    }

    /// <summary>The window is as tall as the form, up to the screen; then the form scrolls.</summary>
    private void FitToContent()
    {
        var scale = Scale();
        var screen = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var footer = ((FrameworkElement)Root.Children[2]).ActualHeight;
        var height = Math.Min((int)Math.Ceiling((32 + Body.ActualHeight + footer) * scale), screen.Height);
        if (height != AppWindow.ClientSize.Height)
        {
            // Grown from the first guess downwards, the form was no longer centred.
            var untouched = _placed is { } placed && AppWindow.Position.Equals(placed);
            AppWindow.ResizeClient(new(AppWindow.ClientSize.Width, height));
            if (untouched)
            {
                Centre();
            }
        }
    }

    private void StartCountdown()
    {
        if (_request.Countdown is { } seconds)
        {
            _countdown = seconds;
            ShowCountdown();
            _clock.Start();
        }
    }

    private void Tick()
    {
        if (--_countdown <= 0)
        {
            Finish(new CallInfoAnswer.Transcribe(Typed()));
        }
        else
        {
            ShowCountdown();
        }
    }

    private void ShowCountdown()
    {
        CountdownBar.Title = L("Проект и участники определились сами. Расшифрую через %@ с, если ничего не менять.", _countdown ?? 0);
        CountdownBar.IsOpen = true;
        OkButton.Content = $"{_request.OkTitle} ({_countdown})";
    }

    private void StopCountdown()
    {
        _countdown = null;
        _clock.Stop();
        CountdownBar.IsOpen = false;
        OkButton.Content = _request.OkTitle;
    }

    private void StopCountdownIfEdited()
    {
        if (_countdown is not null && Typed() != _shown)
        {
            StopCountdown();
        }
    }

    private void OnFormChanged(object sender, RoutedEventArgs e) => StopCountdownIfEdited();

    private void OnNamesChanged(object sender, TextChangedEventArgs e)
    {
        StopCountdownIfEdited();
        ShowSuggestions();
    }

    private async void OnProjectChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ProjectBox.SelectedItem is not ProjectChoice choice || choice == _selected)
        {
            return;
        }
        if (choice.Slug == NewProjectSlug)
        {
            ProjectBox.SelectedItem = _selected;
            await CreateProjectAsync();
            return;
        }
        _selected = choice;
        // The project's language comes with it; one without keeps what the form says.
        var languages = Project.CallLanguages(_projects.FirstOrDefault(p => p.Slug == choice.Slug), LanguagesBox.Languages);
        if (!languages.SequenceEqual(LanguagesBox.Languages))
        {
            LanguagesBox.Languages = languages;
            FillModels(SelectedModel);
        }
        StopCountdownIfEdited();
        ShowSuggestions();
    }

    private async Task CreateProjectAsync()
    {
        var title = new TextBox { PlaceholderText = "Acme", MinWidth = 280 };
        var problem = new TextBlock { Foreground = (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"], TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            RequestedTheme = Root.ActualTheme,
            Title = L("Новый проект"),
            Content = new StackPanel { Spacing = 8, Children = { title, problem } },
            PrimaryButtonText = L("Сохранить"),
            CloseButtonText = L("Отмена"),
            DefaultButton = ContentDialogButton.Primary,
        };
        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (Project.TitleProblem(title.Text, "", _projects) is { } error)
            {
                problem.Text = L(error == ProjectTitleProblem.Empty ? "Нужно название" : "Проект с таким названием уже есть");
                problem.Visibility = Visibility.Visible;
                args.Cancel = true;
                return;
            }
            try
            {
                var project = new Project(Project.UniqueSlug(title.Text, _layout.Profiles), title.Text.Trim());
                project.Save(_layout.Profiles);
                _projects.Add(project);
                FillProjects(project.Slug);
                StopCountdownIfEdited();
                ShowSuggestions();
            }
            catch (Exception failure) when (failure is IOException or UnauthorizedAccessException)
            {
                AppHost.Log(failure);
                problem.Text = failure.Message;
                problem.Visibility = Visibility.Visible;
                args.Cancel = true;
            }
        };
        await dialog.ShowAsync();
    }

    private void ShowSuggestions()
    {
        var known = Project.KnownPeople(_selected?.Slug ?? "", _pastCalls, _projects, _engine.Name);
        var typed = TextRules.SplitList(NamesBox.Text);
        Suggestions.Children.Clear();
        foreach (var person in known)
        {
            var on = typed.Contains(person);
            var chip = new ToggleButton { Content = person, IsChecked = on, Height = 28, Padding = new Thickness(12, 0, 12, 0) };
            ToolTipService.SetToolTip(chip, L(on ? "Убрать из собеседников" : "Добавить в собеседники"));
            chip.Click += (_, _) => ToggleSuggestion(person);
            Suggestions.Children.Add(chip);
        }
        var visibility = known.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        Suggestions.Visibility = SuggestionsLabel.Visibility = visibility;
    }

    private void ToggleSuggestion(string person)
    {
        var names = TextRules.SplitList(NamesBox.Text);
        if (!names.Remove(person))
        {
            names.Add(person);
        }
        NamesBox.Text = string.Join(", ", names);
    }

    private void OnWait(object sender, RoutedEventArgs e) => StopCountdown();

    private void OnOk(object sender, RoutedEventArgs e) => Finish(new CallInfoAnswer.Transcribe(Typed()));

    private void OnLater(object sender, RoutedEventArgs e) => Finish(new CallInfoAnswer.Later(Typed()));

    private void OnCancel(object sender, RoutedEventArgs e) => Finish(new CallInfoAnswer.Cancel());

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            Close();
        }
    }

    private void Finish(CallInfoAnswer answer)
    {
        _answer.TrySetResult(answer);
        Close();
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _clock.Stop();
        _settings.PropertyChanged -= OnSettingChanged;
        _answer.TrySetResult(_request.AllowLater ? new CallInfoAnswer.Later(null) : new CallInfoAnswer.Cancel());
    }

    private void OnSettingChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppSettings.Theme))
        {
            WindowTheme.Apply(this, Root, _settings.Theme);
        }
    }

    private static string AssistantTitle(Core.Settings.Assistant assistant) => assistant switch
    {
        Core.Settings.Assistant.Claude => "Claude Code",
        Core.Settings.Assistant.Codex => "Codex",
        _ => "Cursor",
    };

    private static string AssistantVendor(Core.Settings.Assistant assistant) => assistant switch
    {
        Core.Settings.Assistant.Claude => "Anthropic",
        Core.Settings.Assistant.Codex => "OpenAI",
        _ => "Cursor",
    };
}
