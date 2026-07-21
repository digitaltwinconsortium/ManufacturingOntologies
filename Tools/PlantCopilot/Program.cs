using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;
using PlantCopilot;
using PlantCopilot.Auth;

// "Plant Copilot" - a read-only Model Context Protocol (MCP) server that exposes the factory's i3X
// data (Azure Data Explorer / Microsoft Fabric Eventhouse) as grounded tools for an LLM agent.
//
// When deployed as a container (Azure Container Apps) the server uses the MCP Streamable HTTP
// transport and listens on port 8080, exposing the MCP endpoint at "/mcp". A remote agent runtime
// (Azure AI Foundry, Copilot, VS Code, ...) connects to https://<fqdn>/mcp.
//
// Optionally the server enforces OAuth 2.0 (with Dynamic Client Registration) on /mcp. Set
// AUTH_ENABLED=true to turn it on; see Auth/OAuthOptions.cs and README.md for details.

var builder = WebApplication.CreateBuilder(args);

builder.WebHost.ConfigureKestrel(options => options.ListenAnyIP(8080));

builder.Services.AddHttpClient<I3xClient>();

// Optional OAuth 2.0 authorization layer (Authorization Server + Resource Server).
var oauth = OAuthOptions.FromEnvironment();
builder.Services.AddSingleton(oauth);
builder.Services.AddSingleton<OAuthStore>();

if (oauth.Enabled)
{
    if (oauth.UseExternalAuthority)
    {
        // Production mode: validate JWT access tokens issued by an external identity provider
        // (e.g. Microsoft Entra ID). The server does NOT run its own Authorization Server, so there
        // is no Dynamic Client Registration; register the client in the external IdP instead.
        builder.Services
            .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddJwtBearer(options =>
            {
                options.MapInboundClaims = false;
                options.Authority = oauth.Authority;
                options.TokenValidationParameters = new TokenValidationParameters
                {
                    ValidateIssuer = true,
                    ValidateAudience = oauth.Audiences.Count > 0,
                    ValidAudiences = oauth.Audiences,
                    ValidateLifetime = true,
                    ValidateIssuerSigningKey = true,
                };
            });
    }
    else
    {
        // Demo mode: the server is its own self-contained Authorization Server and signs/validates
        // tokens with an in-process key. MCP hosts self-register via Dynamic Client Registration.
        builder.Services
            .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddJwtBearer(options =>
            {
                options.MapInboundClaims = false;
                options.TokenValidationParameters = new TokenValidationParameters
                {
                    ValidateIssuer = false,   // issuer is derived from the request base URL at runtime
                    ValidateAudience = false, // audience equals the issuer; skip strict binding for the demo
                    ValidateLifetime = true,
                    ValidateIssuerSigningKey = true,
                    IssuerSigningKey = oauth.SigningKey,
                };

                // On 401, point MCP hosts at the RFC 9728 protected-resource metadata for discovery.
                options.Events = new JwtBearerEvents
                {
                    OnChallenge = context =>
                    {
                        context.HandleResponse();
                        string issuer = oauth.ResolveIssuer(context.Request);
                        string resourceMetadata = $"{issuer}/.well-known/oauth-protected-resource";
                        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
                        context.Response.Headers.WWWAuthenticate =
                            $"Bearer resource_metadata=\"{resourceMetadata}\"";
                        return Task.CompletedTask;
                    },
                };
            });
    }

    builder.Services.AddAuthorization();
}

builder.Services
    .AddMcpServer()
    .WithHttpTransport()
    .WithToolsFromAssembly();

var app = builder.Build();

// Simple liveness endpoint for the Container Apps ingress health probe.
app.MapGet("/", () => Results.Ok("Plant Copilot MCP server. MCP endpoint: /mcp"));

if (oauth.Enabled)
{
    app.UseAuthentication();
    app.UseAuthorization();

    // The built-in Authorization Server (metadata, Dynamic Client Registration, authorize and token
    // endpoints) is only mapped in demo mode. In external-authority mode the identity provider owns
    // these endpoints, so the server acts purely as a Resource Server.
    if (!oauth.UseExternalAuthority)
    {
        app.MapOAuth(oauth, app.Services.GetRequiredService<OAuthStore>());
    }

    // Expose the MCP Streamable HTTP endpoint at /mcp, protected by OAuth.
    app.MapMcp("/mcp").RequireAuthorization();
}
else
{
    // Expose the MCP Streamable HTTP endpoint at /mcp (unauthenticated).
    app.MapMcp("/mcp");
}

app.Run();
