using PlantCopilot;

// "Plant Copilot" - a read-only Model Context Protocol (MCP) server that exposes the factory's i3X
// data (Azure Data Explorer / Microsoft Fabric Eventhouse) as grounded tools for an LLM agent.
//
// When deployed as a container (Azure Container Apps) the server uses the MCP Streamable HTTP
// transport and listens on port 8080, exposing the MCP endpoint at "/mcp". A remote agent runtime
// (Azure AI Foundry, Copilot, VS Code, ...) connects to https://<fqdn>/mcp.

var builder = WebApplication.CreateBuilder(args);

builder.WebHost.ConfigureKestrel(options => options.ListenAnyIP(8080));

builder.Services.AddHttpClient<I3xClient>();

builder.Services
    .AddMcpServer()
    .WithHttpTransport()
    .WithToolsFromAssembly();

var app = builder.Build();

// Simple liveness endpoint for the Container Apps ingress health probe.
app.MapGet("/", () => Results.Ok("Plant Copilot MCP server. MCP endpoint: /mcp"));

// Expose the MCP Streamable HTTP endpoint at /mcp.
app.MapMcp("/mcp");

app.Run();
