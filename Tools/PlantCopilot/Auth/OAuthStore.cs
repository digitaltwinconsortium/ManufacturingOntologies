using System.Collections.Concurrent;

namespace PlantCopilot.Auth;

/// <summary>A client registered via RFC 7591 Dynamic Client Registration.</summary>
public sealed record RegisteredClient(
    string ClientId,
    string? ClientName,
    IReadOnlyList<string> RedirectUris,
    IReadOnlyList<string> GrantTypes,
    string TokenEndpointAuthMethod,
    DateTimeOffset IssuedAt);

/// <summary>A short-lived authorization code plus its PKCE challenge and requested context.</summary>
public sealed record AuthorizationCode(
    string Code,
    string ClientId,
    string RedirectUri,
    string CodeChallenge,
    string CodeChallengeMethod,
    string? Scope,
    string Subject,
    DateTimeOffset ExpiresAt);

/// <summary>
/// Thread-safe in-memory store for dynamically registered clients and pending authorization codes.
/// Adequate for a single-instance reference/demo deployment; state resets on restart.
/// </summary>
public sealed class OAuthStore
{
    private readonly ConcurrentDictionary<string, RegisteredClient> _clients = new();
    private readonly ConcurrentDictionary<string, AuthorizationCode> _codes = new();

    public RegisteredClient AddClient(RegisteredClient client)
    {
        _clients[client.ClientId] = client;
        return client;
    }

    public bool TryGetClient(string clientId, out RegisteredClient client) =>
        _clients.TryGetValue(clientId, out client!);

    public void AddCode(AuthorizationCode code) => _codes[code.Code] = code;

    /// <summary>Atomically fetch and remove a code so it can only be redeemed once.</summary>
    public bool TryConsumeCode(string code, out AuthorizationCode value) =>
        _codes.TryRemove(code, out value!);
}
