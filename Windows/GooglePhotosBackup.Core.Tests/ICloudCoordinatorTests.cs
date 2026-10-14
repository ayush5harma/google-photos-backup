using System.Text.Json.Nodes;
using GooglePhotosBackup.Core;
using Xunit;

namespace GooglePhotosBackup.Core.Tests;

public sealed class ICloudCoordinatorTests
{
    [Theory]
    [InlineData("signed_out", ICloudAuthStatus.SignedOut)]
    [InlineData("signed_in", ICloudAuthStatus.SignedIn)]
    public async Task StatusChecksExistingSessionWithoutSendingSecrets(string bridgeStatus, ICloudAuthStatus expected)
    {
        JsonObject? captured = null;
        var bridge = new FakeBridge((request, emit, _) =>
        {
            captured = request;
            emit(new JsonObject { ["type"] = "auth", ["status"] = bridgeStatus, ["account"] = "first@example.com" });
            return Task.FromResult(0);
        });
        var coordinator = new ICloudCoordinator(bridge, "state", "stage");

        Assert.Equal(expected, await coordinator.StatusAsync("first@example.com", CancellationToken.None));
        Assert.Equal("status", captured!["command"]!.GetValue<string>());
        Assert.Equal("first@example.com", captured["account"]!.GetValue<string>());
        Assert.Equal("state", captured["state_dir"]!.GetValue<string>());
        Assert.Null(captured["password"]);
        Assert.Null(captured["code"]);
    }

