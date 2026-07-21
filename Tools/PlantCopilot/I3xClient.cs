using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace PlantCopilot;

/// <summary>
/// Thin, read-only client for the i3X REST API exposed by the reference solution's I3X4Kusto adapter
/// (which sits in front of Azure Data Explorer or a Microsoft Fabric Eventhouse). Every method returns the
/// raw JSON response as a string so the MCP tools can hand the grounded data straight to the agent.
///
/// Configuration (environment variables):
///   I3X_BASE_URL  - base URL of the I3X API, e.g. https://&lt;resourcesName&gt;-i3x4kusto.&lt;region&gt;.azurecontainerapps.io
///   I3X_USERNAME  - HTTP Basic auth user (the deployment's adminUsername, default 'admin')
///   I3X_PASSWORD  - HTTP Basic auth password (the deployment's adminPassword)
/// </summary>
public sealed class I3xClient
{
    private readonly HttpClient _http;

    public I3xClient(HttpClient http)
    {
        _http = http;

        string baseUrl = (Environment.GetEnvironmentVariable("I3X_BASE_URL") ?? "http://localhost:8080").TrimEnd('/');
        _http.BaseAddress = new Uri(baseUrl + "/");
        _http.Timeout = TimeSpan.FromSeconds(60);

        string? user = Environment.GetEnvironmentVariable("I3X_USERNAME");
        string? pass = Environment.GetEnvironmentVariable("I3X_PASSWORD");
        if (!string.IsNullOrEmpty(user) && !string.IsNullOrEmpty(pass))
        {
            string token = Convert.ToBase64String(Encoding.UTF8.GetBytes($"{user}:{pass}"));
            _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Basic", token);
        }

        _http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
    }

    // ---- GET endpoints ----

    /// <summary>GET /v1/info - server version and capabilities (health check).</summary>
    public Task<string> GetInfoAsync(CancellationToken ct) => GetAsync("v1/info", ct);

    /// <summary>GET /v1/namespaces - all OPC UA namespaces available in the data.</summary>
    public Task<string> GetNamespacesAsync(CancellationToken ct) => GetAsync("v1/namespaces", ct);

    /// <summary>GET /v1/objecttypes[?namespaceUri=] - object/variable types, optionally scoped to a namespace.</summary>
    public Task<string> GetObjectTypesAsync(string? namespaceUri, CancellationToken ct)
    {
        string path = "v1/objecttypes";
        if (!string.IsNullOrWhiteSpace(namespaceUri))
        {
            path += "?namespaceUri=" + Uri.EscapeDataString(namespaceUri);
        }
        return GetAsync(path, ct);
    }

    /// <summary>
    /// GET /v1/objects with optional filters. root=true returns the top of the ISA-95 hierarchy;
    /// typeElementId returns the objects of a given type; includeMetadata adds type/namespace metadata.
    /// </summary>
    public Task<string> GetObjectsAsync(bool? root, string? typeElementId, bool includeMetadata, CancellationToken ct)
    {
        var query = new List<string>();
        if (root == true) query.Add("root=true");
        if (!string.IsNullOrWhiteSpace(typeElementId)) query.Add("typeElementId=" + Uri.EscapeDataString(typeElementId));
        if (includeMetadata) query.Add("includeMetadata=true");
        string path = "v1/objects" + (query.Count > 0 ? "?" + string.Join("&", query) : string.Empty);
        return GetAsync(path, ct);
    }

    // ---- POST endpoints (bulk, keyed by elementIds) ----

    /// <summary>POST /v1/objects/related - the related objects (children/parent) of the given elements.</summary>
    public Task<string> GetRelatedAsync(string[] elementIds, string? relationshipType, bool includeMetadata, CancellationToken ct)
    {
        var body = new Dictionary<string, object?>
        {
            ["elementIds"] = elementIds,
            ["includeMetadata"] = includeMetadata,
        };
        if (!string.IsNullOrWhiteSpace(relationshipType)) body["relationshipType"] = relationshipType;
        return PostAsync("v1/objects/related", body, ct);
    }

    /// <summary>POST /v1/objects/value - the latest value(s) for the given element(s).</summary>
    public Task<string> GetValueAsync(string[] elementIds, CancellationToken ct)
        => PostAsync("v1/objects/value", new Dictionary<string, object?> { ["elementIds"] = elementIds }, ct);

    /// <summary>POST /v1/objects/history - the historical values for the given element(s) over a time range.</summary>
    public Task<string> GetHistoryAsync(string[] elementIds, string? startTime, string? endTime, CancellationToken ct)
    {
        var body = new Dictionary<string, object?> { ["elementIds"] = elementIds };
        if (!string.IsNullOrWhiteSpace(startTime)) body["startTime"] = startTime;
        if (!string.IsNullOrWhiteSpace(endTime)) body["endTime"] = endTime;
        return PostAsync("v1/objects/history", body, ct);
    }

    // ---- helpers ----

    private async Task<string> GetAsync(string path, CancellationToken ct)
    {
        using var resp = await _http.GetAsync(path, ct).ConfigureAwait(false);
        return await ReadAsync(resp, ct).ConfigureAwait(false);
    }

    private async Task<string> PostAsync(string path, object body, CancellationToken ct)
    {
        string json = JsonSerializer.Serialize(body);
        using var content = new StringContent(json, Encoding.UTF8, "application/json");
        using var resp = await _http.PostAsync(path, content, ct).ConfigureAwait(false);
        return await ReadAsync(resp, ct).ConfigureAwait(false);
    }

    private static async Task<string> ReadAsync(HttpResponseMessage resp, CancellationToken ct)
    {
        string text = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
        {
            return $"{{\"error\":\"I3X request failed with HTTP {(int)resp.StatusCode} {resp.StatusCode}\",\"detail\":{JsonSerializer.Serialize(text)}}}";
        }
        return string.IsNullOrWhiteSpace(text) ? "{}" : text;
    }
}
