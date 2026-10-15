using GooglePhotosBackup.Core;
using Windows.Devices.Enumeration;

namespace GooglePhotosBackup.App;

/// <summary>Catalogues the Windows-supported WPD/MTP/PTP devices without asking for broad filesystem access.</summary>
internal static class WindowsPortableDeviceCatalog
{
    public static async Task<IReadOnlyList<DeviceDescriptor>> GetDevicesAsync()
    {
        var found = new Dictionary<string, DeviceDescriptor>(StringComparer.OrdinalIgnoreCase);
        foreach (var kind in new[] { DeviceClass.PortableStorageDevice })
        {
            var devices = await DeviceInformation.FindAllAsync(kind);
            foreach (var device in devices)
            {
                if (!device.IsEnabled || found.ContainsKey(device.Id)) continue;
                var name = string.IsNullOrWhiteSpace(device.Name) ? "Connected device" : device.Name;
                var status = "Portable storage / DCIM device";
                found[device.Id] = new DeviceDescriptor(device.Id, name, "Windows device", status);
            }
        }
        return found.Values.OrderBy(device => device.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
    }
}
