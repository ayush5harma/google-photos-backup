using System.Text.RegularExpressions;

namespace GooglePhotosBackup.Core;

/// <summary>What a failed item calls for, decided from Google's answer.</summary>
public enum FailureClass
{
    /// <summary>HTTP 429: Google asked the app to slow down.</summary>
    RateLimited,
    /// <summary>The network or Google itself had trouble; the same request may work.</summary>
    Retryable,
    /// <summary>The file or the request is the problem; sending it again cannot help.</summary>
    Permanent
}

/// <summary>
/// Reads a failure message as gpmc words it, the same rules as the Mac's FailureClassifier
/// (Sources/PhotosBackupCore/RetryPolicy.swift) and the bridge's _is_retryable_failure: gpmc keeps only the text of
/// a per-file error, so the text is all either side has.
/// </summary>
public static partial class FailureClassifier
{
    private static readonly string[] NetworkMarkers =
    [
        "timed out", "timeout", "connection reset", "connection aborted", "connection refused", "connectionerror",
        "remotedisconnected", "max retries exceeded", "newconnectionerror", "nameresolutionerror", "name resolution",
        "network is unreachable", "no route to host", "broken pipe", "temporarily unavailable", "eof occurred",
        "no answer from the uploader"
    ];

    public static FailureClass Classify(string? message, bool? bridgeRetryable)
    {
        message ??= "";
        if (StatusCode(message) is { } status)
        {
            if (status == 429) return FailureClass.RateLimited;
            if (status == 408 || status >= 500) return FailureClass.Retryable;
            if (status >= 400) return FailureClass.Permanent;
        }
        var lowered = message.ToLowerInvariant();
        if (lowered.Contains("too many requests", StringComparison.Ordinal)) return FailureClass.RateLimited;
        if (NetworkMarkers.Any(marker => lowered.Contains(marker, StringComparison.Ordinal))) return FailureClass.Retryable;
        return bridgeRetryable == true ? FailureClass.Retryable : FailureClass.Permanent;
    }

    /// <summary>The HTTP status a message names, or null. Only the phrasings requests, urllib3 and the bridge use
    /// count, so a number inside a URL or an upload id is never read as a status.</summary>
    public static int? StatusCode(string message)
    {
        foreach (var pattern in (Regex[])[ClientServerError(), TooManyErrorResponses(), HttpStatus(), StatusWord()])
        {
            var match = pattern.Match(message);
            if (match.Success) return int.Parse(match.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
        }
        return null;
    }

    [GeneratedRegex(@"\b([1-5][0-9]{2}) (?:Client|Server) Error\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex ClientServerError();
    [GeneratedRegex(@"too many ([1-5][0-9]{2}) error responses", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex TooManyErrorResponses();
    [GeneratedRegex(@"\bHTTP(?: Error)?:? ([1-5][0-9]{2})\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex HttpStatus();
    [GeneratedRegex(@"\bstatus(?: code)?:? ([1-5][0-9]{2})\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex StatusWord();
}
