using System.Text.Json.Nodes;
using System.Threading.Channels;
using GooglePhotosBackup.Core;
using Xunit;

namespace GooglePhotosBackup.Core.Tests;

public sealed class BridgeSessionClientTests
{
    private const string Serve = "{\"command\":\"serve\"}";

    [Fact]
    public async Task OneBridgeServesEveryRequestOfARun()
    {
        var started = new List<FakeChannel>();
        var session = new BridgeSessionClient(() =>
        {
            var channel = new FakeChannel((self, request) =>
            {
                self.Emit(new JsonObject { ["type"] = "auth", ["n"] = request["n"]!.GetValue<int>() });
                self.Served(request["n"]!.GetValue<int>() == 2 ? 3 : 0);
            });
            started.Add(channel);
            return channel;
        });
        var seen = new List<int>();
        var codes = new List<int>();
        var startedBridge = new List<bool>();
        for (var n = 1; n <= 3; n++)
        {
            codes.Add(await session.ExecuteAsync(new JsonObject { ["command"] = "check-auth", ["n"] = n },
                message => seen.Add(message["n"]!.GetValue<int>()), CancellationToken.None));
            startedBridge.Add(session.LastRequestStartedBridge);
        }
        var channel = Assert.Single(started);
        Assert.Equal(Serve, channel.Input[0]);
        Assert.Equal(4, channel.Input.Count);
        Assert.Equal([1, 2, 3], seen);
        Assert.Equal([0, 3, 0], codes);
        Assert.Equal([true, false, false], startedBridge);
        Assert.False(channel.Killed);
        await session.DisposeAsync();
        Assert.True(channel.InputClosed);
        Assert.True(channel.Disposed);
    }

    [Fact]
    public async Task ADeadBridgeIsReplacedAtTheNextRequest()
    {
        var started = new List<FakeChannel>();
        var session = new BridgeSessionClient(() =>
        {
            var channel = new FakeChannel((self, _) =>
            {
                self.Emit(new JsonObject { ["type"] = "progress" });
                if (started.Count == 1) self.Die(3); else self.Served(0);
            });
            started.Add(channel);
            return channel;
        });
        var events = 0;
        Assert.Equal(3, await session.ExecuteAsync(new JsonObject { ["command"] = "upload" }, _ => events++, CancellationToken.None));
        Assert.True(started[0].Disposed);
        Assert.Equal(0, await session.ExecuteAsync(new JsonObject { ["command"] = "upload" }, _ => events++, CancellationToken.None));
        Assert.True(session.LastRequestStartedBridge);
        Assert.Equal(2, started.Count);
        Assert.Equal(Serve, started[1].Input[0]);
        Assert.Equal(2, events);
    }

