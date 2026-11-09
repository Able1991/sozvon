using Microsoft.UI.Xaml.Markup;

namespace Sozvon.App.Strings;

/// <summary>XAML access to the string table: <c>Text="{s:L K='Звонки'}"</c>.</summary>
[MarkupExtensionReturnType(ReturnType = typeof(string))]
public sealed partial class LExtension : MarkupExtension
{
    public string K { get; set; } = "";

    protected override object ProvideValue() => Loc.L(K);
}
