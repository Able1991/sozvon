namespace Sozvon.Core.Engine;

/// <summary>A protocol line: <c>RESULT: ok [value]</c> or <c>RESULT: error &lt;code&gt; &lt;message&gt;</c>.</summary>
public sealed record ResultLine(bool Ok, int? Code, string Message);

/// <summary>The result of an engine run: the exit code and the RESULT line (contract section 5).</summary>
public abstract record RunOutcome(string Message)
{
    public sealed record Ok() : RunOutcome("");

    /// <summary>2: no audio on any track, or invalid input.</summary>
    public sealed record NoAudio(string Text) : RunOutcome(Text);

    /// <summary>3: the engine is broken.</summary>
    public sealed record EngineBroken(string Text) : RunOutcome(Text);

    /// <summary>4: the model is not downloaded.</summary>
    public sealed record ModelMissing(string Text) : RunOutcome(Text);

    /// <summary>5: ffmpeg could not read the recording.</summary>
    public sealed record Damaged(string Text) : RunOutcome(Text);

    /// <summary>1 and everything else, including a process killed or one that failed to start.</summary>
    public sealed record Failed(int Code, string Text) : RunOutcome(Text);

    public bool IsOk => this is Ok;

    public static ResultLine? ParseLine(string line)
    {
        var l = line.Trim();
        if (!l.StartsWith("RESULT:", StringComparison.Ordinal)) return null;
        var rest = l["RESULT:".Length..].Trim();
        if (rest == "ok") return new ResultLine(true, 0, "");
        if (rest.StartsWith("ok ", StringComparison.Ordinal)) return new ResultLine(true, 0, rest[3..].Trim());
        if (!rest.StartsWith("error", StringComparison.Ordinal)) return null;
        var tail = rest["error".Length..].Trim();
        var parts = tail.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length > 0 && int.TryParse(parts[0], out var code))
            return new ResultLine(false, code, parts.Length > 1 ? parts[1] : "");
        return new ResultLine(false, null, tail);
    }

    /// <summary>The exit code wins; the RESULT code refines a generic exit code of 1 or a 0 with an error line.</summary>
    public static RunOutcome Parse(int exitCode, ResultLine? result, string? lastLine = null)
    {
        var code = exitCode;
        if (result is { Ok: false, Code: { } resultCode and not 0 } && code is 0 or 1) code = resultCode;
        if (code == 0 && result is { Ok: false }) code = 1;
        if (code == 0) return new Ok();
        var message = !string.IsNullOrEmpty(result?.Message) ? result.Message : lastLine?.Trim() ?? "";
        return code switch
        {
            2 => new NoAudio(message),
            3 => new EngineBroken(message),
            4 => new ModelMissing(message),
            5 => new Damaged(message),
            _ => new Failed(code, message),
        };
    }

    /// <summary>The same over all output lines: the last RESULT line and the last line with text.</summary>
    public static RunOutcome Parse(int exitCode, IReadOnlyList<string> lines)
    {
        var tracker = new OutputTracker();
        foreach (var line in lines) tracker.Consume(line);
        return Parse(exitCode, tracker.Result, tracker.LastLine);
    }
}

/// <summary>Follows the engine's output for the last line and the RESULT line.</summary>
public sealed class OutputTracker
{
    public string? LastLine { get; private set; }
    public ResultLine? Result { get; private set; }

    public void Consume(string line)
    {
        if (RunOutcome.ParseLine(line) is { } result) Result = result;
        if (line.Trim().Length > 0) LastLine = line;
    }
}
