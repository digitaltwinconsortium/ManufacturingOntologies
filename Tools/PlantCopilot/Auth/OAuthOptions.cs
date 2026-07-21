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
///
///   External identity provider (production) mode:
///   AUTH_AUTHORITY - OIDC authority of an external identity provider, e.g. Microsoft Entra ID
///                    (https://login.microsoftonline.com/&lt;tenant&gt;/v2.0). When set, the server stops
///                    acting as its own Authorization Server (no /register, /authorize, /token) and
///                    instead validates JWT access tokens issued by that provider. In this mode
///                    Dynamic Client Registration is NOT used; register the client (e.g. the Copilot
///                    Studio connector) in the external IdP and configure a manual OAuth connection.
///   AUTH_AUDIENCE  - expected audience (aud) claim(s), comma-separated (recommended in authority mode).
/// </summary>
public sealed class OAuthOptions
{
    public bool Enabled { get; init; }

    /// <summary>Configured public issuer, or null to derive it from the incoming request.</summary>
    public string? Issuer { get; init; }

    public int TokenLifetimeMinutes { get; init; } = 60;

    /// <summary>
    /// OIDC authority of an external identity provider (e.g. Microsoft Entra ID). When set, the server
    /// validates tokens issued by this provider instead of running its own Authorization Server.
    /// </summary>
    public string? Authority { get; init; }

    /// <summary>Expected audience(s) for tokens in external-authority mode.</summary>
    public IReadOnlyList<string> Audiences { get; init; } = Array.Empty<string>();

    /// <summary>True when authentication is enabled and an external IdP authority is configured.</summary>
    public bool UseExternalAuthority => Enabled && !string.IsNullOrWhiteSpace(Authority);

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

        string? authority = Environment.GetEnvironmentVariable("AUTH_AUTHORITY")?.TrimEnd('/');

        string[] audiences = (Environment.GetEnvironmentVariable("AUTH_AUDIENCE") ?? string.Empty)
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        int lifetime = 60;
        if (int.TryParse(Environment.GetEnvironmentVariable("AUTH_TOKEN_LIFETIME_MINUTES"), out int parsed) && parsed > 0)
        {
            lifetime = parsed;
        }

        return new OAuthOptions
        {
            Enabled = enabled,
            Issuer = issuer,
            Authority = string.IsNullOrWhiteSpace(authority) ? null : authority,
            Audiences = audiences,
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
