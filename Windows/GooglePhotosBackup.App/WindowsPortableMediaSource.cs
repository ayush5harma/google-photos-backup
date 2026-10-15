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
        _files.Keys.Where(key => key.StartsWith(deviceId + "\n", StringComparison.Ordinal)).ToList().ForEach(key => _files.Remove(key));
        var root = StorageDevice.FromId(deviceId) ?? throw new IOException("Windows could not open the connected device.");
        var items = new List<DeviceMediaItem>();
        await WalkAsync(root, deviceId, "Connected device", items, ct).ConfigureAwait(false);
        return items;
    }

    public async Task<Stream> OpenReadAsync(DeviceMediaItem item, CancellationToken ct)
    {
        if (!_files.TryGetValue(Key(item.DeviceId, item.ObjectId), out var file))
            throw new IOException("The selected device media is no longer available.");
        var stream = await file.OpenReadAsync().AsTask(ct).ConfigureAwait(false);
        return stream.AsStreamForRead();
    }

    private async Task WalkAsync(StorageFolder folder, string deviceId, string album, List<DeviceMediaItem> items, CancellationToken ct)
    {
        if (items.Count >= MaxItems) return;
        var files = await folder.GetFilesAsync().AsTask(ct).ConfigureAwait(false);
        foreach (var file in files)
        {
            if (items.Count >= MaxItems) return;
            if (!IsMedia(file.Name)) continue;
            var objectId = file.FolderRelativeId;
            var size = (await file.GetBasicPropertiesAsync().AsTask(ct).ConfigureAwait(false)).Size;
            _files[Key(deviceId, objectId)] = file;
            items.Add(new DeviceMediaItem(deviceId, objectId, file.Name, checked((long)size), album));
        }
        var folders = await folder.GetFoldersAsync().AsTask(ct).ConfigureAwait(false);
        foreach (var child in folders)
        {
            if (items.Count >= MaxItems) return;
            await WalkAsync(child, deviceId, child.Name, items, ct).ConfigureAwait(false);
        }
    }

    private static string Key(string deviceId, string objectId) => deviceId + "\n" + objectId;
    private static bool IsMedia(string name) => new[] { ".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".gif", ".mp4", ".mov", ".m4v", ".avi" }.Contains(Path.GetExtension(name), StringComparer.OrdinalIgnoreCase);
}
