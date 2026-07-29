namespace PlantCopilot.Auth;

/// <summary>
/// Configuration for the optional OAuth 2.0 layer of the Plant Copilot MCP server.
///
/// The server acts purely as an OAuth 2.0 **Resource Server**: it validates JWT access tokens issued
/// by an external identity provider (for example Microsoft Entra ID). It does not issue tokens and
/// does not run an authorization server, so there is no Dynamic Client Registration - register the
/// calling application in your identity provider instead.
///
/// Environment variables:
///   AUTH_AUTHORITY - OIDC authority of the identity provider, e.g.
///                    https://login.microsoftonline.com/&lt;tenant&gt;/v2.0. OAuth is enabled only when
///                    this is set.
///   AUTH_AUDIENCE  - expected audience (aud) claim(s), comma-separated. Strongly recommended.
/// </summary>
public sealed class OAuthOptions
{
    /// <summary>OIDC authority of the external identity provider, or null when OAuth is not configured.</summary>
    public string? Authority { get; init; }

    /// <summary>Expected audience(s) for incoming access tokens.</summary>
    public IReadOnlyList<string> Audiences { get; init; } = Array.Empty<string>();

    /// <summary>True when an external identity provider is configured and bearer tokens are accepted.</summary>
    public bool Enabled => !string.IsNullOrWhiteSpace(Authority);

    public static OAuthOptions FromEnvironment()
    {
        string? authority = Environment.GetEnvironmentVariable("AUTH_AUTHORITY")?.TrimEnd('/');

        string[] audiences = (Environment.GetEnvironmentVariable("AUTH_AUDIENCE") ?? string.Empty)
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        return new OAuthOptions
        {
            Authority = string.IsNullOrWhiteSpace(authority) ? null : authority,
            Audiences = audiences,
        };
    }
}
