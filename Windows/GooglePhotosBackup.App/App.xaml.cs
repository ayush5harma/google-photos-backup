using System.Text.Json;
using Microsoft.UI.Xaml;

namespace GooglePhotosBackup.App;

public partial class App : Application
{
    private Window? _window;
    private FileStream? _instanceLock;

    public App()
    {
        InitializeComponent();
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var arguments = Environment.GetCommandLineArgs();
        var smokeIndex = Array.IndexOf(arguments, "--smoke-test");
        if (smokeIndex >= 0)
        {
            try
            {
                // 2026-10-15: The CI launch check constructs real XAML without reading credentials or reaching Google.
                var window = new MainWindow(smokeTest: true);
                _window = window;
                window.Activate();
                await window.WhenLoadedAsync();
                await Task.Delay(100);
                var tempRoot = Path.Combine(Path.GetTempPath(), "GooglePhotosBackupSmoke-" + Guid.NewGuid().ToString("N"));
                bool encryptedCredentialRoundTrip;
                try
                {
                    var testStore = new LocalStore(tempRoot);
                    testStore.SaveCredential("fixture-only-credential");
                    encryptedCredentialRoundTrip = testStore.LoadCredential() == "fixture-only-credential";
                }
                finally
                {
                    if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
                }
                if (!encryptedCredentialRoundTrip) throw new InvalidOperationException("DPAPI fixture roundtrip failed.");
                var screenshotIndex = Array.IndexOf(arguments, "--screenshot");
                if (screenshotIndex >= 0 && screenshotIndex + 1 < arguments.Length)
                    await window.SaveScreenshotAsync(arguments[screenshotIndex + 1]);
                if (smokeIndex + 1 < arguments.Length && !arguments[smokeIndex + 1].StartsWith("--", StringComparison.Ordinal))
                {
                    var reportPath = arguments[smokeIndex + 1];
                    Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(reportPath))!);
                    File.WriteAllText(reportPath, JsonSerializer.Serialize(new { status = "ok", encryptedCredentialRoundTrip }));
                }
                Environment.Exit(0);
            }
            catch (Exception) { Environment.Exit(1); }
            return;
        }

        try
        {
            var root = new LocalStore().Root;
            Directory.CreateDirectory(root);
            // 2026-10-15: An exclusive per-user file prevents separate app processes from racing state writes.
            _instanceLock = new FileStream(Path.Combine(root, "instance.lock"), FileMode.OpenOrCreate,
                FileAccess.ReadWrite, FileShare.None);
        }
        catch (IOException) { Environment.Exit(1); return; }
        catch (UnauthorizedAccessException) { Environment.Exit(1); return; }
        _window = new MainWindow();
        _window.Activate();
    }
}
