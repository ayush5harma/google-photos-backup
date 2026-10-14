using System.Collections.ObjectModel;
using GooglePhotosBackup.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.Storage.Streams;

namespace GooglePhotosBackup.App;

public sealed partial class MainWindow : Window
{
    private readonly ObservableCollection<string> _folders = [];
    private readonly ObservableCollection<string> _activity = [];
    private readonly LocalStore? _store;
    private readonly List<RunRecord> _history = [];
    private AppPreferences _preferences = new();
    private BackupCoordinator? _coordinator;
    private SignInWindow? _signInWindow;
    private CancellationTokenSource? _runCancellation;
    private string? _credential;
    private bool _connecting;
    private bool _paused;
    private bool _loadingSettings;
    private bool _hasRunAttempt;
    private int _runGeneration;
    private Action<BackupProgress>? _progressSubscription;

    public MainWindow(bool smokeTest = false)
    {
        InitializeComponent();
        AppWindow.Resize(new SizeInt32(1080, 760));
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "app-icon.ico");
        if (File.Exists(iconPath)) AppWindow.SetIcon(iconPath);
        FoldersList.ItemsSource = _folders;
        ActivityList.ItemsSource = _activity;
        Navigation.SelectedItem = Navigation.MenuItems[0];

        if (smokeTest)
        {
            // 2026-10-15: CI fixtures construct the actual window without touching user state or network.
            // 2026-10-15: RenderTargetBitmap omits Mica; an opaque fixture brush preserves readable navigation in CI PNGs.
            Navigation.Background = new SolidColorBrush(Navigation.ActualTheme == ElementTheme.Dark
                ? Microsoft.UI.Colors.Black : Microsoft.UI.Colors.White);
            _folders.Add(@"C:\Sample Photos\Family");
            _folders.Add(@"C:\Sample Photos\Travel");
            AccountText.Text = "sample@example.invalid";
            SettingsAccountText.Text = AccountText.Text;
            OverviewSignInButton.Visibility = Visibility.Collapsed;
            SettingsSignInButton.Visibility = Visibility.Collapsed;
            StatusText.Text = "Backing up sample photos";
            RunProgress.Value = 42;
            ProgressText.Text = "42 of 100 files · 0 failed";
            SelectionSummary.Text = "2 folders selected";
            _activity.Add("Today · 48 uploaded · 2 already in Google Photos · 0 failed");
            StartButton.IsEnabled = false;
            PauseButton.IsEnabled = true;
            CancelButton.IsEnabled = true;
            return;
        }

