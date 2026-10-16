using System.Runtime.InteropServices;

namespace GooglePhotosBackup.Core;

/// <summary>Minimal traversal boundary for portable-device catalogs. Device folders can disappear while they are being read.</summary>
public interface IDeviceMediaCatalogFolder
{
    string Name { get; }
    Task<IReadOnlyList<IDeviceMediaCatalogFile>> GetFilesAsync(CancellationToken cancellationToken);
    Task<IReadOnlyList<IDeviceMediaCatalogFolder>> GetFoldersAsync(CancellationToken cancellationToken);
}

public interface IDeviceMediaCatalogFile
{
    string ObjectId { get; }
    string Name { get; }
    Task<long> GetSizeAsync(CancellationToken cancellationToken);
}

public sealed record DeviceMediaCatalogEntry(IDeviceMediaCatalogFile File, string AlbumName, long Size);
public sealed record DeviceMediaCatalogResult(IReadOnlyList<DeviceMediaCatalogEntry> Items, int SkippedEntries);

/// <summary>Walks a portable device without hiding a failed root device or cancellation.</summary>
public static class DeviceMediaCatalog
{
    private const int NotFoundHResult = unchecked((int)0x80070490);
    private const int FileNotFoundHResult = unchecked((int)0x80070002);
    private const int PathNotFoundHResult = unchecked((int)0x80070003);
    private const int AccessDeniedHResult = unchecked((int)0x80070005);

    public static async Task<DeviceMediaCatalogResult> ReadAsync(
        IDeviceMediaCatalogFolder root,
        int maximumItems,
        Func<string, bool> isMedia,
        CancellationToken cancellationToken)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maximumItems);
        var items = new List<DeviceMediaCatalogEntry>();
        var skipped = 0;
        await WalkAsync(root, root.Name, isRoot: true).ConfigureAwait(false);
        return new DeviceMediaCatalogResult(items, skipped);

        async Task WalkAsync(IDeviceMediaCatalogFolder folder, string album, bool isRoot)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                var files = await folder.GetFilesAsync(cancellationToken).ConfigureAwait(false);
                foreach (var file in files)
                {
                    if (items.Count >= maximumItems) return;
                    if (!isMedia(file.Name)) continue;
                    try
                    {
                        var size = await file.GetSizeAsync(cancellationToken).ConfigureAwait(false);
                        items.Add(new DeviceMediaCatalogEntry(file, album, size));
                    }
                    catch (Exception ex) when (!cancellationToken.IsCancellationRequested && IsSkippable(ex))
                    {
                        skipped++;
                    }
                }

                var folders = await folder.GetFoldersAsync(cancellationToken).ConfigureAwait(false);
                foreach (var child in folders)
                {
                    if (items.Count >= maximumItems) return;
                    await WalkAsync(child, child.Name, isRoot: false).ConfigureAwait(false);
                }
            }
            catch (Exception ex) when (!isRoot && !cancellationToken.IsCancellationRequested && IsSkippable(ex))
            {
                skipped++;
            }
        }
    }

    private static bool IsSkippable(Exception exception) => exception switch
    {
        UnauthorizedAccessException => true,
        IOException { HResult: FileNotFoundHResult or PathNotFoundHResult or AccessDeniedHResult } => true,
        COMException { HResult: NotFoundHResult or FileNotFoundHResult or PathNotFoundHResult or AccessDeniedHResult } => true,
        _ => false
    };
}
