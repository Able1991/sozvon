using Microsoft.UI.Xaml.Controls;

namespace Sozvon.App.Setup.Pages;

public sealed partial class ReadyPage : UserControl, ISetupPage
{
    public ReadyPage()
    {
        InitializeComponent();
        FindButton.Content = Strings.L("Найти проекты через ассистента");
        UnavailableText.Text = Strings.L("Пока недоступно на Windows");
        LaterText.Text = Strings.L("Проекты можно завести позже: страница «Проекты» в главном окне.");
        HintTitle.Text = Strings.L("Значок может быть скрыт");
        HintText.Text = Strings.L("Windows 11 может спрятать новый значок. Нажми стрелку рядом с часами и перетащи Sozvon в область уведомлений.");
    }

    public event Action? Changed { add { } remove { } }
    public string Glyph => "";
    public string Title => Strings.L("Проекты");
    public string Subtitle => Strings.L("Проект это команда и её слова: имена, продукты, термины. С ними расшифровка точнее, а саммари знает, о ком речь.");
    public SetupFooter Footer => new(true, Strings.L("Готово"));

    public void OnShown()
    {
    }

    public bool Primary() => true;
}
