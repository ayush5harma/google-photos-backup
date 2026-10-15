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
            var reportPath = smokeIndex + 1 < arguments.Length && !arguments[smokeIndex + 1].StartsWith("--", StringComparison.Ordinal)
                ? arguments[smokeIndex + 1] : null;
            var stage = "construct-window";
            try
            {
                // 2026-10-15: The CI launch check constructs real XAML without reading credentials or reaching Google.
                var window = new MainWindow(smokeTest: true);
                _window = window;
                window.Activate();
                stage = "load-window";
                await window.WhenLoadedAsync();
                await Task.Delay(100);
                stage = "icloud-page";
                var icloudPageRendered = window.ValidateICloudSmokePage();
                if (!icloudPageRendered) throw new InvalidOperationException("The iCloud page did not render its sign-in controls.");
                stage = "dpapi-roundtrip";
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
                string? lightIconSource = null;
                string? darkIconSource = null;
                if (screenshotIndex >= 0 && screenshotIndex + 1 < arguments.Length)
                {
                    stage = "capture-theme-screenshots";
                    (lightIconSource, darkIconSource) = await window.SaveThemeScreenshotsAsync(arguments[screenshotIndex + 1]);
                }
                stage = "navigation-collapse-reopen";
                var collapsedScreenshot = screenshotIndex >= 0 && screenshotIndex + 1 < arguments.Length
                    ? Path.Combine(Path.GetDirectoryName(Path.GetFullPath(arguments[screenshotIndex + 1]))!, "ui-smoke-collapsed.png")
                    : null;
                var (navigationCollapsed, navigationReopened) = await window.ValidateNavigationPaneAsync(collapsedScreenshot);
                if (reportPath is not null)
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(reportPath))!);
                    File.WriteAllText(reportPath, JsonSerializer.Serialize(new
                    {
                        status = "ok", encryptedCredentialRoundTrip, icloudPageRendered, lightIconSource, darkIconSource,
                        navigationCollapsed, navigationReopened, collapsedScreenshot
                    }));
                }
                Environment.Exit(0);
            }
            catch (Exception error)
            {
                // 2026-10-15: This path uses fixture data only; CI can report XAML failure details without user credentials.
                if (reportPath is not null)
                {
                    try
                    {
                        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(reportPath))!);
                        File.WriteAllText(reportPath, JsonSerializer.Serialize(new
                        {
                            status = "failed", stage, errorType = error.GetType().Name,
                            hResult = $"0x{error.HResult:X8}", message = error.Message,
                            innerType = error.InnerException?.GetType().Name,
                            innerMessage = error.InnerException?.Message,
                            stack = error.ToString()[..Math.Min(error.ToString().Length, 8000)]
                        }));
                    }
                    catch (Exception) { }
                }
                Environment.Exit(1);
            }
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
