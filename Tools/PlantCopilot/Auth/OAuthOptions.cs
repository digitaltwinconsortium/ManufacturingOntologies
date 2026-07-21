using System.Security.Cryptography;
using Microsoft.IdentityModel.Tokens;

namespace PlantCopilot.Auth;

/// <summary>
/// Configuration for the optional OAuth 2.0 authorization layer of the Plant Copilot MCP server.
///
/// The server can act as a self-contained OAuth 2.0 Authorization Server (AS) and Resource Server (RS):
///   - As an AS it exposes RFC 8414 metadata, RFC 7591 Dynamic Client Registration, an authorization
///     endpoint (authorization code + PKCE) and a token endpoint that issues signed RS256 JWTs.
///   - As an RS it validates those JWTs on the protected <c>/mcp</c> endpoint and advertises the AS via
///     RFC 9728 protected-resource metadata.
///
/// Environment variables:
///   AUTH_ENABLED   - set to "false" to leave /mcp open; OAuth (incl. Dynamic Client Registration)
///                    is enabled by default (any other value, or unset, keeps it on).
///   AUTH_ISSUER    - public base URL of this server, e.g. https://&lt;fqdn&gt; (used as issuer/audience
///                    and to build discovery URLs). Falls back to the incoming request's base URL.
///   AUTH_TOKEN_LIFETIME_MINUTES - access-token lifetime in minutes (default: 60).
/// </summary>
public sealed class OAuthOptions
{
    public bool Enabled { get; init; }

    /// <summary>Configured public issuer, or null to derive it from the incoming request.</summary>
    public string? Issuer { get; init; }

    public int TokenLifetimeMinutes { get; init; } = 60;

    /// <summary>In-process RSA signing key used to sign and validate access tokens.</summary>
    public RsaSecurityKey SigningKey { get; }

    public string KeyId { get; }

    public OAuthOptions()
    {
        var rsa = RSA.Create(2048);
        SigningKey = new RsaSecurityKey(rsa) { KeyId = Guid.NewGuid().ToString("N") };
        KeyId = SigningKey.KeyId;
    }

    public static OAuthOptions FromEnvironment()
    {
        bool enabled = !string.Equals(
            Environment.GetEnvironmentVariable("AUTH_ENABLED"), "false", StringComparison.OrdinalIgnoreCase);

        string? issuer = Environment.GetEnvironmentVariable("AUTH_ISSUER")?.TrimEnd('/');

        int lifetime = 60;
        if (int.TryParse(Environment.GetEnvironmentVariable("AUTH_TOKEN_LIFETIME_MINUTES"), out int parsed) && parsed > 0)
        {
            lifetime = parsed;
        }

        return new OAuthOptions
        {
            Enabled = enabled,
            Issuer = issuer,
            TokenLifetimeMinutes = lifetime,
        };
    }

    /// <summary>
    /// Resolve the public issuer/base URL. Prefers the configured AUTH_ISSUER, otherwise derives it from
    /// the current request so the sample works without extra configuration behind Container Apps ingress.
    /// </summary>
    public string ResolveIssuer(HttpRequest request)
    {
        if (!string.IsNullOrWhiteSpace(Issuer))
        {
            return Issuer;
        }

        return $"{request.Scheme}://{request.Host.Value}";
    }
}
