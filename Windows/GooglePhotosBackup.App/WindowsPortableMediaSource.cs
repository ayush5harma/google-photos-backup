using GooglePhotosBackup.Core;
using Windows.Devices.Enumeration;
using Windows.Devices.Portable;
using Windows.Storage;

namespace GooglePhotosBackup.App;

/// <summary>Uses the Windows-supported WPD/MTP/PTP StorageDevice API. iPhones are included when their driver exposes DCIM.</summary>
internal sealed class WindowsPortableMediaSource : IDeviceMediaSource
{
    private const int MaxItems = 2_000;
    private readonly Dictionary<string, StorageFile> _files = new(StringComparer.Ordinal);
    public string? LastCatalogWarning { get; private set; }

    public async Task<IReadOnlyList<DeviceDescriptor>> GetDevicesAsync(CancellationToken ct)
    {
        var selector = StorageDevice.GetDeviceSelector();
        var devices = await DeviceInformation.FindAllAsync(selector).AsTask(ct);
        return devices.Where(device => device.IsEnabled)
            .Select(device => new DeviceDescriptor(device.Id, string.IsNullOrWhiteSpace(device.Name) ? "Connected device" : device.Name,
                "Windows portable device", "Unlock and trust the device to browse media"))
            .ToArray();
    }

    public async Task<IReadOnlyList<DeviceMediaItem>> GetMediaAsync(string deviceId, CancellationToken ct)
    {
        LastCatalogWarning = null;
        _files.Keys.Where(key => key.StartsWith(deviceId + "\n", StringComparison.Ordinal)).ToList().ForEach(key => _files.Remove(key));
        var root = StorageDevice.FromId(deviceId) ?? throw new IOException("Windows could not open the connected device.");
        var catalog = await DeviceMediaCatalog.ReadAsync(new PortableFolder(root), MaxItems, IsMedia, ct).ConfigureAwait(false);
        var items = new List<DeviceMediaItem>(catalog.Items.Count);
        foreach (var entry in catalog.Items)
        {
            var file = ((PortableFile)entry.File).File;
            _files[Key(deviceId, entry.File.ObjectId)] = file;
            items.Add(new DeviceMediaItem(deviceId, entry.File.ObjectId, entry.File.Name, entry.Size, entry.AlbumName));
        }
        if (catalog.SkippedEntries > 0)
            LastCatalogWarning = $"Some device folders or files could not be read ({catalog.SkippedEntries} skipped). The media list may be incomplete.";
        return items;
    }

    public async Task<Stream> OpenReadAsync(DeviceMediaItem item, CancellationToken ct)
    {
        if (!_files.TryGetValue(Key(item.DeviceId, item.ObjectId), out var file))
            throw new IOException("The selected device media is no longer available.");
        var stream = await file.OpenReadAsync().AsTask(ct).ConfigureAwait(false);
        return stream.AsStreamForRead();
    }

    private sealed class PortableFolder(StorageFolder folder) : IDeviceMediaCatalogFolder
    {
        public string Name => folder.Name;
        public async Task<IReadOnlyList<IDeviceMediaCatalogFile>> GetFilesAsync(CancellationToken ct) =>
            (await folder.GetFilesAsync().AsTask(ct).ConfigureAwait(false)).Select(file => (IDeviceMediaCatalogFile)new PortableFile(file)).ToArray();
        public async Task<IReadOnlyList<IDeviceMediaCatalogFolder>> GetFoldersAsync(CancellationToken ct) =>
            (await folder.GetFoldersAsync().AsTask(ct).ConfigureAwait(false)).Select(child => (IDeviceMediaCatalogFolder)new PortableFolder(child)).ToArray();
    }

    private sealed class PortableFile(StorageFile file) : IDeviceMediaCatalogFile
    {
        public StorageFile File => file;
        public string ObjectId => file.FolderRelativeId;
        public string Name => file.Name;
        public async Task<long> GetSizeAsync(CancellationToken ct) => checked((long)(await file.GetBasicPropertiesAsync().AsTask(ct).ConfigureAwait(false)).Size);
    }

    private static string Key(string deviceId, string objectId) => deviceId + "\n" + objectId;
    private static bool IsMedia(string name) => new[] { ".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".gif", ".mp4", ".mov", ".m4v", ".avi" }.Contains(Path.GetExtension(name), StringComparer.OrdinalIgnoreCase);
}
