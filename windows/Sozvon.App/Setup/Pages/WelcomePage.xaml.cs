using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Sozvon.App.Setup.Pages;

public sealed partial class WelcomePage : UserControl, ISetupPage
{
    public WelcomePage()
    {
        InitializeComponent();
        AddFeature("", "Одна кнопка", "Запись включается в плавающей капсуле или значком в области уведомлений. Когда приложение для звонков включает микрофон, Sozvon предлагает записать: по умолчанию он только спрашивает и сам ничего не пишет.");
        AddFeature("", "Локально", "Расшифровка идёт на компьютере. Ничего не покидает его, пока ты не включишь саммари через ассистента.");
        AddFeature("", "Кто что сказал", "Реплики разбиваются по голосам. Запомни голоса один раз, и имена подставятся сами.");
        AddFeature("", "Саммари", "Коротко, решения и задачи через ассистента. Потом можно спросить его о любом звонке.");
    }

    public event Action? Changed { add { } remove { } }
    public string Glyph => "";
    public string Title => Strings.L("Добро пожаловать в Sozvon");
    public string Subtitle => Strings.L("Нажал значок на панели задач, созвонился, остановил. Дальше расшифровка и саммари на этом компьютере.");
    public SetupFooter Footer => new(false, Strings.L("Продолжить"));

    public void OnShown()
    {
    }

    public bool Primary() => true;

    private void AddFeature(string glyph, string title, string text)
    {
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        var label = new StackPanel();
        label.Children.Add(new TextBlock { Text = Strings.L(title), Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        label.Children.Add(new TextBlock { Text = Strings.L(text), TextWrapping = TextWrapping.Wrap });
        Grid.SetColumn(label, 1);
        row.Children.Add(new FontIcon { Glyph = glyph, FontSize = 20, VerticalAlignment = VerticalAlignment.Top });
        row.Children.Add(label);
        Features.Children.Add(row);
    }
}
