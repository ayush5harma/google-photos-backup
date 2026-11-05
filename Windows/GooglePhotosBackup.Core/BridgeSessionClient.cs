using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace GooglePhotosBackup.Core;

/// <summary>A started bridge process as the session sees it: one line in, one line out.</summary>
public interface IBridgeChannel : IDisposable
{
    bool HasExited { get; }
    Task WriteLineAsync(string line, CancellationToken cancellationToken);
    /// <summary>The next stdout line, or null once stdout has ended.</summary>
    Task<string?> ReadLineAsync(CancellationToken cancellationToken);
    /// <summary>End of input: a serve session then exits by itself.</summary>
    void CloseInput();
    void Kill();
    Task<int> WaitForExitAsync(TimeSpan timeout);
}

/// <summary>
/// One bridge process for a whole backup run (issue #58, the Windows side of the Mac's BridgeSession in
/// Sources/PhotosBackup/GPMCBridge.swift). The first line is {"command":"serve"}; every request is then one line,
/// answered by the events a one-shot bridge would emit and a final `served` carrying that bridge's exit status.
/// The run pays Python's start-up, the Google sign-in and new connections once instead of for every batch, and
/// the bridge keeps its HTTP sessions only in a serve session. A bridge that died is replaced at the next request;
/// cancelling a request (Stop) kills the bridge.
/// </summary>
public sealed class BridgeSessionClient(Func<IBridgeChannel> start) : IBridgeClient, IAsyncDisposable
{
    private const int StoppedStatus = 5;
    private const int MaximumLine = 64 * 1024;
    private const string ServeLine = "{\"command\":\"serve\"}";
    private static readonly TimeSpan ExitWait = TimeSpan.FromSeconds(5);
    private readonly SemaphoreSlim _oneAtATime = new(1, 1);
    private readonly object _gate = new();
    private IBridgeChannel? _channel;

    public BridgeSessionClient(string pythonPath, string bridgePath)
        : this(() => new ProcessBridgeChannel(pythonPath, bridgePath)) { }

    /// <summary>The last request started the bridge, so its time includes start-up and sign-in.</summary>
    public bool LastRequestStartedBridge { get; private set; }

    /// <summary>One request at a time: two would read each other's events from the one stdout, and an item's
    /// media key could be recorded for another.</summary>
    public async Task<int> ExecuteAsync(JsonObject request, Action<JsonObject> onEvent, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(onEvent);
        await _oneAtATime.WaitAsync(cancellationToken).ConfigureAwait(false);
        var answered = false;
        try
        {
            var (channel, started) = await RunningAsync().ConfigureAwait(false);
            LastRequestStartedBridge = started;
            // Stop: kill at once (the read below then ends); the bridge is disposed on the way out.
            using var registration = cancellationToken.Register(channel.Kill);
            try
            {
                await channel.WriteLineAsync(request.ToJsonString(), cancellationToken).ConfigureAwait(false);
            }
            catch (IOException)
            {
                // It died before reading the request: its stdout ends below and the exit status answers.
            }
            string? line;
            while ((line = await channel.ReadLineAsync(cancellationToken).ConfigureAwait(false)) is not null)
            {
                if (line.Length > MaximumLine || JsonNode.Parse(line) is not JsonObject message)
                    throw new InvalidOperationException("The uploader returned an invalid response.");
                if (message["type"] is JsonValue type && type.TryGetValue<string>(out var kind) && kind == "served")
                {
                    answered = true;
                    var code = message["code"] is JsonValue value && value.TryGetValue<int>(out var number) ? number : 1;
                    if (code == StoppedStatus) Forget();
                    return code;
                }
                onEvent(message);
            }
            // Its output ended before the answer did: the bridge died. What it reported is in; the next request
            // starts a new bridge.
            answered = true;
            var exit = await channel.WaitForExitAsync(ExitWait).ConfigureAwait(false);
            Forget();
            return exit;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception) when (cancellationToken.IsCancellationRequested)
        {
            // The kill broke the read or the write; that is the stop, not a failure.
            throw new OperationCanceledException(cancellationToken);
        }
        catch (Exception error) when (error is not InvalidOperationException)
        {
            throw new InvalidOperationException("The uploader could not complete.");
        }
        finally
        {
            // Left mid-answer (a stop, a bad line, an observer that threw): the rest of this request's events
            // must never be read as the next request's, so this bridge goes.
            if (!answered) Forget();
            _oneAtATime.Release();
        }
    }

