using System.Text.Json.Nodes;

namespace GooglePhotosBackup.Core;

public enum ICloudAuthStatus { SignedOut, NeedsTwoFactor, SignedIn }

public sealed record ICloudTrustedPhone(int Id, string Label);

public sealed record ICloudBackupResult(int Uploaded, int Existing, int Failed, int Pending);

public sealed record ICloudBackupProgress(int Completed, int Total, int Uploaded, int Existing, int Failed);

public sealed class ICloudCoordinator(IBridgeClient bridge, string stateDirectory, string stagingDirectory)
{
    public event Action<ICloudBackupProgress>? ProgressChanged;
    public IReadOnlyList<ICloudTrustedPhone> TrustedPhones { get; private set; } = [];
    public bool DeviceCodeAvailable { get; private set; }

    public Task<ICloudAuthStatus> StatusAsync(string account, CancellationToken cancellationToken) =>
        AuthenticateAsync("status", account, null, null, cancellationToken);

    public Task<ICloudAuthStatus> SignInAsync(string account, string password, CancellationToken cancellationToken) =>
        AuthenticateAsync("sign-in", account, password, null, cancellationToken);

    public Task<ICloudAuthStatus> VerifyTwoFactorAsync(string account, string password, string code, CancellationToken cancellationToken) =>
        AuthenticateAsync("verify-2fa", account, password, code, cancellationToken);

    public Task<ICloudAuthStatus> VerifyTwoFactorAsync(string account, string password, string code,
        int? phoneId, CancellationToken cancellationToken) =>
        AuthenticateAsync("verify-2fa", account, password, code, cancellationToken, phoneId);

    public Task<ICloudAuthStatus> SendCodeAsync(string account, string password, int phoneId,
        CancellationToken cancellationToken)
    {
        if (phoneId < 0) throw new ArgumentException("Choose a trusted phone.", nameof(phoneId));
        return AuthenticateAsync("send-code", account, password, null, cancellationToken, phoneId);
    }

    private async Task<ICloudAuthStatus> AuthenticateAsync(string command, string account, string? password,
        string? code, CancellationToken cancellationToken, int? phoneId = null)
    {
        if (string.IsNullOrWhiteSpace(account)) throw new ArgumentException("Enter an Apple Account email address.", nameof(account));
        var request = new JsonObject { ["command"] = command, ["account"] = account.Trim(), ["state_dir"] = stateDirectory };
        if (password is not null) request["password"] = password;
        if (code is not null) request["code"] = code;
        if (phoneId is not null) request["phone_id"] = phoneId;
        ICloudAuthStatus? status = null;
        var error = false;
        var legacyTwoStep = false;
        TrustedPhones = [];
        DeviceCodeAvailable = false;
        var exit = await bridge.ExecuteAsync(request, message =>
        {
            if (Text(message, "type") == "fatal") { error = true; legacyTwoStep = Text(message, "kind") == "unsupported_2sa"; }
            if (Text(message, "type") != "auth") return;
            if (Text(message, "account") is { } returnedAccount &&
                !string.Equals(returnedAccount, account.Trim(), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The iCloud session belongs to a different account.");
            status = Text(message, "status") switch
            {
                "signed_in" => ICloudAuthStatus.SignedIn,
                "needs_2fa" => ICloudAuthStatus.NeedsTwoFactor,
                "signed_out" => ICloudAuthStatus.SignedOut,
                _ => throw new InvalidOperationException("iCloud returned an unknown sign-in state.")
            };
            DeviceCodeAvailable = message["device_code_available"] is JsonValue deviceValue &&
                deviceValue.TryGetValue<bool>(out var deviceAvailable) && deviceAvailable;
            if (message["phones"] is JsonArray phones)
                TrustedPhones = phones.OfType<JsonObject>()
                    .Where(phone => phone["id"] is JsonValue id && id.TryGetValue<int>(out _))
                    .Select(phone => new ICloudTrustedPhone(phone["id"]!.GetValue<int>(), Text(phone, "label") ?? ""))
                    .Where(phone => phone.Id >= 0 && phone.Label.Length > 0)
                    .ToArray();
        }, cancellationToken).ConfigureAwait(false);
        if (legacyTwoStep) throw new InvalidOperationException("Legacy Apple two-step verification is not supported. Use two-factor authentication or back up a local folder.");
        if (exit != 0 || error || status is null) throw new InvalidOperationException("iCloud sign-in could not be checked. Try again.");
        return status.Value;
    }

    public async Task<ICloudBackupResult> BackupAsync(string account, string googleCredential, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(account)) throw new ArgumentException("Connect iCloud first.", nameof(account));
        if (GoogleSignIn.Email(googleCredential) is null) throw new ArgumentException("Connect Google Photos first.", nameof(googleCredential));
        var request = new JsonObject
        {
            ["command"] = "backup", ["account"] = account.Trim(), ["state_dir"] = stateDirectory,
            ["staging_dir"] = stagingDirectory, ["auth_data"] = googleCredential
        };
        ICloudBackupResult? result = null;
        var error = false;
        var expired = false;
        var exit = await bridge.ExecuteAsync(request, message =>
        {
            switch (Text(message, "type"))
            {
                case "auth":
                    expired |= Text(message, "status") != "signed_in";
                    break;
                case "fatal":
                    error = true;
                    expired |= Text(message, "kind") is "auth_expired" or "session_expired";
                    break;
                case "progress":
                    ProgressChanged?.Invoke(new ICloudBackupProgress(
                        Number(message, "completed"), Number(message, "total"), Number(message, "uploaded"),
                        Number(message, "existing"), Number(message, "failed")));
                    break;
                case "done":
                    result = new ICloudBackupResult(Number(message, "uploaded"), Number(message, "existing"),
                        Number(message, "failed"), Number(message, "pending"));
                    break;
            }
        }, cancellationToken).ConfigureAwait(false);
        if (expired) throw new InvalidOperationException("Your iCloud session expired. Sign in again and resume.");
        if (exit != 0 || error || result is null) throw new InvalidOperationException("iCloud backup stopped. Sign in again if needed, then resume.");
        return result;
    }

    private static string? Text(JsonObject item, string key) =>
        item[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static int Number(JsonObject item, string key) =>
        item[key] is JsonValue value && value.TryGetValue<int>(out var number) && number >= 0 ? number : 0;
}
