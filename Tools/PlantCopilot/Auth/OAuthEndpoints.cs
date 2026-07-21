using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace PlantCopilot.Auth;

/// <summary>
/// Minimal, self-contained OAuth 2.0 Authorization Server endpoints for the Plant Copilot MCP server:
///   - GET  /.well-known/oauth-protected-resource   (RFC 9728) resource metadata
///   - GET  /.well-known/oauth-authorization-server (RFC 8414) AS metadata
///   - GET  /.well-known/jwks.json                  JSON Web Key Set for token validation
///   - POST /register                               (RFC 7591) Dynamic Client Registration
///   - GET  /authorize                              authorization code + PKCE (S256)
///   - POST /token                                  token endpoint (authorization_code grant)
///
/// This is a demo-grade AS: the authorization endpoint auto-approves the request (there is no interactive
/// user login/consent UI). It is intended to make MCP hosts that perform Dynamic Client Registration work
/// against the reference solution out of the box. For production, front the MCP server with a real IdP.
/// </summary>
public static class OAuthEndpoints
{
    private const string ScopeDefault = "mcp";
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = null };

    public static void MapOAuth(this WebApplication app, OAuthOptions options, OAuthStore store)
    {
        app.MapGet("/.well-known/oauth-protected-resource", (HttpRequest request) =>
        {
            string issuer = options.ResolveIssuer(request);
            var doc = new JsonObject
            {
                ["resource"] = issuer,
                ["authorization_servers"] = new JsonArray(issuer),
                ["bearer_methods_supported"] = new JsonArray("header"),
                ["scopes_supported"] = new JsonArray(ScopeDefault),
            };
            return Results.Content(doc.ToJsonString(), "application/json");
        });

        app.MapGet("/.well-known/oauth-authorization-server", (HttpRequest request) =>
        {
            string issuer = options.ResolveIssuer(request);
            var doc = new JsonObject
            {
                ["issuer"] = issuer,
                ["authorization_endpoint"] = $"{issuer}/authorize",
                ["token_endpoint"] = $"{issuer}/token",
                ["registration_endpoint"] = $"{issuer}/register",
                ["jwks_uri"] = $"{issuer}/.well-known/jwks.json",
                ["scopes_supported"] = new JsonArray(ScopeDefault),
                ["response_types_supported"] = new JsonArray("code"),
                ["grant_types_supported"] = new JsonArray("authorization_code"),
                ["token_endpoint_auth_methods_supported"] = new JsonArray("none", "client_secret_post"),
                ["code_challenge_methods_supported"] = new JsonArray("S256"),
            };
            return Results.Content(doc.ToJsonString(), "application/json");
        });

        app.MapGet("/.well-known/jwks.json", () =>
        {
            var jwk = JsonWebKeyConverter.ConvertFromRSASecurityKey(options.SigningKey);
            jwk.Use = "sig";
            jwk.Alg = SecurityAlgorithms.RsaSha256;
            var set = new JsonObject
            {
                ["keys"] = new JsonArray(JsonNode.Parse(JsonSerializer.Serialize(jwk, JsonOptions))),
            };
            return Results.Content(set.ToJsonString(), "application/json");
        });

        // ---- RFC 7591 Dynamic Client Registration ----
        app.MapPost("/register", async (HttpRequest request) =>
        {
            JsonNode? body;
            try
            {
                body = await JsonNode.ParseAsync(request.Body);
            }
            catch (JsonException)
            {
                return RegistrationError("invalid_client_metadata", "Request body is not valid JSON.");
            }

            if (body is null)
            {
                return RegistrationError("invalid_client_metadata", "Missing request body.");
            }

            var redirectUris = (body["redirect_uris"] as JsonArray)?
                .Select(n => n?.GetValue<string>())
                .Where(s => !string.IsNullOrWhiteSpace(s))
                .Select(s => s!)
                .ToList() ?? new List<string>();

            var grantTypes = (body["grant_types"] as JsonArray)?
                .Select(n => n?.GetValue<string>())
                .Where(s => !string.IsNullOrWhiteSpace(s))
                .Select(s => s!)
                .ToList() ?? new List<string> { "authorization_code" };

            if (!grantTypes.Contains("authorization_code"))
            {
                return RegistrationError("invalid_client_metadata",
                    "This server only supports the 'authorization_code' grant type.");
            }

            if (redirectUris.Count == 0)
            {
                return RegistrationError("invalid_redirect_uri",
                    "At least one redirect_uri is required for the authorization_code grant.");
            }

            string authMethod = body["token_endpoint_auth_method"]?.GetValue<string>() ?? "none";
            string? clientName = body["client_name"]?.GetValue<string>();

            var client = store.AddClient(new RegisteredClient(
                ClientId: "mcp-" + Guid.NewGuid().ToString("N"),
                ClientName: clientName,
                RedirectUris: redirectUris,
                GrantTypes: grantTypes,
                TokenEndpointAuthMethod: authMethod,
                IssuedAt: DateTimeOffset.UtcNow));

            var response = new JsonObject
            {
                ["client_id"] = client.ClientId,
                ["client_id_issued_at"] = client.IssuedAt.ToUnixTimeSeconds(),
                ["redirect_uris"] = new JsonArray(client.RedirectUris.Select(u => (JsonNode)u!).ToArray()),
                ["grant_types"] = new JsonArray(client.GrantTypes.Select(g => (JsonNode)g!).ToArray()),
                ["token_endpoint_auth_method"] = client.TokenEndpointAuthMethod,
            };
            if (client.ClientName is not null)
            {
                response["client_name"] = client.ClientName;
            }

            return Results.Content(response.ToJsonString(), "application/json", Encoding.UTF8, StatusCodes.Status201Created);
        });

        // ---- Authorization endpoint (authorization code + PKCE) ----
        app.MapGet("/authorize", (HttpRequest request) =>
        {
            var q = request.Query;
            string? clientId = q["client_id"];
            string? redirectUri = q["redirect_uri"];
            string responseType = q["response_type"].ToString();
            string? state = q["state"];
            string? scope = q["scope"];
            string? codeChallenge = q["code_challenge"];
            string codeChallengeMethod = string.IsNullOrEmpty(q["code_challenge_method"]) ? "plain" : q["code_challenge_method"].ToString();

            if (string.IsNullOrEmpty(clientId) || !store.TryGetClient(clientId, out var client))
            {
                return Results.BadRequest(new { error = "invalid_client", error_description = "Unknown or missing client_id." });
            }

            if (string.IsNullOrEmpty(redirectUri) || !client.RedirectUris.Contains(redirectUri))
            {
                return Results.BadRequest(new { error = "invalid_request", error_description = "redirect_uri is not registered for this client." });
            }

            if (responseType != "code")
            {
                return RedirectWithError(redirectUri, state, "unsupported_response_type", "Only 'code' is supported.");
            }

            if (string.IsNullOrEmpty(codeChallenge) || codeChallengeMethod != "S256")
            {
                return RedirectWithError(redirectUri, state, "invalid_request", "PKCE with code_challenge_method=S256 is required.");
            }

            // Demo AS: auto-approve without interactive login/consent.
            var code = new AuthorizationCode(
                Code: Base64Url(RandomNumberGenerator.GetBytes(32)),
                ClientId: clientId,
                RedirectUri: redirectUri,
                CodeChallenge: codeChallenge,
                CodeChallengeMethod: codeChallengeMethod,
                Scope: scope,
                Subject: "plant-copilot-user",
                ExpiresAt: DateTimeOffset.UtcNow.AddMinutes(5));
            store.AddCode(code);

            var location = new StringBuilder(redirectUri);
            location.Append(redirectUri.Contains('?') ? '&' : '?');
            location.Append("code=").Append(Uri.EscapeDataString(code.Code));
            if (!string.IsNullOrEmpty(state))
            {
                location.Append("&state=").Append(Uri.EscapeDataString(state));
            }
            return Results.Redirect(location.ToString());
        });

        // ---- Token endpoint ----
        app.MapPost("/token", async (HttpRequest request) =>
        {
            if (!request.HasFormContentType)
            {
                return TokenError("invalid_request", "Expected application/x-www-form-urlencoded body.");
            }

            var form = await request.ReadFormAsync();
            string grantType = form["grant_type"].ToString();
            if (grantType != "authorization_code")
            {
                return TokenError("unsupported_grant_type", "Only 'authorization_code' is supported.");
            }

            string code = form["code"].ToString();
            string clientId = form["client_id"].ToString();
            string redirectUri = form["redirect_uri"].ToString();
            string codeVerifier = form["code_verifier"].ToString();

            if (string.IsNullOrEmpty(code) || !store.TryConsumeCode(code, out var authCode))
            {
                return TokenError("invalid_grant", "Authorization code is invalid or already used.");
            }

            if (authCode.ExpiresAt < DateTimeOffset.UtcNow)
            {
                return TokenError("invalid_grant", "Authorization code has expired.");
            }

            if (authCode.ClientId != clientId || authCode.RedirectUri != redirectUri)
            {
                return TokenError("invalid_grant", "client_id or redirect_uri does not match the authorization request.");
            }

            if (string.IsNullOrEmpty(codeVerifier) || !VerifyPkce(codeVerifier, authCode.CodeChallenge))
            {
                return TokenError("invalid_grant", "PKCE code_verifier validation failed.");
            }

            string issuer = options.ResolveIssuer(request);
            string scope = authCode.Scope ?? ScopeDefault;
            string accessToken = IssueToken(options, issuer, authCode.Subject, clientId, scope);

            var response = new JsonObject
            {
                ["access_token"] = accessToken,
                ["token_type"] = "Bearer",
                ["expires_in"] = options.TokenLifetimeMinutes * 60,
                ["scope"] = scope,
            };
            return Results.Content(response.ToJsonString(), "application/json");
        });
    }

    private static string IssueToken(OAuthOptions options, string issuer, string subject, string clientId, string scope)
    {
        var now = DateTime.UtcNow;
        var handler = new JsonWebTokenHandler();
        var descriptor = new SecurityTokenDescriptor
        {
            Issuer = issuer,
            Audience = issuer,
            Subject = new ClaimsIdentity(new[]
            {
                new Claim(JwtRegisteredClaimNames.Sub, subject),
                new Claim("client_id", clientId),
                new Claim("scope", scope),
            }),
            IssuedAt = now,
            NotBefore = now,
            Expires = now.AddMinutes(options.TokenLifetimeMinutes),
            SigningCredentials = new SigningCredentials(options.SigningKey, SecurityAlgorithms.RsaSha256),
        };
        return handler.CreateToken(descriptor);
    }

    private static bool VerifyPkce(string codeVerifier, string codeChallenge)
    {
        byte[] hash = SHA256.HashData(Encoding.ASCII.GetBytes(codeVerifier));
        return CryptographicOperations.FixedTimeEquals(
            Encoding.ASCII.GetBytes(Base64Url(hash)),
            Encoding.ASCII.GetBytes(codeChallenge));
    }

    private static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static IResult RegistrationError(string error, string description) =>
        Results.Json(new { error, error_description = description }, statusCode: StatusCodes.Status400BadRequest);

    private static IResult TokenError(string error, string description) =>
        Results.Json(new { error, error_description = description }, statusCode: StatusCodes.Status400BadRequest);

    private static IResult RedirectWithError(string redirectUri, string? state, string error, string description)
    {
        var location = new StringBuilder(redirectUri);
        location.Append(redirectUri.Contains('?') ? '&' : '?');
        location.Append("error=").Append(Uri.EscapeDataString(error));
        location.Append("&error_description=").Append(Uri.EscapeDataString(description));
        if (!string.IsNullOrEmpty(state))
        {
            location.Append("&state=").Append(Uri.EscapeDataString(state));
        }
        return Results.Redirect(location.ToString());
    }
}