        _store = new LocalStore();
        _preferences = _store.LoadPreferences();
        _credential = _store.LoadCredential();
        foreach (var folder in _preferences.Folders.Distinct(StringComparer.OrdinalIgnoreCase)) _folders.Add(folder);
        _history.AddRange(_store.LoadHistory());
        RefreshHistory();
        _loadingSettings = true;
        QualityBox.SelectedIndex = _preferences.Quality switch { "saver" => 1, "quota" => 2, _ => 0 };
        MirrorFoldersToggle.IsOn = _preferences.MirrorFolders;
        _loadingSettings = false;
        Closed += (_, _) => { _runGeneration++; _runCancellation?.Cancel(); _signInWindow?.Close(); };
        RefreshControls();
    }

    private void Navigation_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItemContainer is not NavigationViewItem item) return;
        var tag = item.Tag?.ToString();
        OverviewPage.Visibility = tag == "overview" ? Visibility.Visible : Visibility.Collapsed;
        FoldersPage.Visibility = tag == "folders" ? Visibility.Visible : Visibility.Collapsed;
        ActivityPage.Visibility = tag == "activity" ? Visibility.Visible : Visibility.Collapsed;
        SettingsPage.Visibility = tag == "settings" ? Visibility.Visible : Visibility.Collapsed;
        Navigation.Header = item.Content;
    }

    private async void AddFolder_Click(object sender, RoutedEventArgs args)
    {
        if (_runCancellation is not null) return;
        try
        {
            var picker = new FolderPicker();
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            var folder = await picker.PickSingleFolderAsync();
            if (folder is null) return;
            var path = Path.GetFullPath(folder.Path);
            if (_folders.Any(existing => string.Equals(existing, path, StringComparison.OrdinalIgnoreCase)))
            {
                ShowNotice("That folder is already selected.", InfoBarSeverity.Informational);
                return;
            }
            _folders.Add(path);
            SavePreferences();
            RefreshControls();
        }
        catch (Exception)
        {
            ShowNotice("The folder could not be added. Check its permissions and try again.", InfoBarSeverity.Error);
        }
    }

    private void RemoveFolder_Click(object sender, RoutedEventArgs args)
    {
        if (_runCancellation is not null || FoldersList.SelectedItem is not string selected) return;
        _folders.Remove(selected);
        SavePreferences();
        RefreshControls();
    }

    private async void Start_Click(object sender, RoutedEventArgs args)
    {
        if (_store is null || _runCancellation is not null || _credential is null || _folders.Count == 0) return;
        if (_folders.Any(folder => !Directory.Exists(folder)))
        {
            ShowNotice("A selected folder is unavailable. Reconnect its drive or remove it before backing up.", InfoBarSeverity.Warning);
            return;
        }
        var started = DateTimeOffset.Now;
        _hasRunAttempt = true;
        var generation = ++_runGeneration;
        _runCancellation = new CancellationTokenSource();
        _paused = false;
        BackupSummary? summary = null;
        try
        {
            var bridge = CreateBridge();
            _coordinator = new BackupCoordinator(bridge, _store.StateDirectory);
            _progressSubscription = progress => ProgressChanged(progress, generation);
            _coordinator.ProgressChanged += _progressSubscription;
            RefreshControls();
            StatusText.Text = "Preparing backup";
            var options = new BackupOptions([.. _folders], _preferences.Quality,
                _preferences.MirrorFolders, _preferences.Threads);
            summary = await _coordinator.RunAsync(options, _credential, _runCancellation.Token);
            StatusText.Text = summary.Canceled ? "Backup canceled" : summary.Failed > 0 ? "Backup finished with failures" : "Backup complete";
            ProgressText.Text = $"{summary.Uploaded} uploaded · {summary.Existing} already backed up · {summary.Failed} failed";
        }
        catch (OperationCanceledException) when (_runCancellation.IsCancellationRequested)
        {
            StatusText.Text = "Backup canceled";
            ProgressText.Text = "Confirmed uploads remain in Google Photos.";
        }
        catch (Exception)
        {
            StatusText.Text = "Backup could not finish";
            ShowNotice("Backup could not finish. Check folder access, the Google account, and the bundled uploader.", InfoBarSeverity.Error);
        }
        finally
        {
            _runGeneration++;
            if (_coordinator is not null && _progressSubscription is not null)
                _coordinator.ProgressChanged -= _progressSubscription;
            _progressSubscription = null;
            _coordinator = null;
            _runCancellation.Dispose();
            _runCancellation = null;
            if (summary is not null)
            {
                _history.Insert(0, new RunRecord(started, summary.Uploaded, summary.Existing, summary.Failed, summary.Canceled));
                try { _store.SaveHistory(_history); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                { ShowNotice("The backup completed, but its history could not be saved.", InfoBarSeverity.Warning); }
                RefreshHistory();
            }
            RefreshControls();
        }
    }

    private void ProgressChanged(BackupProgress progress, int generation)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (generation != _runGeneration) return;
            StatusText.Text = progress.Phase;
            RunProgress.Value = progress.Total > 0 ? 100.0 * progress.Completed / progress.Total : 0;
            ProgressText.Text = progress.Total > 0
                ? $"{progress.Completed} of {progress.Total} files · {progress.Failed} failed"
                : progress.Message ?? "Preparing files";
        });
    }

    private void Pause_Click(object sender, RoutedEventArgs args)
    {
        if (_coordinator is null) return;
        _coordinator.Pause();
        _paused = true;
        StatusText.Text = "Paused after the current upload";
        RefreshControls();
    }

    private void Resume_Click(object sender, RoutedEventArgs args)
    {
        if (_coordinator is null) return;
        _coordinator.Resume();
        _paused = false;
        StatusText.Text = "Resuming backup";
        RefreshControls();
    }

    private void Cancel_Click(object sender, RoutedEventArgs args)
    {
        _runCancellation?.Cancel();
        StatusText.Text = "Stopping backup";
        CancelButton.IsEnabled = false;
    }

    private async void SignIn_Click(object sender, RoutedEventArgs args)
    {
        if (_runCancellation is not null || _connecting || _signInWindow is not null) return;
        try
        {
            var window = new SignInWindow(async token =>
            {
                using var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false })
                { Timeout = TimeSpan.FromSeconds(45) };
                var credential = await GoogleSignIn.ExchangeAsync(token, http, CancellationToken.None);
                await CheckAndSaveCredentialAsync(credential);
            });
            _signInWindow = window;
            window.Closed += (_, _) => { _signInWindow = null; RefreshControls(); };
            window.Activate();
            RefreshControls();
        }
        catch (Exception)
        {
            ShowNotice("Google's sign-in window could not open. Use the advanced credential option in Settings.", InfoBarSeverity.Error);
        }
    }

    private async void ConnectCredential_Click(object sender, RoutedEventArgs args)
    {
        if (_runCancellation is not null || _connecting) return;
        var candidate = CredentialBox.Password.Trim();
        CredentialBox.Password = string.Empty;
        if (candidate.Length == 0)
        {
            ShowNotice("Paste a gpmc auth_data credential first.", InfoBarSeverity.Warning);
            return;
        }
        try { await CheckAndSaveCredentialAsync(candidate); }
        catch (Exception) { ShowNotice("The credential could not be checked. Verify it and your connection, then try again.", InfoBarSeverity.Error); }
    }

    private async Task CheckAndSaveCredentialAsync(string candidate)
    {
        if (_store is null || _runCancellation is not null) return;
        _connecting = true;
        RefreshControls();
        try
        {
            var email = GoogleSignIn.Email(candidate)
                ?? throw new InvalidOperationException("The credential has no valid account address.");
            var accepted = await new BackupCoordinator(CreateBridge(), _store.StateDirectory)
                .CheckAuthAsync(candidate, CancellationToken.None);
            if (!accepted)
                throw new InvalidOperationException("Google Photos did not accept this account. Sign in again.");
            _store.SaveCredential(candidate);
            _credential = candidate;
            ShowNotice($"Connected to {email}.", InfoBarSeverity.Success);
        }
        finally
        {
            _connecting = false;
            RefreshControls();
        }
    }

    private void Disconnect_Click(object sender, RoutedEventArgs args)
    {
        if (_store is null || _runCancellation is not null || _connecting) return;
        try
        {
            _store.ClearCredential();
            _credential = null;
            ShowNotice("Google Photos disconnected on this PC.", InfoBarSeverity.Informational);
            RefreshControls();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            ShowNotice("The account could not be disconnected. Try again.", InfoBarSeverity.Error);
        }
    }

    private void Quality_SelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        if (_loadingSettings || QualityBox.SelectedItem is not ComboBoxItem selected) return;
        _preferences.Quality = selected.Tag?.ToString() ?? "original";
        SavePreferences();
    }

    private void MirrorFolders_Toggled(object sender, RoutedEventArgs args)
    {
        if (_loadingSettings) return;
        _preferences.MirrorFolders = MirrorFoldersToggle.IsOn;
        SavePreferences();
    }

    private void SavePreferences()
    {
        if (_store is null) return;
        _preferences.Folders = [.. _folders];
        try { _store.SavePreferences(_preferences); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { ShowNotice("Settings could not be saved. Check disk space and try again.", InfoBarSeverity.Error); }
    }

    private void RefreshHistory()
    {
        _activity.Clear();
        foreach (var record in _history.Take(40))
            _activity.Add($"{record.Started:g} · {record.Uploaded} uploaded · {record.Existing} already backed up · {record.Failed} failed{(record.Canceled ? " · canceled" : "")}");
        if (_activity.Count == 0) _activity.Add("No backup runs yet.");
    }

    private void RefreshControls()
    {
        var busy = _runCancellation is not null;
        var email = _credential is null ? null : GoogleSignIn.Email(_credential);
        AccountText.Text = email ?? "Not connected";
        SettingsAccountText.Text = email ?? "Not connected";
        OverviewSignInButton.Content = email is null ? "Connect Google Photos" : "Change Google account";
        OverviewSignInButton.IsEnabled = !busy && !_connecting && _signInWindow is null;
        SettingsSignInButton.IsEnabled = !busy && !_connecting && _signInWindow is null;
        ConnectCredentialButton.IsEnabled = !busy && !_connecting && _signInWindow is null;
        CredentialBox.IsEnabled = !busy && !_connecting && _signInWindow is null;
        DisconnectButton.IsEnabled = email is not null && !busy && !_connecting && _signInWindow is null;
        StartButton.IsEnabled = email is not null && _folders.Count > 0 && !busy && !_connecting && _signInWindow is null;
        PauseButton.IsEnabled = busy && !_paused;
        ResumeButton.IsEnabled = busy && _paused;
        CancelButton.IsEnabled = busy;
        AddFolderButton.IsEnabled = !busy;
        RemoveFolderButton.IsEnabled = !busy;
        QualityBox.IsEnabled = !busy;
        MirrorFoldersToggle.IsEnabled = !busy;
        SelectionSummary.Text = _folders.Count == 1 ? "1 folder selected" : $"{_folders.Count} folders selected";
        if (!busy && !_hasRunAttempt && _history.Count == 0)
            StatusText.Text = email is null ? "Connect a Google Photos account to get started."
                : _folders.Count == 0 ? "Choose a folder to get started." : "Ready to back up";
    }

    private static IBridgeClient CreateBridge()
    {
        var python = Path.Combine(AppContext.BaseDirectory, "runtime", "python", "python.exe");
        var script = Path.Combine(AppContext.BaseDirectory, "runtime", "bridge", "gpmc_bridge.py");
        if (!File.Exists(python) || !File.Exists(script))
            throw new InvalidOperationException("The bundled uploader is missing. Reinstall Google Photos Backup.");
        return new BridgeProcessClient(python, script);
    }

    private void ShowNotice(string message, InfoBarSeverity severity)
    {
        NoticeBar.Message = message;
        NoticeBar.Severity = severity;
        NoticeBar.IsOpen = true;
        Navigation.SelectedItem = Navigation.MenuItems[0];
    }

    public async Task SaveScreenshotAsync(string path)
    {
        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync((UIElement)Content);
        if (bitmap.PixelWidth == 0 || bitmap.PixelHeight == 0)
            throw new InvalidOperationException("The window did not render.");
        var buffer = await bitmap.GetPixelsAsync();
        var pixels = new byte[(int)buffer.Length];
        using (var reader = DataReader.FromBuffer(buffer)) reader.ReadBytes(pixels);
        var fullPath = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
        File.WriteAllBytes(fullPath, []);
        var file = await StorageFile.GetFileFromPathAsync(fullPath);
        using var stream = await file.OpenAsync(FileAccessMode.ReadWrite);
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels);
        await encoder.FlushAsync();
    }

    public Task WhenLoadedAsync()
    {
        if (Navigation.IsLoaded) return Task.CompletedTask;
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        RoutedEventHandler? handler = null;
        handler = (_, _) =>
        {
            Navigation.Loaded -= handler;
            ready.TrySetResult();
        };
        Navigation.Loaded += handler;
        return ready.Task;
    }
}
