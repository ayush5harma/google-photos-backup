using System.Text.Json.Nodes;
using GooglePhotosBackup.Core;
using Xunit;

namespace GooglePhotosBackup.Core.Tests;

public sealed class BackupParallelismTests
{
    private static readonly string[] UploadKeys = ["auth_data", "command", "items", "quality", "threads"];
    private static readonly string[] ItemKeys = ["filename", "id", "path"];

    /// <summary>
    /// The hard constraint of issue #58: Original quality is gpmc saver=False, use_quota=False (a Pixel XL, free),
    /// which the bridge derives from quality "original" alone. Every request at every thread count must carry exactly
    /// that and nothing else that could pick a storage mode.
    /// </summary>
    [Fact]
    public async Task OriginalQualityGoesOutUnchangedAtEveryThreadCount()
    {
        for (var threads = 1; threads <= UploadParallelism.MaximumThreads; threads++)
        {
            using var fixture = new TempFolder();
            for (var i = 0; i < 3; i++) File.WriteAllText(Path.Combine(fixture.Root, $"photo{i}.jpg"), new string('x', i + 1));
            var uploads = new List<JsonObject>();
            var bridge = new SessionBridge((request, emit) =>
            {
                if (Command(request) == "check-auth") { Auth(request, emit); return 0; }
                uploads.Add(request);
                foreach (var item in Items(request)) Confirm(item, emit);
                return 0;
            });
            var result = await new BackupCoordinator(bridge, fixture.State).RunAsync(
                new BackupOptions([fixture.Root], MirrorFolders: false, Threads: threads, ThreadsAutomatic: false),
                Credential("one@example.com"), CancellationToken.None);
            Assert.Equal(3, result.Uploaded);
            var request = Assert.Single(uploads);
            AssertOriginal(request, threads);
        }
    }

