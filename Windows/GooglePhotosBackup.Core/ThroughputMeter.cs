using System.Globalization;

namespace GooglePhotosBackup.Core;

/// <summary>
/// Upload speed and time left for the run view, from the bridge's per-file progress (bytes actually sent) and item
/// outcomes. A port of the Mac's ThroughputMeter (Sources/PhotosBackupCore/UploadPipeline.swift). Not thread-safe:
/// the coordinator feeds it from the bridge's event callback, one event at a time.
/// </summary>
public sealed class ThroughputMeter
{
    /// <summary>Speed is what was sent over the last half minute.</summary>
    public static readonly TimeSpan Window = TimeSpan.FromSeconds(30);
    /// <summary>Time left follows the items finished over the last three minutes.</summary>
    public static readonly TimeSpan ItemWindow = TimeSpan.FromMinutes(3);
    private static readonly TimeSpan MinimumSpan = TimeSpan.FromSeconds(5);
    private const int MinimumItems = 5;

    private readonly Dictionary<string, long> _perItem = new(StringComparer.Ordinal);
    private readonly List<(DateTimeOffset At, long Total)> _marks = [];
    private readonly List<DateTimeOffset> _finishes = [];

    /// <summary>Every byte the uploads have sent this run, retries included.</summary>
    public long BytesSent { get; private set; }

    /// <summary>The bridge says <paramref name="total"/> bytes of item <paramref name="id"/> have gone so far.</summary>
    public void Sent(string id, long total, DateTimeOffset now)
    {
        var before = _perItem.GetValueOrDefault(id);
        // Less than before: the item started over (a new attempt).
        var added = total >= before ? total - before : total;
        _perItem[id] = total;
        if (added <= 0) return;
        BytesSent += added;
        _marks.Add((now, BytesSent));
        // Keep one mark at or before the window's start as the baseline.
        while (_marks.Count > 2 && _marks[1].At <= now - Window) _marks.RemoveAt(0);
    }

    /// <summary>Item <paramref name="id"/> has an outcome; if it is sent again it starts from nothing.</summary>
    public void Finished(string id, DateTimeOffset now)
    {
        _perItem.Remove(id);
        _finishes.Add(now);
        _finishes.RemoveAll(at => at < now - ItemWindow);
    }

    public double? BytesPerSecond(DateTimeOffset now)
    {
        if (_marks.Count == 0) return null;
        var start = now - Window;
        var baseline = _marks.LastOrDefault(mark => mark.At <= start, _marks[0]);
        var span = now - baseline.At;
        if (span < MinimumSpan) return null;
        return (_marks[^1].Total - baseline.Total) / span.TotalSeconds;
    }

    public double? SecondsLeft(int remaining, DateTimeOffset now)
    {
        if (remaining <= 0) return 0;
        var recent = _finishes.Where(at => at >= now - ItemWindow).ToList();
        if (recent.Count < MinimumItems) return null;
        var span = (now - recent[0]).TotalSeconds;
        if (span <= 0) return null;
        return remaining * span / (recent.Count - 1);
    }

    /// <summary>"12.3 MB/s, about 14 min left"; null until there is a speed to show.</summary>
    public static string? Describe(double? bytesPerSecond, double? secondsLeft)
    {
        if (bytesPerSecond is not { } rate) return null;
        var speed = Speed(rate);
        return secondsLeft is { } left ? $"{speed}, {TimeLeft(left)}" : speed;
    }

    /// <summary>"12.3 MB/s" (decimal megabytes, as Explorer's transfer dialogs count them).</summary>
    public static string Speed(double bytesPerSecond) =>
        (bytesPerSecond / 1_000_000).ToString("0.0", CultureInfo.InvariantCulture) + " MB/s";

    public static string TimeLeft(double seconds)
    {
        var minutes = (int)Math.Round(seconds / 60, MidpointRounding.AwayFromZero);
        if (seconds < 60 || minutes == 0) return "less than a minute left";
        if (minutes < 60) return $"about {minutes} min left";
        var hours = minutes / 60;
        var rest = minutes % 60;
        return rest == 0 ? $"about {hours} h left" : $"about {hours} h {rest} min left";
    }
}
