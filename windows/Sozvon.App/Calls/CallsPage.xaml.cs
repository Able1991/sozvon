using System.ComponentModel;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Sozvon.App.Calls;

public sealed partial class CallsPage : UserControl
{
    private static readonly Windows.UI.Color[] ProjectColors =
    [
        ColorHelper.FromArgb(255, 0xE0, 0x8A, 0x3C),
        ColorHelper.FromArgb(255, 0xE5, 0x48, 0x4D),
        ColorHelper.FromArgb(255, 0xA9, 0x84, 0x67),
        ColorHelper.FromArgb(255, 0x8A, 0x8A, 0x8A),
        ColorHelper.FromArgb(255, 0x2E, 0x8B, 0x57),
        ColorHelper.FromArgb(255, 0x6B, 0x5B, 0xD6),
    ];

    public CallsPage(CallsViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
        ViewModel.PropertyChanged += OnViewModelChanged;
        ViewModel.Projects.CollectionChanged += (_, _) => RebuildProjectMenu();
        GroupedCalls.Source = ViewModel.Groups;
        RebuildProjectMenu();
        ShowDetail();
    }

    public CallsViewModel ViewModel { get; }

    public static Brush ProjectBrush(string slug) =>
        new SolidColorBrush(ProjectColors[(uint)StableHash(slug) % ProjectColors.Length]);

    public static Visibility Shown(string text) => text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility ShownIf(bool value, bool expected) => value == expected ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Ctrl+F: the find bar of the opened call's transcript; false when that is not what is on screen.</summary>
    public bool OpenTranscriptFind() => ViewModel.Detail is not null && Detail.OpenFind();

    private void OnCallSelected(object sender, SelectionChangedEventArgs e) => ViewModel.SelectedRow = CallList.SelectedItem as CallRow;

    private static int StableHash(string text) => text.Aggregate(17, (hash, c) => unchecked(hash * 31 + c));

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(CallsViewModel.SelectedRow):
                CallList.SelectedItem = ViewModel.SelectedRow;
                break;
            case nameof(CallsViewModel.Detail):
                ShowDetail();
                break;
            case nameof(CallsViewModel.SelectedProject):
                ProjectButton.Content = ViewModel.SelectedProject.Title;
                break;
        }
    }

    private void ShowDetail()
    {
        Detail.ViewModel = ViewModel.Detail;
        Detail.Visibility = ViewModel.Detail is null ? Visibility.Collapsed : Visibility.Visible;
        NoSelection.Visibility = ViewModel.Detail is null ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RebuildProjectMenu()
    {
        ProjectButton.Content = ViewModel.SelectedProject.Title;
        ProjectMenu.Items.Clear();
        foreach (var project in ViewModel.Projects)
        {
            var item = new RadioMenuFlyoutItem { Text = project.Title, IsChecked = project == ViewModel.SelectedProject };
            item.Click += (_, _) => ViewModel.SelectedProject = project;
            ProjectMenu.Items.Add(item);
        }
    }
}