    [Fact]
    public void EveryLevelTheAutomaticControllerReachesSendsOriginalQuality()
    {
        var parallelism = UploadParallelism.Automatic();
        var visited = new SortedSet<int>();
        var rate = 6_000_000.0;
        while (true)
        {
            visited.Add(parallelism.Current);
            AssertOriginal(BackupCoordinator.UploadRequest(Credential("one@example.com"), "original", parallelism.Current,
                [("id", Path.Combine(Path.GetTempPath(), "a.jpg"))]), parallelism.Current);
            if (!parallelism.IsClimbing) break;
            parallelism.Measured(new UploadSample((long)(rate * 4), 4, 10, false, 0));
            rate *= 1.2;
        }
        // Down again: 429s halve it to 4, repeated server failures take it to 1 one step at a time.
        while (parallelism.Current > 1)
        {
            var rateLimited = parallelism.Current > 4;
            parallelism.Measured(new UploadSample(0, 1, 0, rateLimited, ServerFailures: rateLimited ? 0 : 2));
            visited.Add(parallelism.Current);
            AssertOriginal(BackupCoordinator.UploadRequest(Credential("one@example.com"), "original", parallelism.Current,
                [("id", Path.Combine(Path.GetTempPath(), "a.jpg"))]), parallelism.Current);
        }
        Assert.Equal(Enumerable.Range(1, UploadParallelism.MaximumThreads), visited);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(33)]
    public void NoRequestAsksForMoreThanTheBridgeAllows(int threads)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            BackupCoordinator.UploadRequest(Credential("one@example.com"), "original", threads, []));
    }

    [Fact]
    public async Task AutomaticStartsAtFourAndHalvesWhenGoogleAsksToSlowDown()
    {
        using var fixture = new TempFolder();
        for (var i = 0; i < 3; i++) File.WriteAllText(Path.Combine(fixture.Root, $"p{i}.png"), "p" + i);
        var threads = new List<int>();
        var limited = false;
        var bridge = new SessionBridge((request, emit) =>
        {
            if (Command(request) == "check-auth") { Auth(request, emit); return 0; }
            threads.Add(request["threads"]!.GetValue<int>());
            var item = Assert.Single(Items(request));
            if (!limited)
            {
                limited = true;
                emit(new JsonObject { ["type"] = "item_failed", ["id"] = item["id"]!.GetValue<string>(),
                    ["message"] = "429 Client Error: Too Many Requests for url: https://photos/upload", ["retryable"] = true });
            }
            else Confirm(item, emit);
            return 0;
        });
        var progress = new List<BackupProgress>();
        var coordinator = new BackupCoordinator(bridge, fixture.State);
        coordinator.ProgressChanged += progress.Add;
        var result = await coordinator.RunAsync(new BackupOptions([fixture.Root], MirrorFolders: false, BatchSize: 1),
            Credential("one@example.com"), CancellationToken.None);
        Assert.Equal(3, result.Uploaded);
        Assert.Equal([4, 2, 2, 2], threads);
        Assert.Contains(progress, update => update.Parallelism == "4 at a time, finding the fastest");
        Assert.Equal("2 at a time (Google asked to slow down)", progress.Last(update => update.Phase == "Uploading").Parallelism);
    }

    [Fact]
    public async Task ManualSendsExactlyTheChosenNumberFromTheFirstBatchWhateverGoogleSays()
    {
        using var fixture = new TempFolder();
        for (var i = 0; i < 3; i++) File.WriteAllText(Path.Combine(fixture.Root, $"p{i}.png"), "p" + i);
        var threads = new List<int>();
        var limited = false;
        var bridge = new SessionBridge((request, emit) =>
        {
            if (Command(request) == "check-auth") { Auth(request, emit); return 0; }
            threads.Add(request["threads"]!.GetValue<int>());
            var item = Assert.Single(Items(request));
            if (!limited)
            {
                limited = true;
                emit(new JsonObject { ["type"] = "item_failed", ["id"] = item["id"]!.GetValue<string>(),
                    ["message"] = "429 Client Error: Too Many Requests", ["retryable"] = true });
                emit(new JsonObject { ["type"] = "fatal", ["kind"] = "rate_limit" });
                return 6;
            }
            Confirm(item, emit);
            return 0;
        });
        var result = await new BackupCoordinator(bridge, fixture.State).RunAsync(
            new BackupOptions([fixture.Root], MirrorFolders: false, Threads: 7, ThreadsAutomatic: false, BatchSize: 1),
            Credential("one@example.com"), CancellationToken.None);
        Assert.Equal(3, result.Uploaded);
        Assert.Equal([7, 7, 7, 7], threads);
    }

    [Fact]
    public async Task BatchesHoldFiftyByDefaultAndSendTheLargestFirst()
    {
        using var fixture = new TempFolder();
        for (var i = 0; i < 60; i++) File.WriteAllText(Path.Combine(fixture.Root, $"f{i:00}.jpg"), new string('x', 1 + i % 7));
        var batches = new List<List<long>>();
        var bridge = new SessionBridge((request, emit) =>
        {
            if (Command(request) == "check-auth") { Auth(request, emit); return 0; }
            batches.Add(Items(request).Select(item => new FileInfo(item["path"]!.GetValue<string>()).Length).ToList());
            foreach (var item in Items(request)) Confirm(item, emit);
            return 0;
        });
        await new BackupCoordinator(bridge, fixture.State).RunAsync(new BackupOptions([fixture.Root], MirrorFolders: false),
            Credential("one@example.com"), CancellationToken.None);
        Assert.Equal([50, 10], batches.Select(batch => batch.Count));
        foreach (var batch in batches) Assert.Equal(batch.OrderByDescending(size => size), batch);
    }

    [Theory]
    [InlineData(33, 50)]
    [InlineData(4, 0)]
    [InlineData(4, 101)]
    public async Task OutOfRangeSettingsAreRefusedBeforeAnyRequest(int threads, int batchSize)
    {
        using var fixture = new TempFolder();
        var calls = 0;
        var bridge = new SessionBridge((_, _) => { calls++; return 0; });
        await Assert.ThrowsAsync<ArgumentException>(() => new BackupCoordinator(bridge, fixture.State).RunAsync(
            new BackupOptions([fixture.Root], Threads: threads, ThreadsAutomatic: false, BatchSize: batchSize),
            Credential("one@example.com"), CancellationToken.None));
        Assert.Equal(0, calls);
    }

    private static void AssertOriginal(JsonObject request, int threads)
    {
        Assert.Equal("upload", Command(request));
        Assert.Equal("original", request["quality"]!.GetValue<string>());
        Assert.Equal(threads, request["threads"]!.GetValue<int>());
        Assert.Equal(UploadKeys, request.Select(pair => pair.Key).Order(StringComparer.Ordinal));
        foreach (var item in Items(request))
            Assert.Equal(ItemKeys, item.Select(pair => pair.Key).Order(StringComparer.Ordinal));
        var text = request.ToJsonString();
        foreach (var key in new[] { "saver", "use_quota", "storage", "force" })
            Assert.DoesNotContain("\"" + key, text, StringComparison.Ordinal);
    }

    private static string Credential(string email) => $"Email={Uri.EscapeDataString(email)}&Token=fixture-token&androidId=1234567890abcdef";
    private static string Command(JsonObject request) => request["command"]!.GetValue<string>();
    private static List<JsonObject> Items(JsonObject request) => request["items"]!.AsArray().Select(node => node!.AsObject()).ToList();
    private static void Auth(JsonObject request, Action<JsonObject> emit) => emit(new JsonObject
    {
        ["type"] = "auth", ["email"] = GoogleSignIn.Email(request["auth_data"]!.GetValue<string>())
    });
    private static void Confirm(JsonObject item, Action<JsonObject> emit) => emit(new JsonObject
    {
        ["type"] = "item", ["id"] = item["id"]!.GetValue<string>(), ["media_key"] = "key-" + item["id"]!.GetValue<string>(),
        ["status"] = "uploaded"
    });

    /// <summary>A bridge that is already running, as a serve session is after the run's check-auth.</summary>
    private sealed class SessionBridge(Func<JsonObject, Action<JsonObject>, int> run) : IBridgeClient
    {
        public bool LastRequestStartedBridge => false;
        public Task<int> ExecuteAsync(JsonObject request, Action<JsonObject> onEvent, CancellationToken cancellationToken) =>
            Task.FromResult(run(request, onEvent));
    }

    private sealed class TempFolder : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "photos-parallel-" + Guid.NewGuid().ToString("N"));
        public string State => Path.Combine(Root, "state");
        public TempFolder() => Directory.CreateDirectory(Root);
        public void Dispose() => Directory.Delete(Root, recursive: true);
    }
}
