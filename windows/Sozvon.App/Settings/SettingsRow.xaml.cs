using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;

namespace Sozvon.App.Settings;

/// <summary>A SettingsCard-style row: header and description on the left, a control on the right.</summary>
[ContentProperty(Name = nameof(Action))]
public sealed partial class SettingsRow : UserControl
{
    public static readonly DependencyProperty HeaderProperty =
        DependencyProperty.Register(nameof(Header), typeof(string), typeof(SettingsRow), new PropertyMetadata(""));

    public static readonly DependencyProperty DescriptionProperty =
        DependencyProperty.Register(nameof(Description), typeof(string), typeof(SettingsRow), new PropertyMetadata("", OnDescriptionChanged));

    public SettingsRow()
    {
        InitializeComponent();
        DescriptionText.Visibility = Visibility.Collapsed;
    }

    public string Header
    {
        get => (string)GetValue(HeaderProperty);
        set => SetValue(HeaderProperty, value);
    }

    public string Description
    {
        get => (string)GetValue(DescriptionProperty);
        set => SetValue(DescriptionProperty, value);
    }

    public object? Action
    {
        get => ActionHost.Content;
        set => ActionHost.Content = value;
    }

    /// <summary>Marks a row whose value is stored but has no effect yet.</summary>
    public bool NotConnected
    {
        get => NotConnectedText.Visibility == Visibility.Visible;
        set => NotConnectedText.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
    }

    private static void OnDescriptionChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var row = (SettingsRow)d;
        row.DescriptionText.Visibility = string.IsNullOrEmpty((string)e.NewValue) ? Visibility.Collapsed : Visibility.Visible;
    }
}
