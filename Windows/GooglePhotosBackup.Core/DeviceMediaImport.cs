using System.Security.Cryptography;
using System.Text;

namespace GooglePhotosBackup.Core;

/// <summary>Boundary for MTP/PTP/WPD implementations.  A device object's id is stable on that device,
/// unlike a filename, and is consequently safe to use for resume state.</summary>
public interface IDeviceMediaSource
{
    Task<IReadOnlyList<DeviceDescriptor>> GetDevicesAsync(CancellationToken cancellationToken);
    Task<IReadOnlyList<DeviceMediaItem>> GetMediaAsync(string deviceId, CancellationToken cancellationToken);
    Task<Stream> OpenReadAsync(DeviceMediaItem item, CancellationToken cancellationToken);
}

public sealed record DeviceDescriptor(string Id, string Name, string Kind, string Status);
public sealed record DeviceMediaItem(string DeviceId, string ObjectId, string Name, long Size, string? AlbumName = null);
public sealed record StagedDeviceMedia(string StableId, string Path, string AlbumName);

/// <summary>
/// Copies explicitly selected device objects to a private, bounded cache.  The backup engine only ever
/// receives local, complete files; unplug/cancel failures never become upload candidates.
/// </summary>
public sealed class DeviceMediaStager(string root, long maximumBytes = 2L * 1024 * 1024 * 1024)
{
    public async Task<IReadOnlyList<StagedDeviceMedia>> StageAsync(
        IDeviceMediaSource source, IReadOnlyList<DeviceMediaItem> selected, CancellationToken ct)
    {
        if (selected.Count == 0) return [];
        if (selected.Sum(item => item.Size) > maximumBytes)
            throw new InvalidOperationException("Selected device media exceeds the private staging limit.");
        var output = new List<StagedDeviceMedia>();
        foreach (var item in selected)
        {
            ct.ThrowIfCancellationRequested();
            if (string.IsNullOrWhiteSpace(item.DeviceId) || string.IsNullOrWhiteSpace(item.ObjectId) || item.Size < 0)
                throw new InvalidOperationException("The connected device returned an invalid media item.");
            var stableId = Hash(item.DeviceId + "\n" + item.ObjectId);
            var deviceDir = Path.Combine(root, Hash(item.DeviceId));
            Directory.CreateDirectory(deviceDir);
            var finalPath = Path.Combine(deviceDir, stableId + SafeExtension(item.Name));
            if (!File.Exists(finalPath))
            {
                var temporary = finalPath + ".partial";
                try
                {
                    await using var input = await source.OpenReadAsync(item, ct).ConfigureAwait(false);
                    await using var outputStream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None,
                        128 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
                    await input.CopyToAsync(outputStream, 128 * 1024, ct).ConfigureAwait(false);
                    await outputStream.FlushAsync(ct).ConfigureAwait(false);
                    if (item.Size != 0 && new FileInfo(temporary).Length != item.Size)
                        throw new IOException("The device disconnected before the media copy finished.");
                    File.Move(temporary, finalPath, false);
                }
                catch
                {
                    try { if (File.Exists(temporary)) File.Delete(temporary); } catch { }
                    throw;
                }
            }
            output.Add(new StagedDeviceMedia(stableId, finalPath, CleanAlbumName(item.AlbumName, item.Name)));
        }
        return output;
    }

    public void CleanupIncomplete()
    {
        if (!Directory.Exists(root)) return;
        foreach (var partial in Directory.EnumerateFiles(root, "*.partial", SearchOption.AllDirectories))
            try { File.Delete(partial); } catch { }
    }

    private static string SafeExtension(string name)
    {
        var extension = Path.GetExtension(name);
        return extension.Length is > 0 and <= 10 && extension.All(c => char.IsLetterOrDigit(c) || c == '.') ? extension : ".media";
    }
    private static string CleanAlbumName(string? album, string fallback) =>
        string.IsNullOrWhiteSpace(album) ? "Connected device" : album.Trim()[..Math.Min(120, album.Trim().Length)];
    private static string Hash(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
}
