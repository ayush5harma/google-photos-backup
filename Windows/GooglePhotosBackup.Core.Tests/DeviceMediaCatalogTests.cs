using System.Runtime.InteropServices;
using GooglePhotosBackup.Core;
using Xunit;

namespace GooglePhotosBackup.Core.Tests;

public sealed class DeviceMediaCatalogTests
{
    [Fact]
    public async Task DuplicateObjectsDoNotHideDistinctFilesWithTheSameNameOrConsumeTheLimit()
    {
        var first = new FakeFolder("DCIM", files: _ => Task.FromResult<IReadOnlyList<IDeviceMediaCatalogFile>>([
            new FakeFile("same-object", "IMG_6245.HEIC", 769010),
            new FakeFile("same-object", "IMG_6245.HEIC", 769010)]));
        var second = new FakeFolder("Other", files: _ => Task.FromResult<IReadOnlyList<IDeviceMediaCatalogFile>>([
            new FakeFile("different-object", "IMG_6245.HEIC", 769010)]));
        var root = new FakeFolder("device", folders: _ => Task.FromResult<IReadOnlyList<IDeviceMediaCatalogFolder>>([first, second]));

        var result = await DeviceMediaCatalog.ReadAsync(root, 2, _ => true, CancellationToken.None);

        Assert.Equal(new[] { "same-object", "different-object" }, result.Items.Select(item => item.File.ObjectId));
        Assert.Equal(0, result.SkippedEntries);
    }

    [Fact]
    public async Task SkipsAnInaccessibleChildFolderAndKeepsItsSiblingMedia()
    {
        var inaccessible = new FakeFolder("unavailable", files: _ => Task.FromException<IReadOnlyList<IDeviceMediaCatalogFile>>(new COMException("not found", unchecked((int)0x80070490))));
        var fixture = new FakeFolder("PhotosBackupWindowsTest", files: _ => Task.FromResult<IReadOnlyList<IDeviceMediaCatalogFile>>([new FakeFile("fixture", "photos-backup-windows-usb-20261016.png", 329)]));
        var root = new FakeFolder("device", folders: _ => Task.FromResult<IReadOnlyList<IDeviceMediaCatalogFolder>>([inaccessible, fixture]));

        var result = await DeviceMediaCatalog.ReadAsync(root, 10, name => name.EndsWith(".png", StringComparison.OrdinalIgnoreCase), CancellationToken.None);

        var item = Assert.Single(result.Items);
        Assert.Equal("photos-backup-windows-usb-20261016.png", item.File.Name);
        Assert.Equal(329, item.Size);
        Assert.Equal(1, result.SkippedEntries);
    }

    [Fact]
    public async Task CancellationPropagatesInsteadOfBeingReportedAsAPartialCatalog()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var root = new FakeFolder("device");

        await Assert.ThrowsAsync<OperationCanceledException>(() => DeviceMediaCatalog.ReadAsync(root, 10, _ => true, cancellation.Token));
    }

    [Fact]
    public async Task SkipsAnUnreadableFileAndKeepsOtherFilesInTheFolder()
    {
        var folder = new FakeFolder("Pictures", files: _ => Task.FromResult<IReadOnlyList<IDeviceMediaCatalogFile>>([
            new FakeFile("missing", "missing.jpg", 0, new UnauthorizedAccessException("access denied")),
            new FakeFile("fixture", "photos-backup-windows-usb-20261016.png", 329)]));

        var result = await DeviceMediaCatalog.ReadAsync(folder, 10, _ => true, CancellationToken.None);

        Assert.Equal("photos-backup-windows-usb-20261016.png", Assert.Single(result.Items).File.Name);
        Assert.Equal(1, result.SkippedEntries);
    }

    [Fact]
    public async Task RootNotFoundIsNotMisreportedAsAnEmptyPartialCatalog()
    {
        var root = new FakeFolder("device", files: _ => Task.FromException<IReadOnlyList<IDeviceMediaCatalogFile>>(new COMException("not found", unchecked((int)0x80070490))));

        await Assert.ThrowsAsync<COMException>(() => DeviceMediaCatalog.ReadAsync(root, 10, _ => true, CancellationToken.None));
    }

    private sealed class FakeFolder(
        string name,
        Func<CancellationToken, Task<IReadOnlyList<IDeviceMediaCatalogFile>>>? files = null,
        Func<CancellationToken, Task<IReadOnlyList<IDeviceMediaCatalogFolder>>>? folders = null) : IDeviceMediaCatalogFolder
    {
        public string Name => name;
        public Task<IReadOnlyList<IDeviceMediaCatalogFile>> GetFilesAsync(CancellationToken cancellationToken) => files?.Invoke(cancellationToken) ?? Task.FromResult<IReadOnlyList<IDeviceMediaCatalogFile>>([]);
        public Task<IReadOnlyList<IDeviceMediaCatalogFolder>> GetFoldersAsync(CancellationToken cancellationToken) => folders?.Invoke(cancellationToken) ?? Task.FromResult<IReadOnlyList<IDeviceMediaCatalogFolder>>([]);
    }

    private sealed class FakeFile(string objectId, string name, long size, Exception? failure = null) : IDeviceMediaCatalogFile
    {
        public string ObjectId => objectId;
        public string Name => name;
        public Task<long> GetSizeAsync(CancellationToken cancellationToken) => failure is null ? Task.FromResult(size) : Task.FromException<long>(failure);
    }
}
