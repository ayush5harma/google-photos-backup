using GooglePhotosBackup.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GooglePhotosBackup.App;

public sealed partial class MainWindow
{
    private ICloudCoordinator? _icloudCoordinator;
    private CancellationTokenSource? _icloudRunCancellation;
    private string? _icloudPendingPassword;
    private string? _icloudPendingAccount;
    private bool _icloudConnecting;
    private bool _icloudSignedIn;
    private bool _icloudPaused;
    private int _icloudGeneration;

    private void InitializeICloud()
    {
        if (_preferences.ICloudAccount is not { Length: > 0 } account) return;
        ICloudAccountBox.Text = account;
        ICloudAccountStatus.Text = "Checking iCloud session";
        _ = CheckICloudSessionAsync(account);
    }

    private async Task CheckICloudSessionAsync(string account)
    {
        _icloudConnecting = true;
        RefreshICloudControls();
        try
        {
            var status = await GetICloudCoordinator().StatusAsync(account, CancellationToken.None);
            _icloudSignedIn = status == ICloudAuthStatus.SignedIn;
            ICloudAccountStatus.Text = _icloudSignedIn
                ? $"Connected to iCloud as {account}"
                : "iCloud session expired. Sign in again to resume.";
            if (status == ICloudAuthStatus.NeedsTwoFactor)
                ICloudAccountStatus.Text = "Apple verification required. Sign in again, then enter the code.";
        }
        catch (Exception)
        {
            _icloudSignedIn = false;
            ICloudAccountStatus.Text = "iCloud session could not be checked. Sign in to continue.";
        }
        finally { _icloudConnecting = false; RefreshICloudControls(); }
    }

    private async void ICloudSignIn_Click(object sender, RoutedEventArgs args)
    {
        if (_icloudConnecting || _icloudRunCancellation is not null) return;
        var account = ICloudAccountBox.Text.Trim();
        var password = ICloudPasswordBox.Password;
        ICloudPasswordBox.Password = string.Empty;
        _icloudPendingPassword = null;
        _icloudPendingAccount = null;
        if (account.Length == 0 || password.Length == 0)
        {
            ShowICloudNotice("Enter your Apple Account email and password.", InfoBarSeverity.Warning);
            return;
        }
        _icloudConnecting = true;
        _icloudSignedIn = false;
        ICloudTwoFactorPanel.Visibility = Visibility.Collapsed;
        RefreshICloudControls();
        try
        {
            var status = await GetICloudCoordinator().SignInAsync(account, password, CancellationToken.None);
            if (status == ICloudAuthStatus.NeedsTwoFactor)
            {
                // 2026-10-15: The password remains in process memory only for Apple's next verification step.
                _icloudPendingPassword = password;
                _icloudPendingAccount = account;
                ICloudTwoFactorPanel.Visibility = Visibility.Visible;
                ICloudAccountStatus.Text = "Check your trusted Apple device or phone for a verification code.";
            }
            else if (status == ICloudAuthStatus.SignedIn) CompleteICloudSignIn(account);
            else ShowICloudNotice("Apple did not accept this sign-in. Check your credentials and try again.", InfoBarSeverity.Warning);
        }
        catch (Exception)
        {
            ShowICloudNotice("iCloud sign-in failed. Check your account, connection, and Apple verification settings.", InfoBarSeverity.Error);
        }
        finally { _icloudConnecting = false; RefreshICloudControls(); }
    }

    private async void ICloudVerify_Click(object sender, RoutedEventArgs args)
    {
        if (_icloudConnecting || _icloudPendingPassword is null || _icloudPendingAccount is null) return;
        var code = ICloudCodeBox.Text.Trim();
        ICloudCodeBox.Text = string.Empty;
        if (code.Length != 6 || !code.All(char.IsAsciiDigit))
        {
            ShowICloudNotice("Enter the six-digit verification code Apple sent you.", InfoBarSeverity.Warning);
            return;
        }
        _icloudConnecting = true;
        RefreshICloudControls();
        try
        {
            var status = await GetICloudCoordinator().VerifyTwoFactorAsync(
                _icloudPendingAccount, _icloudPendingPassword, code, CancellationToken.None);
            if (status == ICloudAuthStatus.SignedIn) CompleteICloudSignIn(_icloudPendingAccount);
            else if (status == ICloudAuthStatus.NeedsTwoFactor)
                ShowICloudNotice("That code was not accepted. Get a new code and try again.", InfoBarSeverity.Warning);
            else
            {
                _icloudPendingPassword = null;
                _icloudPendingAccount = null;
                ICloudTwoFactorPanel.Visibility = Visibility.Collapsed;
                ShowICloudNotice("The Apple session expired. Sign in again.", InfoBarSeverity.Warning);
            }
        }
        catch (Exception)
        {
            ShowICloudNotice("The verification code could not be checked. Request a new code and try again.", InfoBarSeverity.Error);
        }
        finally { _icloudConnecting = false; RefreshICloudControls(); }
    }

    private void CompleteICloudSignIn(string account)
    {
        ClearICloudPendingSignIn();
        _icloudSignedIn = true;
        ICloudTwoFactorPanel.Visibility = Visibility.Collapsed;
        ICloudAccountStatus.Text = $"Connected to iCloud as {account}";
        _preferences.ICloudAccount = account;
        SavePreferences();
        ShowICloudNotice("iCloud Photos connected. Connect Google Photos in Overview before backing up.", InfoBarSeverity.Success);
    }

    private async void ICloudStart_Click(object sender, RoutedEventArgs args) => await RunICloudBackupAsync();
    private async void ICloudResume_Click(object sender, RoutedEventArgs args) => await RunICloudBackupAsync();

