using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Sozvon.Core.Calls;
using static Sozvon.App.Strings.Loc;

namespace Sozvon.App.Calls;

/// <summary>"Fix word": select the misheard word or phrase in the line, type the right spelling.</summary>
public sealed partial class FixWordDialog : ContentDialog
{
    private readonly string _line;
    private readonly TextBox _wrong = new() { Header = L("Было"), PlaceholderText = L("Выдели в реплике") };
    private readonly TextBox _right = new() { Header = L("Правильно"), PlaceholderText = L("Как пишется") };
    private readonly InfoBar _partWord = new() { IsClosable = false, Severity = InfoBarSeverity.Warning, Message = L("Выдели слово целиком: часть слова не исправляется") };

    public FixWordDialog(TranscriptRow row)
    {
        _line = row.Line.Text;
        Title = L("Исправить слово");
        PrimaryButtonText = L("Исправить");
        CloseButtonText = L("Отмена");
        DefaultButton = ContentDialogButton.Primary;
        var text = new TextBox
        {
            Header = L("Реплика"),
            Text = row.Text,
            IsReadOnly = true,
            TextWrapping = TextWrapping.Wrap,
            MaxHeight = 120,
        };
        // A selection in the line fills "Было", trimmed of spaces and punctuation as on the Mac.
        text.SelectionChanged += (_, _) =>
        {
            var picked = text.SelectedText.Trim().Trim(Punctuation);
            if (picked.Length > 0)
            {
                _wrong.Text = picked;
            }
        };
        _wrong.TextChanged += (_, _) => Update();
        _right.TextChanged += (_, _) => Update();
        var content = new StackPanel { Spacing = 12, MinWidth = 420 };
        content.Children.Add(new TextBlock { Text = L("Выдели слово или фразу в реплике и напиши, как правильно."), TextWrapping = TextWrapping.Wrap });
        content.Children.Add(text);
        content.Children.Add(_wrong);
        content.Children.Add(_right);
        content.Children.Add(_partWord);
        Content = content;
        PrimaryButtonClick += (_, args) => args.Cancel = !IsValid;
        Update();
    }

    public string Wrong => _wrong.Text;

    public string Right => _right.Text.Trim();

    private static readonly char[] Punctuation = [.. ".,;:!?…«»\"'()[]—–-"];

    private bool IsValid => Wrong.Length > 0 && Transcript.ContainsWord(_line, Wrong) && Right.Length > 0 && Right != Wrong;

    private void Update()
    {
        _partWord.IsOpen = Wrong.Length > 0 && !Transcript.ContainsWord(_line, Wrong);
        IsPrimaryButtonEnabled = IsValid;
    }
}