    /// <summary>The run is over: the bridge reads end of input and exits by itself, closing its connections.</summary>
    public async ValueTask DisposeAsync()
    {
        IBridgeChannel? channel;
        lock (_gate) { channel = _channel; _channel = null; }
        if (channel is null) return;
        try
        {
            channel.CloseInput();
            await channel.WaitForExitAsync(ExitWait).ConfigureAwait(false);
        }
        catch (Exception error) when (error is IOException or InvalidOperationException) { }
        finally
        {
            channel.Kill();
            channel.Dispose();
        }
    }

    private async Task<(IBridgeChannel Channel, bool Started)> RunningAsync()
    {
        lock (_gate)
        {
            if (_channel is { HasExited: false } live) return (live, false);
        }
        Forget();
        var channel = start();
        lock (_gate) _channel = channel;
        try
        {
            await channel.WriteLineAsync(ServeLine, CancellationToken.None).ConfigureAwait(false);
        }
        catch (IOException)
        {
            // Dead at once: the request's read ends and reports its exit status.
        }
        return (channel, true);
    }

    /// <summary>Kill the bridge, if any, and start a new one at the next request.</summary>
    private void Forget()
    {
        IBridgeChannel? channel;
        lock (_gate) { channel = _channel; _channel = null; }
        if (channel is null) return;
        channel.Kill();
        channel.Dispose();
    }
}

/// <summary>The bundled Python running Bridge/gpmc_bridge.py, with stdin and stdout as the protocol.</summary>
public sealed class ProcessBridgeChannel : IBridgeChannel
{
    private readonly Process _process;
    private readonly Task _stderr;

    public ProcessBridgeChannel(string pythonPath, string bridgePath)
    {
        _process = new Process { StartInfo = BridgeProcessClient.StartInfo(pythonPath, bridgePath) };
        if (!_process.Start())
        {
            _process.Dispose();
            throw new InvalidOperationException("The uploader could not start.");
        }
        // 2026-10-15: The long-lived credential goes only through stdin; argv, environment, and discarded stderr
        // never carry it from us.
        _stderr = _process.StandardError.BaseStream.CopyToAsync(Stream.Null, CancellationToken.None);
    }

    public bool HasExited
    {
        get
        {
            try { return _process.HasExited; }
            catch (InvalidOperationException) { return true; }
        }
    }

    public async Task WriteLineAsync(string line, CancellationToken cancellationToken)
    {
        await _process.StandardInput.WriteLineAsync(line.AsMemory(), cancellationToken).ConfigureAwait(false);
        await _process.StandardInput.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task<string?> ReadLineAsync(CancellationToken cancellationToken) =>
        await _process.StandardOutput.ReadLineAsync(cancellationToken).ConfigureAwait(false);

    public void CloseInput()
    {
        try { _process.StandardInput.Close(); }
        catch (IOException) { }
    }

    public void Kill() => BridgeProcessClient.Kill(_process);

    public async Task<int> WaitForExitAsync(TimeSpan timeout)
    {
        try
        {
            await _process.WaitForExitAsync(CancellationToken.None).WaitAsync(timeout).ConfigureAwait(false);
            return _process.ExitCode;
        }
        catch (TimeoutException)
        {
            Kill();
            return 1;
        }
    }

    public void Dispose()
    {
        Kill();
        // 2026-10-15: Wait for a killed uploader to exit before a new run can use the same account and source
        // files.
        try { _process.WaitForExit(ExitWait); }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        try { _stderr.Wait(ExitWait); }
        catch (AggregateException) { }
        _process.Dispose();
    }

    private static readonly TimeSpan ExitWait = TimeSpan.FromSeconds(5);
}