    [Fact]
    public async Task AuthenticationPassesSecretsOnlyInRequestAndRejectsWrongAccount()
    {
        JsonObject? captured = null;
        var bridge = new FakeBridge((request, emit, _) =>
        {
            captured = request;
            emit(new JsonObject { ["type"] = "auth", ["status"] = "needs_2fa", ["account"] = "first@example.com" });
            return Task.FromResult(0);
        });
        var coordinator = new ICloudCoordinator(bridge, "state", "stage");
        Assert.Equal(ICloudAuthStatus.NeedsTwoFactor,
            await coordinator.SignInAsync("first@example.com", "private-password", CancellationToken.None));
        Assert.Equal("sign-in", captured!["command"]!.GetValue<string>());
        Assert.Equal("private-password", captured["password"]!.GetValue<string>());
        Assert.Null(captured["code"]);

        bridge.Run = (_, emit, _) =>
        {
            emit(new JsonObject { ["type"] = "auth", ["status"] = "signed_in", ["account"] = "someone@example.com" });
            return Task.FromResult(0);
        };
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            coordinator.VerifyTwoFactorAsync("first@example.com", "private-password", "123456", CancellationToken.None));
    }

    [Fact]
    public async Task InvalidVerificationReturnsSignedOutAndSendsCodeOnlyThroughBridgeInput()
    {
        JsonObject? captured = null;
        var bridge = new FakeBridge((request, emit, _) =>
        {
            captured = request;
            emit(new JsonObject { ["type"] = "auth", ["status"] = "signed_out", ["account"] = "first@example.com" });
            return Task.FromResult(0);
        });
        var coordinator = new ICloudCoordinator(bridge, "state", "stage");

        Assert.Equal(ICloudAuthStatus.SignedOut, await coordinator.VerifyTwoFactorAsync(
            "first@example.com", "private-password", "123456", CancellationToken.None));
        Assert.Equal("verify-2fa", captured!["command"]!.GetValue<string>());
        Assert.Equal("private-password", captured["password"]!.GetValue<string>());
        Assert.Equal("123456", captured["code"]!.GetValue<string>());
    }

    [Fact]
    public async Task TrustedPhonesSupportSmsRequestAndKeepDeviceCodeAsDefault()
    {
        var requests = new List<JsonObject>();
        var bridge = new FakeBridge((request, emit, _) =>
        {
            requests.Add(request);
            emit(new JsonObject
            {
                ["type"] = "auth", ["status"] = "needs_2fa", ["account"] = "first@example.com",
                ["device_code_available"] = true,
                ["phones"] = new JsonArray
                {
                    new JsonObject { ["id"] = 7, ["label"] = "***1234" },
                    new JsonObject { ["id"] = 8, ["label"] = "***5678" }
                }
            });
            return Task.FromResult(0);
        });
        var coordinator = new ICloudCoordinator(bridge, "state", "stage");

        Assert.Equal(ICloudAuthStatus.NeedsTwoFactor,
            await coordinator.SignInAsync("first@example.com", "private-password", CancellationToken.None));
        Assert.True(coordinator.DeviceCodeAvailable);
        Assert.Equal([new ICloudTrustedPhone(7, "***1234"), new ICloudTrustedPhone(8, "***5678")], coordinator.TrustedPhones);

        Assert.Equal(ICloudAuthStatus.NeedsTwoFactor,
            await coordinator.SendCodeAsync("first@example.com", "private-password", 8, CancellationToken.None));
        Assert.Equal("send-code", requests[1]["command"]!.GetValue<string>());
        Assert.Equal(8, requests[1]["phone_id"]!.GetValue<int>());
        Assert.Null(requests[1]["code"]);

        await coordinator.VerifyTwoFactorAsync("first@example.com", "private-password", "123456", 8, CancellationToken.None);
        Assert.Equal(8, requests[2]["phone_id"]!.GetValue<int>());
        Assert.Equal("123456", requests[2]["code"]!.GetValue<string>());

        await coordinator.VerifyTwoFactorAsync("first@example.com", "private-password", "654321", CancellationToken.None);
        Assert.Null(requests[3]["phone_id"]);
    }

    [Fact]
    public async Task StatusRejectsMismatchedAccountUnknownStateAndFatalEvent()
    {
        var bridge = new FakeBridge((_, emit, _) =>
        {
            emit(new JsonObject { ["type"] = "auth", ["status"] = "signed_in", ["account"] = "other@example.com" });
            return Task.FromResult(0);
        });
        var coordinator = new ICloudCoordinator(bridge, "state", "stage");
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            coordinator.StatusAsync("first@example.com", CancellationToken.None));

        bridge.Run = (_, emit, _) =>
        {
            emit(new JsonObject { ["type"] = "auth", ["status"] = "unexpected", ["account"] = "first@example.com" });
            return Task.FromResult(0);
        };
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            coordinator.StatusAsync("first@example.com", CancellationToken.None));

        bridge.Run = (_, emit, _) =>
        {
            emit(new JsonObject { ["type"] = "fatal", ["kind"] = "session_unavailable", ["message"] = "private diagnostic" });
            emit(new JsonObject { ["type"] = "auth", ["status"] = "signed_in", ["account"] = "first@example.com" });
            return Task.FromResult(0);
        };
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            coordinator.StatusAsync("first@example.com", CancellationToken.None));
        Assert.DoesNotContain("private diagnostic", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task BackupRequiresDoneAndReportsExpiredSession()
    {
        var bridge = new FakeBridge((_, emit, _) =>
        {
            emit(new JsonObject { ["type"] = "progress", ["completed"] = 2, ["total"] = 5,
                ["uploaded"] = 1, ["existing"] = 1, ["failed"] = 0 });
            emit(new JsonObject { ["type"] = "done", ["uploaded"] = 3, ["existing"] = 1, ["failed"] = 1, ["pending"] = 2 });
            return Task.FromResult(0);
        });
        var coordinator = new ICloudCoordinator(bridge, "state", "stage");
        ICloudBackupProgress? progress = null;
        coordinator.ProgressChanged += value => progress = value;
        var result = await coordinator.BackupAsync("first@example.com", Credential(), CancellationToken.None);
        Assert.Equal(new ICloudBackupResult(3, 1, 1, 2), result);
        Assert.Equal(new ICloudBackupProgress(2, 5, 1, 1, 0), progress);

        bridge.Run = (_, emit, _) =>
        {
            emit(new JsonObject { ["type"] = "auth", ["status"] = "signed_out", ["account"] = "first@example.com" });
            return Task.FromResult(1);
        };
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            coordinator.BackupAsync("first@example.com", Credential(), CancellationToken.None));
        Assert.Contains("session expired", error.Message, StringComparison.OrdinalIgnoreCase);

        bridge.Run = (_, _, _) => Task.FromResult(0);
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            coordinator.BackupAsync("first@example.com", Credential(), CancellationToken.None));
    }

    [Fact]
    public async Task LibraryIndexingReportsRetryGuidanceWithoutPrivateDiagnostics()
    {
        var bridge = new FakeBridge((_, emit, _) =>
        {
            emit(new JsonObject { ["type"] = "fatal", ["kind"] = "icloud_unavailable", ["message"] = "private account details" });
            return Task.FromResult(3);
        });
        var coordinator = new ICloudCoordinator(bridge, "state", "stage");
        var status = await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.StatusAsync("first@example.com", CancellationToken.None));
        var backup = await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.BackupAsync("first@example.com", Credential(), CancellationToken.None));
        Assert.Contains("indexing", status.Message);
        Assert.Contains("retry", backup.Message);
        Assert.DoesNotContain("private account", status.Message + backup.Message);
    }

    private static string Credential() =>
        "Email=first%40gmail.com&Token=private&androidId=1234567890abcdef";

    private sealed class FakeBridge(Func<JsonObject, Action<JsonObject>, CancellationToken, Task<int>> run) : IBridgeClient
    {
        public Func<JsonObject, Action<JsonObject>, CancellationToken, Task<int>> Run { get; set; } = run;
        public Task<int> ExecuteAsync(JsonObject request, Action<JsonObject> onEvent, CancellationToken cancellationToken) =>
            Run(request, onEvent, cancellationToken);
    }
}