    private async Task RunICloudBackupAsync()
    {
        if (_icloudRunCancellation is not null || _runCancellation is not null || !_icloudSignedIn || _credential is null ||
            _preferences.ICloudAccount is not { Length: > 0 } account || _store is null) return;
        var generation = ++_icloudGeneration;
        _icloudPaused = false;
        _icloudRunCancellation = new CancellationTokenSource();
        var cancellation = _icloudRunCancellation;
        var coordinator = GetICloudCoordinator();
        void OnProgress(ICloudBackupProgress progress)
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                if (generation != _icloudGeneration) return;
                ICloudProgress.Value = progress.Total > 0 ? 100.0 * progress.Completed / progress.Total : 0;
                ICloudProgressText.Text = $"{progress.Completed} of {progress.Total} checked · {progress.Uploaded} uploaded · {progress.Existing} already backed up · {progress.Failed} failed";
            });
        }
        coordinator.ProgressChanged += OnProgress;
        ICloudBackupStatus.Text = "Backing up iCloud Photos";
        RefreshControls();
        try
        {
            var result = await coordinator.BackupAsync(account, _credential, cancellation.Token);
            ICloudBackupStatus.Text = result.Pending > 0 ? "Backup paused with items still pending"
                : result.Failed > 0 ? "Backup finished with failures" : "iCloud backup complete";
            ICloudProgressText.Text = $"{result.Uploaded} uploaded · {result.Existing} already backed up · {result.Failed} failed · {result.Pending} pending";
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            ICloudBackupStatus.Text = "Paused. Confirmed uploads can be resumed.";
        }
        catch (InvalidOperationException error) when (error.Message.Contains("session expired", StringComparison.OrdinalIgnoreCase))
        {
            _icloudSignedIn = false;
            ICloudBackupStatus.Text = "iCloud session expired";
            ShowICloudNotice("Sign in to iCloud again, then resume the backup.", InfoBarSeverity.Warning);
        }
        catch (Exception)
        {
            ICloudBackupStatus.Text = "iCloud backup stopped";
            ShowICloudNotice("The backup stopped. Check both accounts and your connection, then resume.", InfoBarSeverity.Error);
        }
        finally
        {
            coordinator.ProgressChanged -= OnProgress;
            _icloudGeneration++;
            cancellation.Dispose();
            _icloudRunCancellation = null;
            RefreshControls();
        }
    }

    private void ICloudPause_Click(object sender, RoutedEventArgs args)
    {
        if (_icloudRunCancellation is null) return;
        _icloudPaused = true;
        _icloudRunCancellation.Cancel();
        ICloudBackupStatus.Text = "Pausing after the current transfer";
        RefreshICloudControls();
    }

    private void RefreshICloudControls()
    {
        var busy = _icloudRunCancellation is not null;
        var hasGoogle = GoogleSignIn.Email(_credential ?? "") is not null;
        ICloudSignInButton.IsEnabled = !_icloudConnecting && !busy;
        ICloudVerifyButton.IsEnabled = !_icloudConnecting && !busy;
        ICloudAccountBox.IsEnabled = !_icloudConnecting && !busy && _icloudPendingAccount is null;
        ICloudPasswordBox.IsEnabled = !_icloudConnecting && !busy;
        ICloudStartButton.IsEnabled = _icloudSignedIn && hasGoogle && !busy && _runCancellation is null && !_icloudPaused;
        ICloudPauseButton.IsEnabled = busy && !_icloudPaused;
        ICloudResumeButton.IsEnabled = _icloudSignedIn && hasGoogle && !busy && _runCancellation is null && _icloudPaused;
        if (!hasGoogle && _icloudSignedIn)
            ICloudBackupStatus.Text = "Connect Google Photos in Overview to start the backup.";
    }

    private ICloudCoordinator GetICloudCoordinator()
    {
        if (_icloudCoordinator is not null) return _icloudCoordinator;
        if (_store is null) throw new InvalidOperationException("iCloud is unavailable in the screenshot fixture.");
        var python = Path.Combine(AppContext.BaseDirectory, "runtime", "python", "python.exe");
        var script = Path.Combine(AppContext.BaseDirectory, "runtime", "bridge", "icloud_bridge.py");
        if (!File.Exists(python) || !File.Exists(script))
            throw new InvalidOperationException("The bundled iCloud connector is missing.");
        _icloudCoordinator = new ICloudCoordinator(new BridgeProcessClient(python, script),
            Path.Combine(_store.StateDirectory, "iCloud"), Path.Combine(_store.Root, "iCloudStaging"));
        return _icloudCoordinator;
    }

    private void ShowICloudNotice(string message, InfoBarSeverity severity)
    {
        ICloudNotice.Message = message;
        ICloudNotice.Severity = severity;
        ICloudNotice.IsOpen = true;
    }

    private void ClearICloudPendingSignIn()
    {
        _icloudPendingPassword = null;
        _icloudPendingAccount = null;
        ICloudPasswordBox.Password = string.Empty;
        ICloudCodeBox.Text = string.Empty;
        ICloudTwoFactorPanel.Visibility = Visibility.Collapsed;
    }

    public bool ValidateICloudSmokePage()
    {
        var original = Navigation.SelectedItem;
        try
        {
            Navigation.SelectedItem = Navigation.MenuItems[2];
            return ICloudPage.Visibility == Visibility.Visible &&
                ICloudAccountBox is not null && ICloudPasswordBox is not null &&
                ICloudTwoFactorPanel.Visibility == Visibility.Collapsed && !ICloudStartButton.IsEnabled;
        }
        finally { Navigation.SelectedItem = original; }
    }
}
