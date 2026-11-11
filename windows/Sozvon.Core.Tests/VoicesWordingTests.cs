namespace Sozvon.Core.Tests;

/// <summary>
/// The Voices page and the own voice dialog in English: Windows writes titles and buttons in sentence case, where the
/// Mac's table has "Read the Text Below Aloud" and "Delete All…".
/// </summary>
public sealed class VoicesWordingTests
{
    [Theory]
    [InlineData("Прочитай вслух текст ниже", "Read the text below aloud")]
    [InlineData("Расскажи что-нибудь вслух", "Say something aloud")]
    [InlineData("Добавить язык…", "Add language…")]
    [InlineData("Записать заново", "Record again")]
    [InlineData("Записать заново…", "Record again…")]
    [InlineData("Удалить все…", "Delete all…")]
    [InlineData("Удалить голос", "Delete voice")]
    public void SentenceCase(string key, string english)
    {
        Assert.Equal(english, ProjectsWordingTests.WindowsEnglish().GetValueOrDefault(key));
    }
}
