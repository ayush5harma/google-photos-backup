namespace GooglePhotosBackup.Core;

/// <summary>One bridge upload request, as the parallelism controller reads it.</summary>
/// <param name="Bytes">Bytes of the items Google stored (items it already had send nothing).</param>
/// <param name="Seconds">From sending the request to its last item's answer.</param>
/// <param name="Items">Items that went up (not already in Google Photos).</param>
/// <param name="RateLimited">Google answered HTTP 429 during the request.</param>
/// <param name="ServerFailures">Items that failed in a way sending again may fix: a 5xx, a 408, a dropped
/// connection or a timeout.</param>
/// <param name="IncludesStartUp">The request started the bridge, so its time includes Python's start-up and the
/// sign-in: it counts for pushback, not for speed.</param>
public readonly record struct UploadSample(
    long Bytes, double Seconds, int Items, bool RateLimited, int ServerFailures, bool IncludesStartUp = false);

/// <summary>
/// How many uploads go at once, decided between bridge requests (issue #58, a port of the Mac's
/// UploadParallelism in Sources/PhotosBackupCore/UploadPipeline.swift).
///
/// Automatic starts at four and adds one while each step is measurably faster (10% more bytes a second). A step
/// that is not faster is measured once more at the same level before it counts, so one noisy batch cannot end the
/// climb; a second miss in a row goes back to the best level and stays. Google pushing back ends the climb for the
/// run: a 429 halves the level, two or more retryable failures in one request take one off, and the level only ever
/// goes down after that. Manual uses exactly the chosen number from the first batch to the last.
/// </summary>
public sealed class UploadParallelism
{
    /// <summary>
    /// The bridge's MAX_THREADS (Bridge/gpmc_bridge.py), the most any request may ask for: the bridge refuses a
    /// larger `threads` as a request error, which stops the run. 32 depends on the Mac 0.6.1 change raising the
    /// bridge's cap from 16 to 32 (branch perf/fixed-parallelism); a bundled bridge still at 16 needs this at 16.
    /// Every Windows range (Settings, validation, the automatic ceiling) reads this one constant.
    /// </summary>
    public const int MaximumThreads = 32;
    public const int Initial = 4;
    public const double Improvement = 0.10;
    /// <summary>A level is judged on at least this much: one batch of photos is usually enough, a batch of items
    /// Google already has is not.</summary>
    public const long DecisionBytes = 24_000_000;
    public const double DecisionSeconds = 4;
    /// <summary>One passing 5xx is Google's noise, not pressure.</summary>
    public const int ServerFailuresThatCount = 2;
    /// <summary>Non-improving measurements in a row before the climb settles (issue #58: never lock after one).</summary>
    public const int MissesBeforeSettling = 2;

    private enum Reason { Finding, CheckingAgain, NoFaster, Most, Chosen, RateLimited, ServerTrouble }

    private Reason _reason;
    private int _triedLevel;
    private int _misses;
    private (int Level, double Rate)? _best;
    private long _pendingBytes;
    private double _pendingSeconds;

    private UploadParallelism(bool automatic, int current)
    {
        IsAutomatic = automatic;
        Current = current;
        IsClimbing = automatic && current < MaximumThreads;
        _reason = !automatic ? Reason.Chosen : IsClimbing ? Reason.Finding : Reason.Most;
    }

    public static UploadParallelism Automatic() => new(automatic: true, Initial);

    public static UploadParallelism Manual(int threads)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(threads, 1);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(threads, MaximumThreads);
        return new UploadParallelism(automatic: false, threads);
    }

    public bool IsAutomatic { get; }
    public int Current { get; private set; }
    public bool IsClimbing { get; private set; }

    public void Measured(UploadSample sample)
    {
        if (!IsAutomatic) return;
        if (sample.RateLimited)
        {
            BackOff(Current / 2, Reason.RateLimited);
            return;
        }
        if (sample.ServerFailures >= ServerFailuresThatCount)
        {
            BackOff(Current - 1, Reason.ServerTrouble);
            return;
        }
        if (!IsClimbing || sample.Items <= 0 || sample.IncludesStartUp) return;
        _pendingBytes += sample.Bytes;
        _pendingSeconds += sample.Seconds;
        if (_pendingBytes < DecisionBytes || _pendingSeconds < DecisionSeconds) return;
        var rate = _pendingBytes / _pendingSeconds;
        _pendingBytes = 0;
        _pendingSeconds = 0;
        if (_best is { } best && rate < best.Rate * (1 + Improvement))
        {
            if (++_misses < MissesBeforeSettling)
            {
                _reason = Reason.CheckingAgain;
                return;
            }
            _triedLevel = Current;
            _reason = Reason.NoFaster;
            Current = best.Level;
            IsClimbing = false;
            return;
        }
        _misses = 0;
        _best = (Current, rate);
        _reason = Reason.Finding;
        if (Current < MaximumThreads)
        {
            Current++;
        }
        else
        {
            _reason = Reason.Most;
            IsClimbing = false;
        }
    }

    private void BackOff(int level, Reason cause)
    {
        Current = Math.Max(1, level);
        IsClimbing = false;
        _reason = cause;
        _pendingBytes = 0;
        _pendingSeconds = 0;
    }

    /// <summary>Where it is and why, for the run view.</summary>
    public string Summary
    {
        get
        {
            var level = $"{Current} at a time";
            return _reason switch
            {
                Reason.Finding => level + ", finding the fastest",
                Reason.CheckingAgain => level + ", checking again",
                Reason.NoFaster => $"{level} (no faster at {_triedLevel})",
                Reason.Most => level + " (the most it uses)",
                Reason.Chosen => level + " (chosen in Settings)",
                Reason.RateLimited => level + " (Google asked to slow down)",
                _ => level + " (Google had trouble keeping up)"
            };
        }
    }
}
