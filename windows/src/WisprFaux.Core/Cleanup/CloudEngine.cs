using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace WisprFaux.Core.Cleanup;

/// <summary>
/// A cloud model reachable through the common "chat completions" API that DeepSeek, Z.ai (GLM),
/// Moonshot (Kimi) and others all speak.
/// </summary>
public sealed record CloudProvider(
    string Id,
    string DisplayName,
    // Ends before /chat/completions.
    string BaseUrl,
    string Model,
    // Extra JSON fields for this provider, e.g. turning off GLM's reasoning step.
    IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> ExtraFields,
    // Where to create an API key.
    string KeysUrl,
    string CostNote)
{
    static readonly IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> None =
        new Dictionary<string, IReadOnlyDictionary<string, string>>();

    /// <summary>Z.ai's GLM-4.7-Flash: free with an account (about one request per second).</summary>
    public static readonly CloudProvider GlmFlash = new(
        "zai-glm-4.7-flash",
        "GLM-4.7-Flash (Z.ai)",
        "https://api.z.ai/api/paas/v4",
        "glm-4.7-flash",
        new Dictionary<string, IReadOnlyDictionary<string, string>> { ["thinking"] = new Dictionary<string, string> { ["type"] = "disabled" } },
        "https://z.ai",
        "Free");

    /// <summary>DeepSeek's chat model: pay-as-you-go, about a hundredth of a cent per cleanup.</summary>
    public static readonly CloudProvider DeepSeek = new(
        "deepseek-chat",
        "DeepSeek",
        "https://api.deepseek.com",
        "deepseek-chat",
        None,
        "https://platform.deepseek.com",
        "Paid, about $0.0001 per cleanup");

    public static readonly IReadOnlyList<CloudProvider> All = new[] { GlmFlash, DeepSeek };

    public static CloudProvider? Named(string? id) => All.FirstOrDefault(p => p.Id == id);
}

/// <summary>Cleanup through a <see cref="CloudProvider"/>. Sends only the cleanup prompt and the transcript.</summary>
public sealed class CloudEngine : ICleanupEngine
{
    static readonly HttpClient SharedClient = new() { Timeout = TimeSpan.FromSeconds(10) };

    public CloudProvider Provider { get; }
    readonly string _apiKey;
    readonly HttpClient _client;

    public CloudEngine(CloudProvider provider, string apiKey, HttpClient? client = null)
    {
        Provider = provider;
        _apiKey = apiKey;
        _client = client ?? SharedClient;
    }

    public string Name => Provider.DisplayName;

    public async Task<string> CompleteAsync(
        string instructions,
        IReadOnlyList<(string Dictated, string Cleaned)> examples,
        string text,
        int maxTokens,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, Provider.BaseUrl.TrimEnd('/') + "/chat/completions");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);
        request.Content = new StringContent(RequestBody(Provider, instructions, examples, text, maxTokens), Encoding.UTF8, "application/json");

        using var response = await _client.SendAsync(request, cancellationToken).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        if ((int)response.StatusCode != 200)
            throw new CloudException($"HTTP {(int)response.StatusCode}: {ErrorMessage(body)}");
        return Reply(body);
    }

    internal static string RequestBody(
        CloudProvider provider,
        string instructions,
        IReadOnlyList<(string Dictated, string Cleaned)> examples,
        string text,
        int maxTokens)
    {
        var messages = new JsonArray { new JsonObject { ["role"] = "system", ["content"] = instructions } };
        foreach (var (dictated, cleaned) in examples)
        {
            messages.Add(new JsonObject { ["role"] = "user", ["content"] = dictated });
            messages.Add(new JsonObject { ["role"] = "assistant", ["content"] = cleaned });
        }
        messages.Add(new JsonObject { ["role"] = "user", ["content"] = text });

        var body = new JsonObject
        {
            ["model"] = provider.Model,
            ["messages"] = messages,
            ["temperature"] = 0,
            ["max_tokens"] = maxTokens,
            ["stream"] = false,
        };
        foreach (var (key, fields) in provider.ExtraFields)
        {
            var obj = new JsonObject();
            foreach (var (k, v) in fields) obj[k] = v;
            body[key] = obj;
        }
        return body.ToJsonString();
    }

    internal static string Reply(string json)
    {
        try
        {
            var root = JsonNode.Parse(json);
            var content = root?["choices"]?[0]?["message"]?["content"]?.GetValue<string>();
            if (content is not null) return content;
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException) { }
        throw new CloudException("The reply couldn't be read.");
    }

    internal static string ErrorMessage(string body)
    {
        try
        {
            var root = JsonNode.Parse(body);
            if (root?["error"]?["message"]?.GetValue<string>() is { } m) return m;
            if (root?["message"]?.GetValue<string>() is { } m2) return m2;
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException) { }
        return body.Length > 200 ? body[..200] : body;
    }
}

public sealed class CloudException(string message) : Exception(message);
