using GooglePhotosBackup.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Windows.Graphics;

namespace GooglePhotosBackup.App;

public sealed partial class SignInWindow : Window
{
    private readonly Func<string, Task> _connect;
    private readonly string _profile;
    private readonly DispatcherTimer _cookieTimer = new() { Interval = TimeSpan.FromSeconds(1.5) };
    private bool _checking;
    private bool _browserStarted;

    public SignInWindow(Func<string, Task> connect)
    {
        _connect = connect;
        _profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "GooglePhotosBackup", "AuthProfiles", Guid.NewGuid().ToString("N"));
        InitializeComponent();
        AppWindow.Resize(new SizeInt32(840, 780));
        _cookieTimer.Tick += CheckCookie;
        Closed += async (_, _) =>
        {
            _cookieTimer.Stop();
            try
            {
                if (Browser.CoreWebView2 is { } core)
                {
                    core.CookieManager.DeleteAllCookies();
                    await core.Profile.ClearBrowsingDataAsync();
                }
            }
            catch (Exception) { }
            try { Browser.Close(); }
            catch (Exception) { }
            // 2026-10-15: WebView2 releases profile files after its control closes, so retry cleanup briefly.
            for (var attempt = 0; attempt < 5 && Directory.Exists(_profile); attempt++)
            {
                try { Directory.Delete(_profile, recursive: true); }
                catch (IOException) { await Task.Delay(200); }
                catch (UnauthorizedAccessException) { await Task.Delay(200); }
            }
        };
        Browser.Loaded += (_, _) => _ = StartBrowserAsync();
    }

    private async Task StartBrowserAsync()
    {
        if (_browserStarted) return;
        _browserStarted = true;
        try
        {
            // 2026-10-15: A unique WebView2 profile keeps Google cookies out of the app's normal browser state.
            var environment = await CoreWebView2Environment.CreateWithOptionsAsync(null, _profile, null);
            await Browser.EnsureCoreWebView2Async(environment);
            Browser.Source = new Uri(GoogleSignIn.EmbeddedSetupUrl);
            _cookieTimer.Start();
        }
        catch (Exception)
        {
            ShowError("Google's sign-in page could not open. You can use the advanced credential option in Settings.");
        }
    }

    private async void CheckCookie(object? sender, object args)
    {
        if (_checking || Browser.CoreWebView2 is null) return;
        _checking = true;
        try
        {
            var cookies = await Browser.CoreWebView2.CookieManager.GetCookiesAsync(GoogleSignIn.EmbeddedSetupUrl);
            var token = cookies.FirstOrDefault(cookie => cookie.Name == "oauth_token")?.Value;
            if (string.IsNullOrWhiteSpace(token)) return;
            _cookieTimer.Stop();
            try
            {
                await _connect(token);
                Browser.CoreWebView2?.CookieManager.DeleteAllCookies();
                Close();
            }
            catch (Exception)
            {
                try { Browser.CoreWebView2?.CookieManager.DeleteAllCookies(); }
                catch (Exception) { }
                ShowError("Google Photos did not accept this sign-in. Close this window and try again, or use the advanced credential option.");
            }
        }
        catch (Exception)
        {
            ShowError("The sign-in could not be checked. Close this window and try again.");
            _cookieTimer.Stop();
        }
        finally { _checking = false; }
    }

    private void ShowError(string message)
    {
        SignInNotice.Message = message;
        SignInNotice.IsOpen = true;
    }
}
