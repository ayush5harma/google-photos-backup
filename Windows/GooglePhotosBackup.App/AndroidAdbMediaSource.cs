using System.Diagnostics;
using GooglePhotosBackup.Core;

namespace GooglePhotosBackup.App;

/// <summary>Optional Android transport for a user-paired adb device. adb is never bundled or enabled by default.</summary>
internal sealed class AndroidAdbMediaSource : IDeviceMediaSource
{
    private const int MaxListedItems = 2_000;
    private readonly string? _adb = FindAdb();

    public async Task<IReadOnlyList<DeviceDescriptor>> GetDevicesAsync(CancellationToken ct)
    {
        if (_adb is null) return [];
        var lines = await TextAsync(["devices", "-l"], ct).ConfigureAwait(false);
        return lines.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Where(line => line.Contains(" device", StringComparison.Ordinal))
            .Select(line => line.Split(' ', StringSplitOptions.RemoveEmptyEntries)[0])
            .Select(id => new DeviceDescriptor(id, "Android device " + id, "Android (ADB)", "Unlocked and paired"))
            .ToList();
    }

    public async Task<IReadOnlyList<DeviceMediaItem>> GetMediaAsync(string deviceId, CancellationToken ct)
    {
        RequireAdb();
        var output = await TextAsync(["-s", deviceId, "shell", "find /sdcard/DCIM /sdcard/Pictures -type f 2>/dev/null | head -n " + MaxListedItems], ct).ConfigureAwait(false);
        var paths = output.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Where(path => IsMedia(path)).ToArray();
        var items = new List<DeviceMediaItem>();
        foreach (var path in paths)
        {
            ct.ThrowIfCancellationRequested();
            var sizeText = await TextAsync(["-s", deviceId, "shell", "stat -c %s " + Quote(path)], ct).ConfigureAwait(false);
            if (!long.TryParse(sizeText.Trim(), out var size) || size < 0) continue;
            var name = Path.GetFileName(path);
            var parent = Path.GetFileName(Path.GetDirectoryName(path)?.TrimEnd('/') ?? "");
            items.Add(new DeviceMediaItem(deviceId, path, name, size, string.IsNullOrWhiteSpace(parent) ? "Android device" : parent));
        }
        return items;
    }

    public async Task<Stream> OpenReadAsync(DeviceMediaItem item, CancellationToken ct)
    {
        RequireAdb();
        var process = Start("-s", item.DeviceId, "exec-out", "cat " + Quote(item.ObjectId));
        try
        {
            await Task.Yield();
            ct.ThrowIfCancellationRequested();
            return new ProcessReadStream(process);
        }
        catch { process.Dispose(); throw; }
    }

    private async Task<string> TextAsync(string[] args, CancellationToken ct)
    {
        using var process = Start(args);
        var text = await process.StandardOutput.ReadToEndAsync(ct).ConfigureAwait(false);
        var error = await process.StandardError.ReadToEndAsync(ct).ConfigureAwait(false);
        await process.WaitForExitAsync(ct).ConfigureAwait(false);
        if (process.ExitCode != 0) throw new IOException(string.IsNullOrWhiteSpace(error) ? "Android device is unavailable." : "Android device is unavailable.");
        return text;
    }
    private Process Start(params string[] args)
    {
        RequireAdb();
        var start = new ProcessStartInfo(_adb!) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        foreach (var arg in args) start.ArgumentList.Add(arg);
        return Process.Start(start) ?? throw new IOException("Android Platform Tools could not start.");
    }
    private void RequireAdb() { if (_adb is null) throw new InvalidOperationException("Install Android Platform Tools and pair the phone with adb to import Android media."); }
    private static string? FindAdb()
    {
        var path = Environment.GetEnvironmentVariable("PATH")?.Split(Path.PathSeparator) ?? [];
        return path.Select(folder => Path.Combine(folder, OperatingSystem.IsWindows() ? "adb.exe" : "adb")).FirstOrDefault(File.Exists);
    }
    private static bool IsMedia(string path) => new[] { ".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".gif", ".mp4", ".mov", ".m4v" }.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);
    private static string Quote(string value) => "'" + value.Replace("'", "'\\''", StringComparison.Ordinal) + "'";

    private sealed class ProcessReadStream(Process process) : Stream
    {
        private readonly Stream _inner = process.StandardOutput.BaseStream;
        public override bool CanRead => _inner.CanRead; public override bool CanSeek => false; public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException(); public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int offset, int count) => _inner.Read(buffer, offset, count);
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) => _inner.ReadAsync(buffer, offset, count, ct);
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) => _inner.ReadAsync(buffer, ct);
        protected override void Dispose(bool disposing) { if (disposing) { _inner.Dispose(); if (!process.HasExited) process.Kill(true); process.Dispose(); } base.Dispose(disposing); }
        public override void Flush() => throw new NotSupportedException(); public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException(); public override void SetLength(long value) => throw new NotSupportedException(); public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
