using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;
using PlantCopilot;
using PlantCopilot.Auth;
using System.Globalization;
using System.Threading.RateLimiting;

// "Plant Copilot" - a read-only Model Context Protocol (MCP) server that exposes the factory's i3X
// data (Azure Data Explorer / Microsoft Fabric Eventhouse) as grounded tools for an LLM agent.
//
// When deployed as a container (Azure Container Apps) the server uses the MCP Streamable HTTP
// transport and listens on port 8080, exposing the MCP endpoint at "/mcp". A remote agent runtime
// (Azure AI Foundry, Copilot, VS Code, ...) connects to https://<fqdn>/mcp.
//
// The MCP endpoint is protected by HTTP Basic authentication and/or OAuth 2.0 bearer tokens issued
// by an external identity provider (e.g. Microsoft Entra ID). See Auth/BasicAuthOptions.cs,
// Auth/OAuthOptions.cs and README.md for details.

var builder = WebApplication.CreateBuilder(args);

builder.WebHost.ConfigureKestrel(options =>
{
    options.ListenAnyIP(8080);
    // Do not advertise the server implementation (avoids fingerprinting).
    options.AddServerHeader = false;
});

builder.Services.AddHttpClient<I3xClient>();

// Rate limiting for the public MCP endpoint. Each caller gets its own bucket so a single noisy or
// abusive client cannot starve the others, and the shared upstream (i3X -> ADX/Fabric) is protected
// from request amplification. Limits are sized for interactive agent use: an agent typically issues
// a short burst of tool calls to answer one question, then pauses while the model reasons.
//
// Defaults (override with environment variables):
//   RATE_LIMIT_PERMITS_PER_MINUTE - sustained requests per minute per caller (default 120).
//   RATE_LIMIT_BURST              - extra requests allowed in a burst, queued (default 20).
const string mcpRateLimiterPolicy = "mcp";

int permitsPerMinute = ReadPositiveInt("RATE_LIMIT_PERMITS_PER_MINUTE", 120);
int burstQueueLimit = ReadPositiveInt("RATE_LIMIT_BURST", 20);

builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;

    // Tell well-behaved clients when to retry instead of hammering the endpoint.
    options.OnRejected = (context, cancellationToken) =>
    {
        if (context.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retryAfter))
        {
            context.HttpContext.Response.Headers.RetryAfter =
                ((int)retryAfter.TotalSeconds).ToString(NumberFormatInfo.InvariantInfo);
        }

        return ValueTask.CompletedTask;
    };

    options.AddPolicy(mcpRateLimiterPolicy, httpContext =>
    {
        // Partition per authenticated identity when available, otherwise per remote IP, so limits
        // apply to each caller rather than to the endpoint as a whole.
        string partitionKey =
            httpContext.User?.Identity?.IsAuthenticated == true
                ? httpContext.User.Identity!.Name ?? "authenticated"
                : httpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown";

        return RateLimitPartition.GetSlidingWindowLimiter(partitionKey, _ => new SlidingWindowRateLimiterOptions
        {
            PermitLimit = permitsPerMinute,
            Window = TimeSpan.FromMinutes(1),
            // Six 10-second segments keep the window smooth instead of resetting all at once.
            SegmentsPerWindow = 6,
            QueueProcessingOrder = QueueProcessingOrder.OldestFirst,
            QueueLimit = burstQueueLimit,
        });
    });
});

static int ReadPositiveInt(string variableName, int defaultValue)
    => int.TryParse(Environment.GetEnvironmentVariable(variableName), out int parsed) && parsed > 0
        ? parsed
        : defaultValue;

// Authentication is MANDATORY on /mcp. Two methods are supported:
//   - HTTP Basic authentication (the default): set AUTH_BASIC_PASSWORD; AUTH_BASIC_USERNAME
//     defaults to "admin". The reference deployment supplies both from adminUsername/adminPassword.
//   - OAuth 2.0 bearer tokens issued by an EXTERNAL identity provider (AUTH_AUTHORITY), e.g.
//     Microsoft Entra ID. The server is only a Resource Server: it validates tokens, it never
//     issues them, and there is no Dynamic Client Registration.
// When both are configured they are accepted side by side; the scheme is selected per request from
// the Authorization header. If NEITHER is configured the server fails closed (see below) rather than
// silently exposing the plant data.
var oauth = OAuthOptions.FromEnvironment();
builder.Services.AddSingleton(oauth);

var basicAuth = BasicAuthOptions.FromEnvironment();
builder.Services.AddSingleton(basicAuth);

if (oauth.Enabled || basicAuth.Configured)
{
    const string selectorScheme = "PlantCopilot";

    // Default scheme: the selector when both methods are available, otherwise the single method.
    string defaultScheme =
        oauth.Enabled && basicAuth.Configured ? selectorScheme
        : oauth.Enabled ? JwtBearerDefaults.AuthenticationScheme
        : BasicAuthenticationHandler.SchemeName;

    var authentication = builder.Services.AddAuthentication(defaultScheme);

    if (oauth.Enabled && basicAuth.Configured)
    {
        authentication.AddPolicyScheme(selectorScheme, selectorScheme, options =>
        {
            options.ForwardDefaultSelector = context =>
                context.Request.Headers.Authorization.ToString()
                    .StartsWith("Basic ", StringComparison.OrdinalIgnoreCase)
                        ? BasicAuthenticationHandler.SchemeName
                        : JwtBearerDefaults.AuthenticationScheme;
        });
    }

    if (basicAuth.Configured)
    {
        authentication.AddScheme<AuthenticationSchemeOptions, BasicAuthenticationHandler>(
            BasicAuthenticationHandler.SchemeName, null);
    }

    if (oauth.Enabled)
    {
        // Validate JWT access tokens issued by the external identity provider. Register the calling
        // application in that provider; this server does not register clients.
        authentication.AddJwtBearer(options =>
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

    builder.Services.AddAuthorization();
}

builder.Services
    .AddMcpServer()
    .WithHttpTransport()
    .WithToolsFromAssembly();

var app = builder.Build();

// Simple liveness endpoint for the Container Apps ingress health probe.
app.MapGet("/", () => Results.Ok("Plant Copilot MCP server. MCP endpoint: /mcp"));

if (oauth.Enabled || basicAuth.Configured)
{
    app.UseAuthentication();
    app.UseAuthorization();

    // Placed after authentication so each caller is rate limited by its own identity.
    app.UseRateLimiter();

    // Expose the MCP Streamable HTTP endpoint at /mcp, protected by Basic auth and/or OAuth bearer
    // tokens from the configured external identity provider.
    app.MapMcp("/mcp").RequireAuthorization().RequireRateLimiting(mcpRateLimiterPolicy);
}
else
{
    // Fail closed: authentication is mandatory, so refuse to serve the tools if no method is
    // configured, rather than exposing the plant data anonymously.
    app.MapPost("/mcp", () => Results.Problem(
        detail: "Authentication is not configured. Set AUTH_BASIC_PASSWORD (Basic authentication, "
              + "user name defaults to 'admin') and/or AUTH_AUTHORITY (OAuth 2.0).",
        statusCode: StatusCodes.Status503ServiceUnavailable));

    app.MapGet("/mcp", () => Results.Problem(
        detail: "Authentication is not configured. Set AUTH_BASIC_PASSWORD (Basic authentication, "
              + "user name defaults to 'admin') and/or AUTH_AUTHORITY (OAuth 2.0).",
        statusCode: StatusCodes.Status503ServiceUnavailable));
}

app.Run();
