using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace GooglePhotosBackup.Core;

public static class GoogleSignIn
{
    public const string EmbeddedSetupUrl = "https://accounts.google.com/EmbeddedSetup";
    private const string CookieName = "oauth_token";
    private const string EmailHint = "oauth-token@example.com";
    private const string PlayServicesSignature = "38918a453d07199354f8b19af05ec6562ced5788";
    private const string PhotosPackage = "com.google.android.apps.photos";
    private const string PhotosSignature = "24bb24c05e47e0aefa68a58a766179d9b613a600";
    private const string PhotosService = "oauth2:openid https://www.googleapis.com/auth/mobileapps.native https://www.googleapis.com/auth/photos.native";
    private const string PlayServicesVersion = "240913000";
    private static readonly string[] Endpoints = ["https://android.clients.google.com/auth", "https://android.googleapis.com/auth"];

    public static async Task<string> ExchangeAsync(string oauthToken, HttpClient http, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(http);
        var token = oauthToken.Trim();
        if (token.StartsWith(CookieName + "=", StringComparison.Ordinal)) token = token[(CookieName.Length + 1)..];
        if (token.Length is < 16 or > 8192 || token.Any(character => character is '\r' or '\n'))
            throw new InvalidOperationException("That is not an oauth_token cookie from Google's sign-in page.");

        var androidId = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(8));
        var form = Form(new Dictionary<string, string>
        {
            ["accountType"] = "HOSTED_OR_GOOGLE", ["Email"] = EmailHint, ["has_permission"] = "1", ["add_account"] = "1",
            ["ACCESS_TOKEN"] = "1", ["Token"] = token, ["service"] = "ac2dm", ["source"] = "android",
            ["androidId"] = androidId, ["device_country"] = "us", ["operatorCountry"] = "us", ["lang"] = "en",
            ["sdk_version"] = "17", ["google_play_services_version"] = PlayServicesVersion,
            ["client_sig"] = PlayServicesSignature, ["callerSig"] = PlayServicesSignature, ["droidguard_results"] = "dummy123"
        });
        for (var index = 0; index < Endpoints.Length; index++)
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, Endpoints[index]);
            request.Content = new ByteArrayContent(Encoding.UTF8.GetBytes(form));
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/x-www-form-urlencoded");
            request.Headers.TryAddWithoutValidation("User-Agent", "GoogleAuth/1.4");
            request.Headers.TryAddWithoutValidation("Accept-Encoding", "identity");
            try
            {
                using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
                var body = await ReadLimitedAsync(response.Content, ct);
                var values = ParseFields(body);
                if (values.TryGetValue("Error", out var error))
                    throw new InvalidOperationException(error switch
                    {
                        "BadAuthentication" => "Google did not accept the sign-in. Sign in again; each sign-in works only once.",
                        "NeedsBrowser" => "Google wants the sign-in finished in a browser. Sign in again.",
                        "MissingDroidguard" => "Google refused the device check for this sign-in.",
                        _ => "Google refused the sign-in."
                    });
                if (!values.TryGetValue("Token", out var masterToken) || string.IsNullOrEmpty(masterToken))
                    throw new InvalidOperationException("Google's answer held no account token.");
                if (!values.TryGetValue("Email", out var email) || !PlausibleEmail(email))
                    throw new InvalidOperationException("Google's answer held no account address.");
                return Form(new Dictionary<string, string>
                {
                    ["androidId"] = androidId, ["app"] = PhotosPackage, ["callerPkg"] = PhotosPackage,
                    ["callerSig"] = PhotosSignature, ["client_sig"] = PhotosSignature, ["device_country"] = "us",
                    ["Email"] = email, ["google_play_services_version"] = PlayServicesVersion, ["lang"] = "en_US",
                    ["oauth2_foreground"] = "1", ["operatorCountry"] = "us", ["sdk_version"] = "33",
                    ["service"] = PhotosService, ["source"] = "android", ["Token"] = masterToken
                });
            }
            catch (HttpRequestException error) when (index == 0 && IsUnsentConnectionFailure(error))
            {
                // 2026-10-15: Only a socket failure before sending can reuse
                // Google's single-use cookie at the second endpoint.
            }
            catch (HttpRequestException)
            {
                throw new InvalidOperationException("Google's sign-in service could not be reached.");
            }
        }
        throw new InvalidOperationException("Google's sign-in service could not be reached.");
    }

    public static string? Email(string authData)
    {
        foreach (var pair in authData.Split('&'))
        {
            var separator = pair.IndexOf('=');
            if (separator < 0 || !pair.AsSpan(0, separator).SequenceEqual("Email")) continue;
            var address = WebUtility.UrlDecode(pair[(separator + 1)..]);
            return PlausibleEmail(address) ? address : null;
        }
        return null;
    }

    internal static string CanonicalEmail(string email)
    {
        var lowered = email.Trim().ToLowerInvariant();
        var at = lowered.LastIndexOf('@');
        if (at < 0) return lowered;
        var domain = lowered[(at + 1)..];
        return domain is "gmail.com" or "googlemail.com"
            ? lowered[..at].Replace(".", "", StringComparison.Ordinal) + "@gmail.com"
            : lowered;
    }

    private static bool PlausibleEmail(string value)
    {
        var at = value.IndexOf('@');
        return at > 0 && at == value.LastIndexOf('@') && at < value.Length - 1
            && value[(at + 1)..].Contains('.') && !value.Any(char.IsWhiteSpace);
    }

    private static bool IsUnsentConnectionFailure(HttpRequestException error) =>
        error.InnerException is SocketException socket && socket.SocketErrorCode is
            SocketError.HostNotFound or SocketError.TryAgain or SocketError.NetworkUnreachable or SocketError.ConnectionRefused;

    private static string Form(Dictionary<string, string> fields) => string.Join("&",
        fields.OrderBy(field => field.Key, StringComparer.Ordinal)
            .Select(field => $"{Uri.EscapeDataString(field.Key)}={Uri.EscapeDataString(field.Value).Replace("%20", "+", StringComparison.Ordinal)}"));

    private static Dictionary<string, string> ParseFields(string body)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in body.Split('\n'))
        {
            var trimmed = line.Trim();
            var separator = trimmed.IndexOf('=');
            if (separator > 0) values[trimmed[..separator]] = trimmed[(separator + 1)..];
        }
        return values;
    }

    private static async Task<string> ReadLimitedAsync(HttpContent content, CancellationToken ct)
    {
        await using var stream = await content.ReadAsStreamAsync(ct);
        var buffer = new byte[64 * 1024];
        var read = 0;
        while (read < buffer.Length)
        {
            var count = await stream.ReadAsync(buffer.AsMemory(read), ct);
            if (count == 0) break;
            read += count;
        }
        return Encoding.UTF8.GetString(buffer, 0, read);
    }
}
