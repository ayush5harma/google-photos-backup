using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace GooglePhotosBackup.Core;

public sealed class BridgeProcessClient(string pythonPath, string bridgePath) : IBridgeClient
{
    public async Task<int> ExecuteAsync(JsonObject request, Action<JsonObject> onEvent, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(onEvent);
        var start = new ProcessStartInfo(pythonPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false)
        };
        start.ArgumentList.Add("-I");
        start.ArgumentList.Add("-B");
        start.ArgumentList.Add(bridgePath);

        using var process = new Process { StartInfo = start };
        Task? stderr = null;
        var started = false;
        try
        {
            if (!process.Start()) throw new InvalidOperationException("The uploader could not start.");
            started = true;
            // 2026-10-15: The long-lived credential goes only through stdin;
            // argv, environment, and discarded stderr never carry it from us.
            stderr = process.StandardError.BaseStream.CopyToAsync(Stream.Null, CancellationToken.None);
            using var registration = cancellationToken.Register(() => Kill(process));
            await process.StandardInput.WriteLineAsync(request.ToJsonString().AsMemory(), cancellationToken);
            process.StandardInput.Close();
            string? line;
            while ((line = await process.StandardOutput.ReadLineAsync(cancellationToken)) is not null)
            {
                if (line.Length > 64 * 1024 || JsonNode.Parse(line) is not JsonObject message)
                    throw new InvalidOperationException("The uploader returned an invalid response.");
                onEvent(message);
            }
            await process.WaitForExitAsync(cancellationToken);
            await stderr;
            return process.ExitCode;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception error) when (error is not InvalidOperationException)
        {
            throw new InvalidOperationException("The uploader could not complete.");
        }
        finally
        {
            Kill(process);
            if (started)
            {
                // 2026-10-15: Wait for a canceled uploader to exit before a
                // new run can use the same account and source files.
                try { await process.WaitForExitAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(5)); }
                catch (TimeoutException) { }
                if (stderr is not null)
                {
                    try { await stderr.WaitAsync(TimeSpan.FromSeconds(5)); }
                    catch (TimeoutException) { }
                }
            }
        }
    }

    private static void Kill(Process process)
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (InvalidOperationException) { }
        catch (System.ComponentModel.Win32Exception) { }
    }
}
