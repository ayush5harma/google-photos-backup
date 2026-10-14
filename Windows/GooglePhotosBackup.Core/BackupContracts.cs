using System.Text.Json.Nodes;

namespace GooglePhotosBackup.Core;

public sealed record BackupOptions(IReadOnlyList<string> Folders, string Quality = "original", bool MirrorFolders = true, int Threads = 2);

public sealed record BackupProgress(string Phase, int Completed, int Total, int Failed, string? CurrentFile = null, string? Message = null);

public sealed record BackupSummary(int Uploaded, int Existing, int Failed, bool Canceled);

public interface IBridgeClient
{
    Task<int> ExecuteAsync(JsonObject request, Action<JsonObject> onEvent, CancellationToken cancellationToken);
}
