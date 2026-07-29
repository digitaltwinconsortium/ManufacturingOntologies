using System.Net.Http.Headers;
using System.Security.Claims;
using System.Text;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace PlantCopilot.Auth;

/// <summary>
/// HTTP Basic authentication for the Plant Copilot MCP endpoint. This is a simple alternative to the
/// OAuth 2.0 flow for callers (scripts, tests, MCP hosts without OAuth support) that can only send a
/// static credential.
///
/// Environment variables:
///   AUTH_BASIC_USERNAME - user name accepted on the Authorization: Basic header.
///   AUTH_BASIC_PASSWORD - password accepted on the Authorization: Basic header.
///
/// Basic auth is only active when BOTH variables are set (see <see cref="BasicAuthOptions"/>). It is
/// accepted alongside OAuth bearer tokens; the scheme is selected per request from the Authorization
/// header. Always use it over HTTPS - the credential is only base64-encoded, not encrypted.
/// </summary>
public sealed class BasicAuthenticationHandler : AuthenticationHandler<AuthenticationSchemeOptions>
{
    public const string SchemeName = "Basic";

    private readonly BasicAuthOptions _basic;

    public BasicAuthenticationHandler(
        IOptionsMonitor<AuthenticationSchemeOptions> options,
        ILoggerFactory logger,
        UrlEncoder encoder,
        BasicAuthOptions basic)
        : base(options, logger, encoder)
    {
        _basic = basic;
    }

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (!_basic.Configured)
        {
            return Task.FromResult(AuthenticateResult.NoResult());
        }

        if (!Request.Headers.TryGetValue("Authorization", out var authorizationHeader))
        {
            return Task.FromResult(AuthenticateResult.NoResult());
        }

        if (!AuthenticationHeaderValue.TryParse(authorizationHeader.ToString(), out var header) ||
            !SchemeName.Equals(header.Scheme, StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrEmpty(header.Parameter))
        {
            return Task.FromResult(AuthenticateResult.NoResult());
        }

        string userName;
        string password;
        try
        {
            string decoded = Encoding.UTF8.GetString(Convert.FromBase64String(header.Parameter));
            int separator = decoded.IndexOf(':');
            if (separator < 0)
            {
                return Task.FromResult(AuthenticateResult.Fail("Invalid Basic credentials."));
            }

            userName = decoded[..separator];
            password = decoded[(separator + 1)..];
        }
        catch (FormatException)
        {
            return Task.FromResult(AuthenticateResult.Fail("Invalid Basic credentials."));
        }

        if (!_basic.Matches(userName, password))
        {
            return Task.FromResult(AuthenticateResult.Fail("Invalid user name or password."));
        }

        var claims = new[] { new Claim(ClaimTypes.Name, userName) };
        var identity = new ClaimsIdentity(claims, Scheme.Name);
        var ticket = new AuthenticationTicket(new ClaimsPrincipal(identity), Scheme.Name);
        return Task.FromResult(AuthenticateResult.Success(ticket));
    }

    protected override Task HandleChallengeAsync(AuthenticationProperties properties)
    {
        Response.StatusCode = StatusCodes.Status401Unauthorized;
        Response.Headers.WWWAuthenticate = "Basic realm=\"Plant Copilot\", charset=\"UTF-8\"";
        return Task.CompletedTask;
    }
}
