namespace Sozvon.Audio.Tracks;

/// <summary>
/// Drops the first packets of a newly opened microphone stream until their timestamps run evenly. Measured on a raw
/// microphone, the first four or five packets carry bunched times, about 100 ms apart from the steady ones after them:
/// placing those would write a fake gap at the start and then correct a drift that is not there.
/// </summary>
internal sealed class StartupSettler(int sampleRate)
{
    private const int ContiguousPacketsNeeded = 3;
    private const int GiveUpAfterPackets = 100;
    private const double ToleranceSeconds = 0.002;

    private double _expected = double.NaN;
    private int _contiguous;
    private int _seen;
    private bool _settled;

    /// <returns>True when the packet may be written.</returns>
    public bool Accept(double startSeconds, int frames)
    {
        if (_settled) return true;
        if (double.IsNaN(startSeconds))
        {
            _settled = true;
            return true;
        }

        _seen++;
        bool contiguous = !double.IsNaN(_expected) && Math.Abs(startSeconds - _expected) <= ToleranceSeconds;
        _contiguous = contiguous ? _contiguous + 1 : 0;
        _expected = startSeconds + frames / (double)sampleRate;
        _settled = _contiguous >= ContiguousPacketsNeeded || _seen >= GiveUpAfterPackets;
        return _settled;
    }
}