    [Fact]
    public async Task StopKillsTheBridgeAndTheNextRequestStartsAnother()
    {
        var started = new List<FakeChannel>();
        var session = new BridgeSessionClient(() =>
        {
            var channel = new FakeChannel((self, request) =>
            {
                self.Emit(new JsonObject { ["type"] = "progress" });
                if (request["command"]!.GetValue<string>() == "version") self.Served(0);
            });
            started.Add(channel);
            return channel;
        });
        using var stop = new CancellationTokenSource();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => session.ExecuteAsync(
            new JsonObject { ["command"] = "upload" }, _ => stop.Cancel(), stop.Token));
        Assert.True(started[0].Killed);
        Assert.True(started[0].Disposed);
        Assert.Equal(0, await session.ExecuteAsync(new JsonObject { ["command"] = "version" }, _ => { }, CancellationToken.None));
        Assert.Equal(2, started.Count);
    }

    [Fact]
    public async Task AStoppedAnswerEndsTheSession()
    {
        var started = new List<FakeChannel>();
        var session = new BridgeSessionClient(() =>
        {
            var channel = new FakeChannel((self, _) => self.Served(5));
            started.Add(channel);
            return channel;
        });
        Assert.Equal(5, await session.ExecuteAsync(new JsonObject { ["command"] = "upload" }, _ => { }, CancellationToken.None));
        Assert.True(started[0].Killed);
        await session.ExecuteAsync(new JsonObject { ["command"] = "upload" }, _ => { }, CancellationToken.None);
        Assert.Equal(2, started.Count);
    }

    [Fact]
    public async Task AnObserverThatThrowsLeavesNoEventsForTheNextRequest()
    {
        var started = new List<FakeChannel>();
        var session = new BridgeSessionClient(() =>
        {
            var channel = new FakeChannel((self, request) =>
            {
                var command = request["command"]!.GetValue<string>();
                self.Emit(new JsonObject { ["type"] = "item", ["for"] = command });
                self.Emit(new JsonObject { ["type"] = "item", ["for"] = command });
                self.Served(0);
            });
            started.Add(channel);
            return channel;
        });
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.ExecuteAsync(new JsonObject { ["command"] = "first" },
            _ => throw new InvalidOperationException("Backup history could not be saved."), CancellationToken.None));
        var seen = new List<string>();
        await session.ExecuteAsync(new JsonObject { ["command"] = "second" }, message => seen.Add(message["for"]!.GetValue<string>()),
            CancellationToken.None);
        Assert.Equal(["second", "second"], seen);
        Assert.Equal(2, started.Count);
    }

    [Fact]
    public async Task AnInvalidLineEndsTheBridge()
    {
        var started = new List<FakeChannel>();
        var session = new BridgeSessionClient(() =>
        {
            var channel = new FakeChannel((self, _) => self.EmitRaw("not json"));
            started.Add(channel);
            return channel;
        });
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.ExecuteAsync(new JsonObject { ["command"] = "upload" },
            _ => { }, CancellationToken.None));
        Assert.True(started[0].Killed);
    }

    /// <summary>The real bridge script and Python, when this machine has a Python on PATH (Windows CI does):
    /// proves the process plumbing (no BOM on stdin, a flushed line per request, `served` read) end to end.</summary>
    [Fact]
    public async Task TheRealBridgeAnswersTwoRequestsFromOneProcess()
    {
        var python = FindPython();
        var bridge = FindBridgeScript();
        if (python is null || bridge is null) return;
        await using var session = new BridgeSessionClient(python, bridge);
        var versions = new List<int>();
        for (var i = 0; i < 2; i++)
        {
            var code = await session.ExecuteAsync(new JsonObject { ["command"] = "version" }, message =>
            {
                if (message["type"]!.GetValue<string>() == "version") versions.Add(message["protocol"]!.GetValue<int>());
            }, CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(60));
            Assert.Equal(0, code);
            Assert.Equal(i == 0, session.LastRequestStartedBridge);
        }
        Assert.Equal([1, 1], versions);
    }

    private static string? FindPython()
    {
        var names = OperatingSystem.IsWindows() ? new[] { "python.exe", "python3.exe" } : ["python3", "python"];
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            // The WindowsApps python.exe is a Store alias, not an interpreter.
            if (directory.Length == 0 || directory.Contains("WindowsApps", StringComparison.OrdinalIgnoreCase)) continue;
            foreach (var name in names)
            {
                var candidate = Path.Combine(directory, name);
                if (File.Exists(candidate)) return candidate;
            }
        }
        return null;
    }

    private static string? FindBridgeScript()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, "Bridge", "gpmc_bridge.py");
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    /// <summary>A serve-mode bridge in memory: the first line must be serve, each later line is a request.</summary>
    private sealed class FakeChannel(Action<FakeChannel, JsonObject> onRequest) : IBridgeChannel
    {
        private readonly Channel<string> _output = Channel.CreateUnbounded<string>();
        private int _exitCode;

        public List<string> Input { get; } = [];
        public bool HasExited { get; private set; }
        public bool Killed { get; private set; }
        public bool Disposed { get; private set; }
        public bool InputClosed { get; private set; }

        public Task WriteLineAsync(string line, CancellationToken cancellationToken)
        {
            if (HasExited) throw new IOException("The pipe has been ended.");
            Input.Add(line);
            if (Input.Count == 1) Assert.Equal(Serve, line);
            else onRequest(this, JsonNode.Parse(line)!.AsObject());
            return Task.CompletedTask;
        }

        public async Task<string?> ReadLineAsync(CancellationToken cancellationToken)
        {
            try { return await _output.Reader.ReadAsync(cancellationToken); }
            catch (ChannelClosedException) { return null; }
        }

        public void Emit(JsonObject message) => EmitRaw(message.ToJsonString());
        public void EmitRaw(string line) => _output.Writer.TryWrite(line);
        public void Served(int code) => Emit(new JsonObject { ["type"] = "served", ["v"] = 1, ["code"] = code });

        public void Die(int code)
        {
            _exitCode = code;
            HasExited = true;
            _output.Writer.TryComplete();
        }

        public void CloseInput()
        {
            InputClosed = true;
            Die(0);
        }

        public void Kill()
        {
            Killed = true;
            if (!HasExited) Die(-1);
        }

        public Task<int> WaitForExitAsync(TimeSpan timeout) => Task.FromResult(_exitCode);
        public void Dispose() => Disposed = true;
    }
}
