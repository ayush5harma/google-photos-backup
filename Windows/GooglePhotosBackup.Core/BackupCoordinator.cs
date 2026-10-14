using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace GooglePhotosBackup.Core;

public sealed class BackupCoordinator(IBridgeClient bridge, string stateDirectory)
{
    private static readonly HashSet<string> MediaExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".webp", ".tif", ".tiff", ".bmp", ".avif",
        ".mp4", ".mov", ".m4v", ".avi", ".mkv", ".3gp"
    };
    private static readonly StringComparer PathComparer = OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
    private readonly object _gate = new();
    private CancellationTokenSource? _runCancellation;
    private TaskCompletionSource? _resume;
    private int _running;

    public event Action<BackupProgress>? ProgressChanged;

    public void Pause()
    {
        lock (_gate) _resume ??= new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    public void Resume()
    {
        TaskCompletionSource? resume;
        lock (_gate) { resume = _resume; _resume = null; }
        resume?.TrySetResult();
    }

    public void Stop()
    {
        lock (_gate) _runCancellation?.Cancel();
        Resume();
    }

    public async Task<bool> CheckAuthAsync(string authData, CancellationToken ct)
    {
        return await VerifiedEmailAsync(authData, ct) is not null;
    }

    private async Task<string?> VerifiedEmailAsync(string authData, CancellationToken ct)
    {
        string? verified = null;
        var request = new JsonObject { ["command"] = "check-auth", ["auth_data"] = authData };
        var code = await ExecuteBridgeAsync(request, message =>
        {
            if (Text(message, "type") == "auth") verified = Text(message, "email");
        }, ct).ConfigureAwait(false);
        return code == 0 && verified is not null ? GoogleSignIn.CanonicalEmail(verified) : null;
    }

    public async Task<BackupSummary> RunAsync(BackupOptions options, string authData, CancellationToken ct)
    {
        if (Interlocked.CompareExchange(ref _running, 1, 0) != 0)
            throw new InvalidOperationException("A backup is already running.");
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
        lock (_gate) _runCancellation = linked;
        var uploaded = 0;
        var existing = 0;
        var failed = 0;
        try
        {
            Validate(options, authData);
            var account = await VerifiedEmailAsync(authData, linked.Token).ConfigureAwait(false);
            if (account is null || account != GoogleSignIn.CanonicalEmail(GoogleSignIn.Email(authData)!))
                throw new InvalidOperationException("Google sign-in needs attention.");
            var accountKey = Digest(Encoding.UTF8.GetBytes(account));
            using var stateLock = AcquireAccountLock(accountKey);
            var statePath = Path.Combine(stateDirectory, "state-" + accountKey + ".json");
            var state = Load(statePath, accountKey);
            Emit(new BackupProgress("Scanning", 0, 0, 0));
            var candidates = await Task.Run(() => ScanAsync(options.Folders, linked.Token), linked.Token).ConfigureAwait(false);
            var todo = candidates.Where(item => !state.Files.TryGetValue(item.Key, out var record)
                || record.Fingerprint != item.Fingerprint || string.IsNullOrEmpty(record.MediaKey)).ToList();
            var completed = 0;
            Emit(new BackupProgress("Uploading", completed, todo.Count, failed));
            foreach (var batch in todo.Chunk(20))
            {
                await WaitWhilePausedAsync(linked.Token).ConfigureAwait(false);
                var remaining = batch.ToList();
                for (var attempt = 1; attempt <= 3 && remaining.Count > 0; attempt++)
                {
                    linked.Token.ThrowIfCancellationRequested();
                    var byId = remaining.ToDictionary(item => item.Key, StringComparer.Ordinal);
                    var confirmed = new HashSet<string>(StringComparer.Ordinal);
                    var retryable = new HashSet<string>(StringComparer.Ordinal);
                    var failedEvents = new HashSet<string>(StringComparer.Ordinal);
                    string? fatalKind = null;
                    var request = new JsonObject
                    {
                        ["command"] = "upload", ["auth_data"] = authData, ["quality"] = options.Quality, ["threads"] = options.Threads,
                        ["items"] = new JsonArray(remaining.Select(item => (JsonNode)new JsonObject
                        {
                            ["id"] = item.Key, ["path"] = item.Path, ["filename"] = Path.GetFileName(item.Path)
                        }).ToArray())
                    };
                    var code = await ExecuteBridgeAsync(request, message =>
                    {
                        var type = Text(message, "type");
                        var id = Text(message, "id");
                        if (type == "fatal") { fatalKind = Text(message, "kind"); return; }
                        if (id is null || !byId.TryGetValue(id, out var item)) return;
                        if (type == "progress")
                        {
                            Emit(new BackupProgress("Uploading", completed, todo.Count, failed, Path.GetFileName(item.Path)));
                        }
                        else if (type == "item" && !confirmed.Contains(id))
                        {
                            var mediaKey = Text(message, "media_key");
                            var status = Text(message, "status");
                            if (string.IsNullOrEmpty(mediaKey) || status is not ("uploaded" or "existing")) return;
                            if (state.Files.TryGetValue(id, out var prior) && prior.MediaKey != mediaKey)
                                foreach (var album in state.Albums.Values) album.Members.Remove(id);
                            state.Files[id] = new FileRecord { Fingerprint = item.Fingerprint, MediaKey = mediaKey };
                            Save(statePath, state);
                            confirmed.Add(id);
                            if (status == "existing") existing++; else uploaded++;
                            completed++;
                            Emit(new BackupProgress("Uploading", completed, todo.Count, failed, Path.GetFileName(item.Path)));
                        }
                        else if (type == "item_failed" && !confirmed.Contains(id))
                        {
                            failedEvents.Add(id);
                            if (Boolean(message, "retryable")) retryable.Add(id);
                        }
                    }, linked.Token).ConfigureAwait(false);
                    linked.Token.ThrowIfCancellationRequested();

                    if (fatalKind is "auth" or "request" or "internal" || code is 1 or 2 or 4)
                        throw new InvalidOperationException(fatalKind == "auth" ? "Google sign-in needs attention." : "The uploader stopped early.");
                    var next = new List<Candidate>();
                    foreach (var item in remaining)
                    {
                        if (confirmed.Contains(item.Key)) continue;
                        if (attempt < 3 && (retryable.Contains(item.Key) || (!failedEvents.Contains(item.Key) && code is 3 or 6)))
                            next.Add(item);
                        else
                        {
                            failed++;
                            completed++;
                            Emit(new BackupProgress("Uploading", completed, todo.Count, failed, Path.GetFileName(item.Path), "Upload failed; retry later."));
                        }
                    }
                    remaining = next;
                    if (remaining.Count > 0)
                    {
                        await WaitWhilePausedAsync(linked.Token).ConfigureAwait(false);
                        await Task.Delay(TimeSpan.FromSeconds(attempt), linked.Token).ConfigureAwait(false);
                    }
                }
            }
            if (options.MirrorFolders)
                failed += await MirrorAlbumsAsync(candidates, state, statePath, authData, linked.Token).ConfigureAwait(false);
            linked.Token.ThrowIfCancellationRequested();
            Emit(new BackupProgress("Completed", completed, todo.Count, failed));
            return new BackupSummary(uploaded, existing, failed, false);
        }
        catch (OperationCanceledException) when (linked.IsCancellationRequested)
        {
            Emit(new BackupProgress("Stopped", uploaded + existing + failed, 0, failed));
            return new BackupSummary(uploaded, existing, failed, true);
        }
        finally
        {
            lock (_gate) _runCancellation = null;
            Resume();
            Interlocked.Exchange(ref _running, 0);
        }
    }

    private async Task<int> MirrorAlbumsAsync(List<Candidate> candidates, PersistedState state, string statePath, string authData, CancellationToken ct)
    {
        var failed = 0;
        foreach (var root in candidates.SelectMany(item => item.Roots).Distinct(StringComparer.Ordinal))
        {
            await WaitWhilePausedAsync(ct).ConfigureAwait(false);
            var album = state.Albums.TryGetValue(root, out var saved) ? saved : new AlbumRecord();
            var pending = candidates.Where(item => item.Roots.Contains(root)
                && state.Files.TryGetValue(item.Key, out var file) && file.Fingerprint == item.Fingerprint
                && !string.IsNullOrEmpty(file.MediaKey) && !album.Members.Contains(item.Key)).ToList();
            foreach (var batch in pending.Chunk(100))
            {
                await WaitWhilePausedAsync(ct).ConfigureAwait(false);
                var request = new JsonObject
                {
                    ["command"] = "add-to-album", ["auth_data"] = authData,
                    ["media_keys"] = new JsonArray(batch.Select(item => (JsonNode?)JsonValue.Create(state.Files[item.Key].MediaKey)).ToArray()),
                    ["album"] = album.AlbumId is null
                        ? new JsonObject { ["name"] = batch[0].RootNames[root] }
                        : new JsonObject { ["id"] = album.AlbumId, ["name"] = batch[0].RootNames[root] }
                };
                var confirmed = false;
                var code = await ExecuteBridgeAsync(request, message =>
                {
                    if (Text(message, "type") != "album" || string.IsNullOrEmpty(Text(message, "album_id"))) return;
                    album.AlbumId = Text(message, "album_id");
                    foreach (var item in batch) album.Members.Add(item.Key);
                    state.Albums[root] = album;
                    Save(statePath, state);
                    confirmed = true;
                }, ct).ConfigureAwait(false);
                if (!confirmed || code != 0)
                {
                    // 2026-10-15: A missing album confirmation must remain a
                    // visible failure even when every media upload succeeded.
                    failed++;
                    Emit(new BackupProgress("Albums", 0, 0, failed, Message: "A folder album could not be updated; it will be retried."));
                }
            }
        }
        return failed;
    }

    private static async Task<List<Candidate>> ScanAsync(IReadOnlyList<string> roots, CancellationToken ct)
    {
        var found = new Dictionary<string, Candidate>(PathComparer);
        foreach (var input in roots)
        {
            ct.ThrowIfCancellationRequested();
            string root;
            try { root = CanonicalPath(input); }
            catch (Exception error) when (error is ArgumentException or PathTooLongException or NotSupportedException or IOException or System.Security.SecurityException)
            { throw ScanUnavailable(); }
            // 2026-10-15: Directory.Exists also returns false for access errors;
            // an empty scan must not report success for a selected folder.
            if (!Directory.Exists(root)) throw ScanUnavailable();
            if (IsReparse(root)) throw ScanUnavailable();
            var rootKey = Digest(Encoding.UTF8.GetBytes(OperatingSystem.IsWindows() ? root.ToUpperInvariant() : root));
            var rootName = Path.GetFileName(root);
            if (string.IsNullOrEmpty(rootName)) rootName = "Photos Backup";
            var folders = new Stack<string>();
            folders.Push(root);
            while (folders.TryPop(out var folder))
            {
                ct.ThrowIfCancellationRequested();
                IEnumerable<string> entries;
                try { entries = Directory.EnumerateFileSystemEntries(folder).ToArray(); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
                { throw ScanUnavailable(); }
                foreach (var entry in entries)
                {
                    ct.ThrowIfCancellationRequested();
                    FileAttributes attributes;
                    try { attributes = File.GetAttributes(entry); }
                    catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
                    { throw ScanUnavailable(); }
                    if ((attributes & FileAttributes.ReparsePoint) != 0) continue;
                    if ((attributes & FileAttributes.Directory) != 0) { folders.Push(entry); continue; }
                    if (!MediaExtensions.Contains(Path.GetExtension(entry))) continue;
                    string path;
                    try { path = CanonicalPath(entry); }
                    catch (Exception error) when (error is ArgumentException or PathTooLongException or NotSupportedException or IOException or System.Security.SecurityException)
                    { throw ScanUnavailable(); }
                    if (!found.TryGetValue(path, out var candidate))
                    {
                        string fingerprint;
                        try { fingerprint = await FingerprintAsync(path, ct).ConfigureAwait(false); }
                        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
                        { throw ScanUnavailable(); }
                        candidate = new Candidate(Digest(Encoding.UTF8.GetBytes(OperatingSystem.IsWindows() ? path.ToUpperInvariant() : path)), path, fingerprint);
                        found[path] = candidate;
                    }
                    candidate.Roots.Add(rootKey);
                    candidate.RootNames[rootKey] = rootName;
                }
            }
        }
        return found.Values.ToList();
    }

    private static async Task<string> FingerprintAsync(string path, CancellationToken ct)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 128 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        return Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, ct).ConfigureAwait(false));
    }

    private static string CanonicalPath(string path)
    {
        var full = Path.GetFullPath(path);
        return full == Path.GetPathRoot(full) ? full : full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }

    private static bool IsReparse(string path)
    {
        try { return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        { throw ScanUnavailable(); }
    }

    private static InvalidOperationException ScanUnavailable() =>
        new("A selected folder or media file could not be read. Check that it exists and you have access, then retry.");

    private static void Validate(BackupOptions options, string authData)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (options.Folders is null || options.Folders.Count == 0) throw new ArgumentException("Choose a folder to back up.", nameof(options));
        if (options.Quality is not ("original" or "saver" or "quota")) throw new ArgumentException("Choose a supported upload quality.", nameof(options));
        if (options.Threads is < 1 or > 8) throw new ArgumentException("Threads must be between 1 and 8.", nameof(options));
        if (string.IsNullOrWhiteSpace(authData) || GoogleSignIn.Email(authData) is null)
            throw new InvalidOperationException("Sign in with Google before backing up.");
    }

    private static PersistedState Load(string path, string accountKey)
    {
        if (!File.Exists(path)) return new PersistedState { AccountKey = accountKey };
        try
        {
            var state = JsonSerializer.Deserialize<PersistedState>(File.ReadAllText(path));
            if (state is null || state.AccountKey != accountKey || state.Files is null || state.Albums is null
                || state.Files.Values.Any(file => file is null || file.Fingerprint is null || file.MediaKey is null)
                || state.Albums.Values.Any(album => album is null || album.Members is null))
                throw new InvalidDataException();
            return state;
        }
        catch (Exception error) when (error is JsonException or IOException or InvalidDataException or UnauthorizedAccessException)
        {
            throw new InvalidOperationException("Backup history could not be read; it was left unchanged.");
        }
    }

    private FileStream AcquireAccountLock(string accountKey)
    {
        try
        {
            Directory.CreateDirectory(stateDirectory);
            // 2026-10-15: A second process must not plan from stale state
            // while this run is receiving Google confirmations.
            return new FileStream(Path.Combine(stateDirectory, "state-" + accountKey + ".lock"),
                FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new InvalidOperationException("Backup state is busy or unavailable.");
        }
    }

    private static void Save(string path, PersistedState state)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(file, state);
                file.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            throw new InvalidOperationException("Backup history could not be saved.");
        }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    private async Task WaitWhilePausedAsync(CancellationToken ct)
    {
        Task? waiting;
        lock (_gate) waiting = _resume?.Task;
        if (waiting is not null) await waiting.WaitAsync(ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
    }

    private void Emit(BackupProgress progress)
    {
        if (ProgressChanged is not { } handlers) return;
        foreach (Action<BackupProgress> handler in handlers.GetInvocationList())
        {
            try { handler(progress); }
            catch { /* 2026-10-15: A view observer must not turn confirmed uploads into failures. */ }
        }
    }

    private static string? Text(JsonObject item, string key) =>
        item[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
    private static bool Boolean(JsonObject item, string key) =>
        item[key] is JsonValue value && value.TryGetValue<bool>(out var result) && result;

    private async Task<int> ExecuteBridgeAsync(JsonObject request, Action<JsonObject> onEvent, CancellationToken ct)
    {
        try { return await bridge.ExecuteAsync(request, onEvent, ct).ConfigureAwait(false); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception) { throw new InvalidOperationException("The uploader could not complete."); }
    }
    private static string Digest(byte[] input) => Convert.ToHexStringLower(SHA256.HashData(input));

    private sealed class Candidate(string key, string path, string fingerprint)
    {
        public string Key { get; } = key;
        public string Path { get; } = path;
        public string Fingerprint { get; } = fingerprint;
        public HashSet<string> Roots { get; } = new(StringComparer.Ordinal);
        public Dictionary<string, string> RootNames { get; } = new(StringComparer.Ordinal);
    }

    private sealed class PersistedState
    {
        public PersistedState() { }
        public string AccountKey { get; set; } = "";
        public Dictionary<string, FileRecord> Files { get; set; } = new(StringComparer.Ordinal);
        public Dictionary<string, AlbumRecord> Albums { get; set; } = new(StringComparer.Ordinal);
    }

    private sealed class FileRecord
    {
        public FileRecord() { }
        public string Fingerprint { get; set; } = "";
        public string MediaKey { get; set; } = "";
    }

    private sealed class AlbumRecord
    {
        public AlbumRecord() { }
        public string? AlbumId { get; set; }
        public HashSet<string> Members { get; set; } = new(StringComparer.Ordinal);
    }
}
