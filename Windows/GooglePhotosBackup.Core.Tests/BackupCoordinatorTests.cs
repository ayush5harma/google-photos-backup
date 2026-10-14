using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using GooglePhotosBackup.Core;
using Xunit;

namespace GooglePhotosBackup.Core.Tests;

public sealed class BackupCoordinatorTests
{
    [Fact]
    public async Task OverlappingFoldersResumeEditsAndIsolateAccounts()
    {
        using var fixture = new TempFolder();
        var nested = Directory.CreateDirectory(Path.Combine(fixture.Root, "nested")).FullName;
        File.WriteAllText(Path.Combine(fixture.Root, "one.jpg"), "first");
        var edited = Path.Combine(nested, "two.mp4");
        File.WriteAllText(edited, "second");
        var uploads = new List<int>();
        var bridge = new FakeBridge((request, emit, _) =>
        {
            if (Command(request) == "check-auth") { Auth(request, emit); return Task.FromResult(0); }
            var items = Items(request);
            uploads.Add(items.Count);
            foreach (var item in items) Confirm(item, emit);
            return Task.FromResult(0);
        });
        var coordinator = new BackupCoordinator(bridge, fixture.State);
        var options = new BackupOptions([fixture.Root, nested], MirrorFolders: false);
        var first = await coordinator.RunAsync(options, Credential("first@example.com"), CancellationToken.None);
        Assert.Equal(2, first.Uploaded);
        Assert.Equal([2], uploads);
        Assert.Equal(0, (await coordinator.RunAsync(options, Credential("first@example.com"), CancellationToken.None)).Uploaded);
        Assert.Equal([2], uploads);

        File.WriteAllText(edited, "new content");
        Assert.Equal(1, (await coordinator.RunAsync(options, Credential("first@example.com"), CancellationToken.None)).Uploaded);
        Assert.Equal([2, 1], uploads);
        Assert.Equal(2, (await coordinator.RunAsync(options, Credential("second@example.com"), CancellationToken.None)).Uploaded);
        Assert.Equal([2, 1, 2], uploads);
        Assert.Equal(2, Directory.GetFiles(fixture.State, "state-*.json").Length);
        foreach (var state in Directory.GetFiles(fixture.State, "state-*.json"))
        {
            var contents = File.ReadAllText(state);
            Assert.DoesNotContain("Token", contents, StringComparison.Ordinal);
            Assert.DoesNotContain("first@example.com", contents, StringComparison.Ordinal);
            Assert.DoesNotContain(fixture.Root, contents, StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task OnlyConfirmedItemsPersistAndFailedItemsRetryOnTheNextRun()
    {
        using var fixture = new TempFolder();
        File.WriteAllText(Path.Combine(fixture.Root, "a.jpg"), "a");
        File.WriteAllText(Path.Combine(fixture.Root, "b.heic"), "b");
        var calls = 0;
        var bridge = new FakeBridge((request, emit, _) =>
        {
            if (Command(request) == "check-auth") { Auth(request, emit); return Task.FromResult(0); }
            var items = Items(request);
            calls++;
            if (calls == 1)
            {
                Confirm(items[0], emit);
                emit(new JsonObject { ["type"] = "item_failed", ["id"] = items[1]["id"]!.GetValue<string>(),
                    ["message"] = "private path and token", ["retryable"] = false });
            }
            else Assert.Single(items);
            if (calls > 1) Confirm(items[0], emit);
            return Task.FromResult(0);
        });
        var coordinator = new BackupCoordinator(bridge, fixture.State);
        var options = new BackupOptions([fixture.Root], MirrorFolders: false);
        var first = await coordinator.RunAsync(options, Credential("one@example.com"), CancellationToken.None);
        Assert.Equal(new BackupSummary(1, 0, 1, false), first);
        var second = await coordinator.RunAsync(options, Credential("one@example.com"), CancellationToken.None);
        Assert.Equal(new BackupSummary(1, 0, 0, false), second);
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task RetryableFailureGetsAnotherAttemptButNeverBecomesSuccessFromDoneCounts()
    {
        using var fixture = new TempFolder();
        File.WriteAllText(Path.Combine(fixture.Root, "a.webp"), "a");
        var calls = 0;
        var bridge = new FakeBridge((request, emit, _) =>
        {
            if (Command(request) == "check-auth") { Auth(request, emit); return Task.FromResult(0); }
            calls++;
            var item = Assert.Single(Items(request));
            if (calls == 1)
                emit(new JsonObject { ["type"] = "item_failed", ["id"] = item["id"]!.GetValue<string>(), ["retryable"] = true });
            else Confirm(item, emit);
            emit(new JsonObject { ["type"] = "done", ["uploaded"] = 99, ["existing"] = 99, ["failed"] = 0 });
            return Task.FromResult(0);
        });
        var result = await new BackupCoordinator(bridge, fixture.State).RunAsync(
            new BackupOptions([fixture.Root], MirrorFolders: false), Credential("one@example.com"), CancellationToken.None);
        Assert.Equal(new BackupSummary(1, 0, 0, false), result);
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task DoneCountsWithoutItemConfirmationNeverRecordSuccess()
    {
        using var fixture = new TempFolder();
        File.WriteAllText(Path.Combine(fixture.Root, "a.jpeg"), "a");
        var calls = 0;
        var bridge = new FakeBridge((request, emit, _) =>
        {
            if (Command(request) == "check-auth") Auth(request, emit);
            else
            {
                calls++;
                emit(new JsonObject { ["type"] = "done", ["uploaded"] = 1, ["existing"] = 0, ["failed"] = 0 });
            }
            return Task.FromResult(0);
        });
        var coordinator = new BackupCoordinator(bridge, fixture.State);
        var options = new BackupOptions([fixture.Root], MirrorFolders: false);
        Assert.Equal(new BackupSummary(0, 0, 1, false),
            await coordinator.RunAsync(options, Credential("one@example.com"), CancellationToken.None));
        await coordinator.RunAsync(options, Credential("one@example.com"), CancellationToken.None);
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task ScansEverySupportedMediaExtensionAndSkipsOtherFiles()
    {
        using var fixture = new TempFolder();
        string[] extensions = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "avif",
            "mp4", "mov", "m4v", "avi", "mkv", "3gp"];
        foreach (var extension in extensions) File.WriteAllText(Path.Combine(fixture.Root, "media." + extension), extension);
        File.WriteAllText(Path.Combine(fixture.Root, "notes.txt"), "not media");
        var uploaded = 0;
        var bridge = new FakeBridge((request, emit, _) =>
        {
            if (Command(request) == "check-auth") Auth(request, emit);
            else foreach (var item in Items(request)) { uploaded++; Confirm(item, emit); }
            return Task.FromResult(0);
        });
        var result = await new BackupCoordinator(bridge, fixture.State).RunAsync(
            new BackupOptions([fixture.Root], MirrorFolders: false), Credential("one@example.com"), CancellationToken.None);
        Assert.Equal(extensions.Length, uploaded);
        Assert.Equal(extensions.Length, result.Uploaded);
    }

    [Fact]
    public async Task FolderAlbumsAreAddedOnlyAfterConfirmationAndRemembered()
    {
        using var fixture = new TempFolder();
        var nested = Directory.CreateDirectory(Path.Combine(fixture.Root, "nested")).FullName;
        File.WriteAllText(Path.Combine(nested, "a.mov"), "a");
        var albumCalls = 0;
        var bridge = new FakeBridge((request, emit, _) =>
        {
            switch (Command(request))
            {
                case "check-auth": Auth(request, emit); break;
                case "upload": foreach (var item in Items(request)) Confirm(item, emit); break;
                case "add-to-album":
                    albumCalls++;
                    emit(new JsonObject { ["type"] = "album", ["album_id"] = "album-" + albumCalls });
                    break;
            }
            return Task.FromResult(0);
        });
        var coordinator = new BackupCoordinator(bridge, fixture.State);
        var options = new BackupOptions([fixture.Root, nested]);
        Assert.Equal(1, (await coordinator.RunAsync(options, Credential("one@example.com"), CancellationToken.None)).Uploaded);
        Assert.Equal(2, albumCalls);
        await coordinator.RunAsync(options, Credential("one@example.com"), CancellationToken.None);
        Assert.Equal(2, albumCalls);
    }

    [Fact]
    public async Task AlbumFailureDoesNotEraseConfirmedUploadAndIsRetried()
    {
        using var fixture = new TempFolder();
        File.WriteAllText(Path.Combine(fixture.Root, "a.png"), "a");
        var uploads = 0;
        var albums = 0;
        var bridge = new FakeBridge((request, emit, _) =>
        {
            switch (Command(request))
            {
                case "check-auth": Auth(request, emit); break;
                case "upload": uploads++; Confirm(Assert.Single(Items(request)), emit); break;
                case "add-to-album":
                    albums++;
                    if (albums == 2) emit(new JsonObject { ["type"] = "album", ["album_id"] = "album-1" });
                    else emit(new JsonObject { ["type"] = "album_failed", ["message"] = "private folder path" });
                    break;
            }
            return Task.FromResult(0);
        });
        var coordinator = new BackupCoordinator(bridge, fixture.State);
        var options = new BackupOptions([fixture.Root]);
        Assert.Equal(1, (await coordinator.RunAsync(options, Credential("one@example.com"), CancellationToken.None)).Uploaded);
        Assert.Equal(0, (await coordinator.RunAsync(options, Credential("one@example.com"), CancellationToken.None)).Uploaded);
        Assert.Equal(1, uploads);
        Assert.Equal(2, albums);
    }

    [Fact]
    public async Task BridgeAccountMismatchCannotUseAnotherAccountsHistory()
    {
        using var fixture = new TempFolder();
        File.WriteAllText(Path.Combine(fixture.Root, "a.jpg"), "a");
        var bridge = new FakeBridge((request, emit, _) =>
        {
            Assert.Equal("check-auth", Command(request));
            emit(new JsonObject { ["type"] = "auth", ["email"] = "other@example.com" });
            return Task.FromResult(0);
        });
        var coordinator = new BackupCoordinator(bridge, fixture.State);
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.RunAsync(
            new BackupOptions([fixture.Root]), Credential("one@example.com"), CancellationToken.None));
        Assert.Equal("Google sign-in needs attention.", error.Message);
        Assert.False(Directory.Exists(fixture.State));
    }

    [Fact]
    public async Task GmailAliasesShareOneAccountHistory()
    {
        using var fixture = new TempFolder();
        File.WriteAllText(Path.Combine(fixture.Root, "a.bmp"), "a");
        var uploads = 0;
        var bridge = new FakeBridge((request, emit, _) =>
        {
            if (Command(request) == "check-auth") Auth(request, emit);
            else { uploads++; Confirm(Assert.Single(Items(request)), emit); }
            return Task.FromResult(0);
        });
        var coordinator = new BackupCoordinator(bridge, fixture.State);
        var options = new BackupOptions([fixture.Root], MirrorFolders: false);
        await coordinator.RunAsync(options, Credential("person.name@gmail.com"), CancellationToken.None);
        await coordinator.RunAsync(options, Credential("personname@googlemail.com"), CancellationToken.None);
        Assert.Equal(1, uploads);
        Assert.Single(Directory.GetFiles(fixture.State, "state-*.json"));
    }

    [Fact]
    public async Task ReparsePointsAreSkipped()
    {
        using var fixture = new TempFolder();
        var outside = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "photos-outside-" + Guid.NewGuid().ToString("N"))).FullName;
        try
        {
            File.WriteAllText(Path.Combine(outside, "private.jpg"), "outside");
            try { Directory.CreateSymbolicLink(Path.Combine(fixture.Root, "linked"), outside); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or PlatformNotSupportedException) { return; }
            var uploads = 0;
            var bridge = new FakeBridge((request, emit, _) =>
            {
                if (Command(request) == "check-auth") Auth(request, emit);
                else uploads += Items(request).Count;
                return Task.FromResult(0);
            });
            var result = await new BackupCoordinator(bridge, fixture.State).RunAsync(
                new BackupOptions([fixture.Root], MirrorFolders: false), Credential("one@example.com"), CancellationToken.None);
            Assert.Equal(0, uploads);
            Assert.Equal(0, result.Uploaded);
        }
        finally { Directory.Delete(outside, recursive: true); }
    }

    [Fact]
    public async Task PauseHoldsBeforeUploadAndStopCancelsTheRun()
    {
        using var fixture = new TempFolder();
        File.WriteAllText(Path.Combine(fixture.Root, "a.avif"), "a");
        var checkedAuth = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var uploads = 0;
        var bridge = new FakeBridge((request, emit, _) =>
        {
            if (Command(request) == "check-auth") { Auth(request, emit); checkedAuth.TrySetResult(); }
            else uploads++;
            return Task.FromResult(0);
        });
        var coordinator = new BackupCoordinator(bridge, fixture.State);
        coordinator.Pause();
        var run = coordinator.RunAsync(new BackupOptions([fixture.Root], MirrorFolders: false), Credential("one@example.com"), CancellationToken.None);
        await checkedAuth.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(0, uploads);
        coordinator.Stop();
        Assert.True((await run).Canceled);
        Assert.Equal(0, uploads);
    }

    [Fact]
    public async Task ResumeContinuesAQueuedBatch()
    {
        using var fixture = new TempFolder();
        File.WriteAllText(Path.Combine(fixture.Root, "a.tiff"), "a");
        var checkedAuth = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var uploads = 0;
        var bridge = new FakeBridge((request, emit, _) =>
        {
            if (Command(request) == "check-auth") { Auth(request, emit); checkedAuth.TrySetResult(); }
            else { uploads++; Confirm(Assert.Single(Items(request)), emit); }
            return Task.FromResult(0);
        });
        var coordinator = new BackupCoordinator(bridge, fixture.State);
        coordinator.Pause();
        var run = coordinator.RunAsync(new BackupOptions([fixture.Root], MirrorFolders: false), Credential("one@example.com"), CancellationToken.None);
        await checkedAuth.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(0, uploads);
        coordinator.Resume();
        Assert.Equal(1, (await run).Uploaded);
        Assert.Equal(1, uploads);
    }

    [Fact]
    public async Task TwoCoordinatorInstancesCannotWriteOneAccountsStateConcurrently()
    {
        using var fixture = new TempFolder();
        File.WriteAllText(Path.Combine(fixture.Root, "a.gif"), "a");
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var bridge = new FakeBridge(async (request, emit, ct) =>
        {
            if (Command(request) == "check-auth") { Auth(request, emit); return 0; }
            entered.TrySetResult();
            await release.Task.WaitAsync(ct);
            Confirm(Assert.Single(Items(request)), emit);
            return 0;
        });
        var first = new BackupCoordinator(bridge, fixture.State);
        var second = new BackupCoordinator(bridge, fixture.State);
        var options = new BackupOptions([fixture.Root], MirrorFolders: false);
        var firstRun = first.RunAsync(options, Credential("one@example.com"), CancellationToken.None);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            second.RunAsync(options, Credential("one@example.com"), CancellationToken.None));
        Assert.Equal("Backup state is busy or unavailable.", error.Message);
        release.TrySetResult();
        Assert.Equal(1, (await firstRun).Uploaded);
    }

    [Fact]
    public async Task SignInExchangeUsesMacFormAndReturnsCredential()
    {
        string? posted = null;
        using var http = new HttpClient(new Handler(async request =>
        {
            Assert.Equal("https://android.clients.google.com/auth", request.RequestUri!.ToString());
            posted = await request.Content!.ReadAsStringAsync();
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("Email=person@gmail.com\nToken=master-token\n") };
        }));
        var credential = await GoogleSignIn.ExchangeAsync("oauth_token=oauth2_4/example-token", http, CancellationToken.None);
        Assert.Equal("person@gmail.com", GoogleSignIn.Email(credential));
        Assert.Contains("client_sig=38918a453d07199354f8b19af05ec6562ced5788", posted, StringComparison.Ordinal);
        Assert.Contains("Token=oauth2_4%2Fexample-token", posted, StringComparison.Ordinal);
        Assert.Contains("app=com.google.android.apps.photos", credential, StringComparison.Ordinal);
        Assert.Contains("Token=master-token", credential, StringComparison.Ordinal);
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

    private sealed class FakeBridge(Func<JsonObject, Action<JsonObject>, CancellationToken, Task<int>> run) : IBridgeClient
    {
        public Task<int> ExecuteAsync(JsonObject request, Action<JsonObject> onEvent, CancellationToken cancellationToken) => run(request, onEvent, cancellationToken);
    }

    private sealed class TempFolder : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "photos-core-" + Guid.NewGuid().ToString("N"));
        public string State => Path.Combine(Root, "state");
        public TempFolder() => Directory.CreateDirectory(Root);
        public void Dispose() => Directory.Delete(Root, recursive: true);
    }

    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => send(request);
    }
}
