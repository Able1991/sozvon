using Microsoft.UI.Xaml.Controls;

namespace Sozvon.App.Setup.Pages;

/// <summary>The content of a radio button: a title, a short note beside it and a line of detail.</summary>
public sealed partial class ChoiceLabel : UserControl
{
    public ChoiceLabel(string title, string note, string detail)
    {
        InitializeComponent();
        TitleText.Text = title;
        NoteText.Text = note;
        DetailText.Text = detail;
    }
}
