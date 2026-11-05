using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using GooglePhotosBackup.Core;

namespace GooglePhotosBackup.App;

internal sealed class AppPreferences
{
    public List<string> Folders { get; set; } = [];
    public string Quality { get; set; } = "original";
    public bool MirrorFolders { get; set; } = true;
    /// <summary>The parallel uploads Manual uses. Settings before issue #58 saved 2 here without showing it;
    /// that only matters once automatic is turned off.</summary>
    public int Threads { get; set; } = UploadParallelism.Initial;
    /// <summary>Absent from settings saved before issue #58, so those users get automatic.</summary>
    public bool ThreadsAutomatic { get; set; } = true;
    public int BatchSize { get; set; } = BackupOptions.DefaultBatchSize;
    public string? ICloudAccount { get; set; }

    /// <summary>A hand-edited or older settings file cannot start a run the coordinator would refuse.</summary>
    public AppPreferences Normalized()
    {
        Threads = Math.Clamp(Threads, 1, UploadParallelism.MaximumThreads);
        BatchSize = Math.Clamp(BatchSize, BackupOptions.MinimumChosenBatchSize, BackupOptions.MaximumBatchSize);
        return this;
    }
}

internal sealed record RunRecord(DateTimeOffset Started, int Uploaded, int Existing, int Failed, bool Canceled);

internal sealed class LocalStore
{
    public LocalStore(string? root = null)
    {
        Root = root ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GooglePhotosBackup");
    }

    public string Root { get; }

    public string StateDirectory => Path.Combine(Root, "State");
    public string DeviceStagingDirectory => Path.Combine(Root, "Device staging");

    private string PreferencesFile => Path.Combine(Root, "settings.json");
    private string HistoryFile => Path.Combine(Root, "history.json");
    private string CredentialFile => Path.Combine(Root, "credential.bin");

    public AppPreferences LoadPreferences()
    {
        try
        {
            return (JsonSerializer.Deserialize<AppPreferences>(File.ReadAllText(PreferencesFile)) ?? new AppPreferences()).Normalized();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            return new AppPreferences();
        }
    }

    public void SavePreferences(AppPreferences preferences)
    {
        Directory.CreateDirectory(Root);
        WriteAtomically(PreferencesFile, JsonSerializer.Serialize(preferences));
    }

    public List<RunRecord> LoadHistory()
    {
        try
        {
            return JsonSerializer.Deserialize<List<RunRecord>>(File.ReadAllText(HistoryFile)) ?? [];
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            return [];
        }
    }

    public void SaveHistory(IEnumerable<RunRecord> history)
    {
        Directory.CreateDirectory(Root);
        WriteAtomically(HistoryFile, JsonSerializer.Serialize(history.Take(40)));
    }

    public string? LoadCredential()
    {
        try
        {
            var encrypted = File.ReadAllBytes(CredentialFile);
            var clear = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
            try { return Encoding.UTF8.GetString(clear); }
            finally { CryptographicOperations.ZeroMemory(clear); }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException)
        {
            return null;
        }
    }

    public void SaveCredential(string credential)
    {
        Directory.CreateDirectory(Root);
        var clear = Encoding.UTF8.GetBytes(credential);
        try
        {
            var encrypted = ProtectedData.Protect(clear, null, DataProtectionScope.CurrentUser);
            var temporary = CredentialFile + ".tmp";
            File.WriteAllBytes(temporary, encrypted);
            File.Move(temporary, CredentialFile, true);
        }
        finally { CryptographicOperations.ZeroMemory(clear); }
    }

    public void ClearCredential()
    {
        if (File.Exists(CredentialFile)) File.Delete(CredentialFile);
    }

    private static void WriteAtomically(string path, string contents)
    {
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, contents);
        File.Move(temporary, path, true);
    }
}
