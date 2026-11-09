namespace Sozvon.App.Setup.Pages;

public sealed record SetupFooter(bool BackVisible, string PrimaryText, bool PrimaryEnabled = true, bool PrimaryIsAccent = true);

/// <summary>One step of the wizard: the header and footer it wants, and what its main button does.</summary>
public interface ISetupPage
{
    string Glyph { get; }
    string Title { get; }
    string Subtitle { get; }
    SetupFooter Footer { get; }

    /// <summary>The header or the footer changed.</summary>
    event Action? Changed;

    void OnShown();

    /// <summary>Runs the main button. True moves on to the next step.</summary>
    bool Primary();
}
