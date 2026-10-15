using GooglePhotosBackup.Core;
using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GooglePhotosBackup.App;

public sealed partial class MainWindow
{
    private ICloudCoordinator? _icloudCoordinator;
    private CancellationTokenSource? _icloudRunCancellation;
    private string? _icloudPendingPassword;
    private string? _icloudPendingAccount;
    private int? _icloudSelectedPhoneId;
    private bool _icloudDeviceCodeAvailable;
    private bool _icloudConnecting;
    private bool _icloudSignedIn;
    private bool _icloudPaused;
    private int _icloudAuthGeneration;
    private int _icloudGeneration;
    private readonly ObservableCollection<ICloudSourceAsset> _icloudReclaimCandidates = [];
    private ICloudReclaimPreview? _icloudReclaimPreview;

    private void InitializeICloud()
    {
        ICloudReclaimList.ItemsSource = _icloudReclaimCandidates;
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
        _icloudSelectedPhoneId = null;
        if (account.Length == 0 || password.Length == 0)
        {
            ShowICloudNotice("Enter your Apple Account email and password.", InfoBarSeverity.Warning);
            return;
        }
        _icloudConnecting = true;
        _icloudSignedIn = false;
        var generation = _icloudAuthGeneration;
        ICloudTwoFactorPanel.Visibility = Visibility.Collapsed;
        RefreshICloudControls();
        try
        {
            var status = await GetICloudCoordinator().SignInAsync(account, password, CancellationToken.None);
            if (generation != _icloudAuthGeneration) return;
            if (status == ICloudAuthStatus.NeedsTwoFactor)
            {
                // 2026-10-15: The password remains in process memory only for Apple's next verification step.
                _icloudPendingPassword = password;
                _icloudPendingAccount = account;
                ICloudTwoFactorPanel.Visibility = Visibility.Visible;
                ApplyICloudVerificationMethods();
                ICloudAccountStatus.Text = "Apple verification required.";
            }
            else if (status == ICloudAuthStatus.SignedIn) CompleteICloudSignIn(account);
            else ShowICloudNotice("Apple did not accept this sign-in. Check your credentials and try again.", InfoBarSeverity.Warning);
        }
        catch (InvalidOperationException error) when (error.Message.Contains("Legacy Apple two-step", StringComparison.Ordinal))
        {
            if (generation == _icloudAuthGeneration)
                ShowICloudNotice("This Apple Account uses legacy two-step verification, which this transfer cannot use. Back up a local folder instead.", InfoBarSeverity.Warning);
        }
        catch (Exception)
        {
            if (generation == _icloudAuthGeneration)
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
        var generation = _icloudAuthGeneration;
        RefreshICloudControls();
        try
        {
            var status = await GetICloudCoordinator().VerifyTwoFactorAsync(
                _icloudPendingAccount, _icloudPendingPassword, code, _icloudSelectedPhoneId, CancellationToken.None);
            if (generation != _icloudAuthGeneration) return;
            if (status == ICloudAuthStatus.SignedIn) CompleteICloudSignIn(_icloudPendingAccount);
            else if (status == ICloudAuthStatus.NeedsTwoFactor)
            {
                ApplyICloudVerificationMethods();
                ShowICloudNotice("That code was not accepted. Get a new code and try again.", InfoBarSeverity.Warning);
            }
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
            if (generation == _icloudAuthGeneration)
                ShowICloudNotice("The verification code could not be checked. Request a new code and try again.", InfoBarSeverity.Error);
        }
        finally { _icloudConnecting = false; RefreshICloudControls(); }
    }

    private async void ICloudSendCode_Click(object sender, RoutedEventArgs args)
    {
        if (_icloudConnecting || _icloudPendingAccount is null || _icloudPendingPassword is null ||
            ICloudPhoneBox.SelectedItem is not ComboBoxItem { Tag: int phoneId }) return;
        _icloudConnecting = true;
        var generation = _icloudAuthGeneration;
        RefreshICloudControls();
        try
        {
            var status = await GetICloudCoordinator().SendCodeAsync(
                _icloudPendingAccount, _icloudPendingPassword, phoneId, CancellationToken.None);
            if (generation != _icloudAuthGeneration) return;
            if (status == ICloudAuthStatus.SignedIn) CompleteICloudSignIn(_icloudPendingAccount);
            else if (status == ICloudAuthStatus.NeedsTwoFactor)
            {
                _icloudSelectedPhoneId = phoneId;
                ApplyICloudVerificationMethods();
                ICloudCodeModeText.Text = "Enter the six-digit code Apple sent by text message.";
                ICloudUseDeviceButton.Visibility = _icloudDeviceCodeAvailable ? Visibility.Visible : Visibility.Collapsed;
                ICloudCodeBox.Text = string.Empty;
                ShowICloudNotice("A code was requested for the selected trusted phone.", InfoBarSeverity.Informational);
            }
            else ShowICloudNotice("Apple could not send a code. Sign in again.", InfoBarSeverity.Warning);
        }
        catch (Exception)
        {
            if (generation == _icloudAuthGeneration)
                ShowICloudNotice("The text message could not be sent. Choose another trusted phone or try again.", InfoBarSeverity.Error);
        }
        finally { _icloudConnecting = false; RefreshICloudControls(); }
    }

    private void ICloudUseDevice_Click(object sender, RoutedEventArgs args)
    {
        if (!_icloudDeviceCodeAvailable || _icloudConnecting) return;
        _icloudSelectedPhoneId = null;
        ICloudCodeBox.Text = string.Empty;
        ICloudCodeModeText.Text = "Enter the six-digit code shown on your trusted Apple device.";
        ICloudUseDeviceButton.Visibility = Visibility.Collapsed;
        RefreshICloudControls();
    }

    private void ApplyICloudVerificationMethods()
    {
        var coordinator = GetICloudCoordinator();
        _icloudDeviceCodeAvailable = coordinator.DeviceCodeAvailable;
        var selected = _icloudSelectedPhoneId;
        ICloudPhoneBox.Items.Clear();
        foreach (var phone in coordinator.TrustedPhones)
            ICloudPhoneBox.Items.Add(new ComboBoxItem { Content = phone.Label, Tag = phone.Id });
        ICloudPhoneChoices.Visibility = ICloudPhoneBox.Items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        var chosen = ICloudPhoneBox.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(item => item.Tag is int id && id == selected);
        if (_icloudSelectedPhoneId is not null && chosen is null) _icloudSelectedPhoneId = null;
        ICloudPhoneBox.SelectedItem = chosen ?? ICloudPhoneBox.Items.FirstOrDefault();
        if (!_icloudDeviceCodeAvailable && _icloudSelectedPhoneId is null)
            ICloudCodeModeText.Text = "Choose a trusted phone and request a text message code.";
        else if (_icloudSelectedPhoneId is null)
            ICloudCodeModeText.Text = "Enter the six-digit code shown on your trusted Apple device.";
        ICloudUseDeviceButton.Visibility = _icloudSelectedPhoneId is not null && _icloudDeviceCodeAvailable
            ? Visibility.Visible : Visibility.Collapsed;
        if (!_icloudDeviceCodeAvailable && ICloudPhoneBox.Items.Count == 0)
            ShowICloudNotice("No supported Apple verification method is available for this account. You can back up a local folder instead.", InfoBarSeverity.Warning);
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
        var reclaimAfterBackup = ICloudAutoReclaimToggle.IsOn;
        if (reclaimAfterBackup)
        {
            var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Confirm automatic iCloud reclaim",
                Content = "After each confirmed upload, up to 100 source items will move to iCloud Recently Deleted. This propagates to synced Apple devices, does not recover storage immediately, and is not a permanent purge.",
                PrimaryButtonText = "Back up and move eligible items", CloseButtonText = "Keep originals", DefaultButton = ContentDialogButton.Close };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        }
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
            var result = await coordinator.BackupAsync(account, _credential, cancellation.Token, reclaimAfterBackup);
            ClearICloudReclaimPreview();
            foreach (var asset in coordinator.ReclaimCandidates) _icloudReclaimCandidates.Add(asset);
            if (_icloudReclaimCandidates.Count > 0)
                ICloudReclaimStatus.Text = $"{_icloudReclaimCandidates.Count} confirmed item(s) can be previewed for reclaim. Copy-only remains the default.";
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

    private async void ICloudPreviewReclaim_Click(object sender, RoutedEventArgs args)
    {
        if (_credential is null || _preferences.ICloudAccount is not { Length: > 0 } account || _icloudRunCancellation is not null) return;
        var selected = ICloudReclaimList.SelectedItems.Cast<ICloudSourceAsset>().Take(100).ToArray();
        if (selected.Length == 0) { ShowICloudNotice("Select confirmed items to preview first.", InfoBarSeverity.Informational); return; }
        try
        {
            _icloudReclaimPreview = await GetICloudCoordinator().PreviewReclaimAsync(account, _credential, selected, CancellationToken.None);
            ICloudReclaimStatus.Text = $"Preview: {_icloudReclaimPreview.Count} item(s), {_icloudReclaimPreview.Bytes:N0} bytes. Nothing has been deleted.";
            ICloudConfirmReclaimButton.IsEnabled = true;
        }
        catch { ClearICloudReclaimPreview(); ShowICloudNotice("Reclaim preview could not be prepared. Nothing was deleted.", InfoBarSeverity.Warning); }
    }

    private async void ICloudConfirmReclaim_Click(object sender, RoutedEventArgs args)
    {
        if (_icloudReclaimPreview is null || _credential is null || _preferences.ICloudAccount is not { Length: > 0 } account) return;
        var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Move source media to Recently Deleted?",
            Content = "This affects iCloud Photos and synced Apple devices. Storage is not recovered immediately; this app does not permanently delete media.",
            PrimaryButtonText = "Move to Recently Deleted", CloseButtonText = "Keep originals", DefaultButton = ContentDialogButton.Close };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            var result = await GetICloudCoordinator().ReclaimAsync(account, _credential, _icloudReclaimPreview.Token, CancellationToken.None);
            ICloudReclaimStatus.Text = $"Recently Deleted: {result.SoftDeleted}; retained: {result.Retained}; needs review: {result.Uncertain}.";
        }
        catch { ICloudReclaimStatus.Text = "Reclaim was not fully confirmed. Check iCloud Recently Deleted before taking further action."; }
        finally { ClearICloudReclaimPreview(); }
    }

    private void ClearICloudReclaimPreview()
    {
        _icloudReclaimPreview = null;
        _icloudReclaimCandidates.Clear();
        ICloudConfirmReclaimButton.IsEnabled = false;
    }

    private void RefreshICloudControls()
    {
        var busy = _icloudRunCancellation is not null;
        var hasGoogle = GoogleSignIn.Email(_credential ?? "") is not null;
        ICloudSignInButton.IsEnabled = !_icloudConnecting && !busy;
        ICloudVerifyButton.IsEnabled = !_icloudConnecting && !busy;
        ICloudVerifyButton.IsEnabled &= _icloudSelectedPhoneId is not null || _icloudDeviceCodeAvailable;
        ICloudSendCodeButton.IsEnabled = !_icloudConnecting && !busy && ICloudPhoneBox.SelectedItem is not null;
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
        _icloudAuthGeneration++;
        _icloudPendingPassword = null;
        _icloudPendingAccount = null;
        _icloudSelectedPhoneId = null;
        _icloudDeviceCodeAvailable = false;
        ICloudPasswordBox.Password = string.Empty;
        ICloudCodeBox.Text = string.Empty;
        ICloudTwoFactorPanel.Visibility = Visibility.Collapsed;
        ICloudPhoneChoices.Visibility = Visibility.Collapsed;
        ICloudPhoneBox.Items.Clear();
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
