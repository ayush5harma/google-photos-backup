using System.Text.Json.Nodes;

namespace GooglePhotosBackup.Core;

/// <param name="Threads">The parallel uploads Manual uses; ignored while <paramref name="ThreadsAutomatic"/>.</param>
/// <param name="ThreadsAutomatic">Let <see cref="UploadParallelism"/> find the fastest number (issue #58).</param>
/// <param name="BatchSize">Items per bridge request. Larger than the Mac's 20 so up to 32 uploads have work to
/// share and sit idle less at each batch's tail.</param>
public sealed record BackupOptions(
    IReadOnlyList<string> Folders, string Quality = "original", bool MirrorFolders = true,
    int Threads = UploadParallelism.Initial, bool ThreadsAutomatic = true, int BatchSize = BackupOptions.DefaultBatchSize)
{
    public const int DefaultBatchSize = 50;
    /// <summary>The smallest Settings offers: under 5 the parallel uploads sit idle at every batch's end.</summary>
    public const int MinimumChosenBatchSize = 5;
    public const int MaximumBatchSize = 100;
}

/// <param name="BytesPerSecond">Upload speed over the last half minute, once there is one.</param>
/// <param name="SecondsLeft">Time left at the recent rate of finished items, once there is one.</param>
/// <param name="Parallelism">How many uploads go at once and why (<see cref="UploadParallelism.Summary"/>).</param>
public sealed record BackupProgress(string Phase, int Completed, int Total, int Failed, string? CurrentFile = null, string? Message = null,
    double? BytesPerSecond = null, double? SecondsLeft = null, string? Parallelism = null);

public sealed record BackupSummary(int Uploaded, int Existing, int Failed, bool Canceled);

public interface IBridgeClient
{
    Task<int> ExecuteAsync(JsonObject request, Action<JsonObject> onEvent, CancellationToken cancellationToken);

    /// <summary>The last request started a bridge process, so its time includes Python's start-up and the
    /// sign-in. Always so for a one-shot client; a serve session says so only when it started or replaced one.</summary>
    bool LastRequestStartedBridge => true;
}
