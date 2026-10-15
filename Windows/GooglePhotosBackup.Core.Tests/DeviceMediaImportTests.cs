using GooglePhotosBackup.Core;
using Xunit;

namespace GooglePhotosBackup.Core.Tests;

public sealed class DeviceMediaImportTests
{
    [Fact]
    public async Task StagingUsesDeviceObjectIdentityAndNeverFilenameForDuplicates()
    {
        using var temp = new TempFolder();
        var source = new FakeDeviceSource([new("d", "a", "IMG.jpg", 3), new("d", "b", "IMG.jpg", 3)]);
        var staged = await new DeviceMediaStager(temp.Root).StageAsync(source, source.Items, CancellationToken.None);
        Assert.Equal(2, staged.Count);
        Assert.NotEqual(staged[0].Path, staged[1].Path);
        Assert.All(staged, item => Assert.Equal("abc", File.ReadAllText(item.Path)));
    }

    [Fact]
    public async Task PartialCopyIsRemovedWhenDeviceDisconnects()
    {
        using var temp = new TempFolder();
        var source = new FakeDeviceSource([new("d", "a", "IMG.jpg", 4)], fail: true);
        await Assert.ThrowsAsync<IOException>(() => new DeviceMediaStager(temp.Root).StageAsync(source, source.Items, CancellationToken.None));
        Assert.Empty(Directory.EnumerateFiles(temp.Root, "*.partial", SearchOption.AllDirectories));
    }

    [Fact]
    public async Task StagingRejectsBudgetBeforeOpeningSource()
    {
        using var temp = new TempFolder();
        var source = new FakeDeviceSource([new("d", "a", "IMG.jpg", 8)]);
        await Assert.ThrowsAsync<InvalidOperationException>(() => new DeviceMediaStager(temp.Root, 4).StageAsync(source, source.Items, CancellationToken.None));
        Assert.Equal(0, source.Opened);
    }

    [Fact]
    public async Task StagingRejectsZeroSizedItemsBeforeOpeningSource()
    {
        using var temp = new TempFolder();
        var source = new FakeDeviceSource([new("d", "a", "IMG.jpg", 0)]);

        await Assert.ThrowsAsync<InvalidOperationException>(() => new DeviceMediaStager(temp.Root).StageAsync(source, source.Items, CancellationToken.None));

        Assert.Equal(0, source.Opened);
    }

    [Fact]
    public async Task StagingRemovesPartialWhenSourceExceedsReportedSize()
    {
        using var temp = new TempFolder();
        var source = new FakeDeviceSource([new("d", "a", "IMG.jpg", 3)], bytes: "abcd"u8.ToArray());

        await Assert.ThrowsAsync<IOException>(() => new DeviceMediaStager(temp.Root).StageAsync(source, source.Items, CancellationToken.None));

        Assert.Empty(Directory.EnumerateFiles(temp.Root, "*.partial", SearchOption.AllDirectories));
        Assert.Empty(Directory.EnumerateFiles(temp.Root, "*.jpg", SearchOption.AllDirectories));
    }

    [Fact]
    public async Task StagingRespectsBytesAlreadyRetainedInCache()
    {
        using var temp = new TempFolder();
        File.WriteAllBytes(Path.Combine(temp.Root, "retained.media"), "abc"u8.ToArray());
        var source = new FakeDeviceSource([new("d", "a", "IMG.jpg", 2)], bytes: "ab"u8.ToArray());

        await Assert.ThrowsAsync<InvalidOperationException>(() => new DeviceMediaStager(temp.Root, 4).StageAsync(source, source.Items, CancellationToken.None));

        Assert.Equal(0, source.Opened);
        Assert.True(File.Exists(Path.Combine(temp.Root, "retained.media")));
    }

    [Fact]
    public async Task CompletedMediaIsRetainedUntilExplicitCleanup()
    {
        using var temp = new TempFolder();
        var source = new FakeDeviceSource([new("d", "a", "IMG.jpg", 3)]);
        var stager = new DeviceMediaStager(temp.Root);

        var staged = await stager.StageAsync(source, source.Items, CancellationToken.None);
        Assert.True(File.Exists(staged[0].Path));

        stager.ClearCompleted();
        Assert.False(File.Exists(staged[0].Path));
    }

    private sealed class FakeDeviceSource(IReadOnlyList<DeviceMediaItem> items, bool fail = false, byte[]? bytes = null) : IDeviceMediaSource
    {
        public IReadOnlyList<DeviceMediaItem> Items { get; } = items;
        public int Opened { get; private set; }
        public Task<IReadOnlyList<DeviceDescriptor>> GetDevicesAsync(CancellationToken ct) => Task.FromResult<IReadOnlyList<DeviceDescriptor>>([]);
        public Task<IReadOnlyList<DeviceMediaItem>> GetMediaAsync(string id, CancellationToken ct) => Task.FromResult(Items);
        public Task<Stream> OpenReadAsync(DeviceMediaItem item, CancellationToken ct)
        {
            Opened++;
            if (fail) throw new IOException("disconnected");
            return Task.FromResult<Stream>(new MemoryStream(bytes ?? "abc"u8.ToArray()));
        }
    }

    private sealed class TempFolder : IDisposable
    {
        public TempFolder()
        {
            Root = Path.Combine(Path.GetTempPath(), "PhotosBackupDeviceTests", Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Root);
        }
        public string Root { get; }
        public void Dispose()
        {
            try { if (Directory.Exists(Root)) Directory.Delete(Root, true); } catch { }
        }
    }
}
