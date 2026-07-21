# Plant Copilot (MCP server)

**Plant Copilot** is a small, **read-only** [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server that turns the reference solution's factory data into grounded tools for an LLM agent. It sits in front of the [i3X](https://api.i3x.dev) REST adapter (the `i3x4kusto` container app) so an agent such as an [Azure AI Foundry](https://ai.azure.com) agent, GitHub Copilot, VS Code or Claude Desktop can answer natural-language questions about the plant — "what is the current temperature of assembly cell 3?", "how did line 2's throughput trend over the last shift?", "which assets are of type WeldingRobot?" — using **live and historical values from Azure Data Explorer or a Microsoft Fabric Eventhouse**.

The server uses the MCP **Streamable HTTP** transport, listens on port `8080`, and exposes its MCP endpoint at `/mcp`. It is built as a Docker image and deployed as an Azure Container App by [`Deployment/arm.json`](../../Deployment/arm.json), alongside the `i3x4kusto` app.

The server is deliberately read-only: it exposes browsing and querying tools only. There are **no** tools that change set-points, acknowledge alarms or otherwise actuate the plant. Any actuation must go through a separate, human-approval-gated path (see [agenticai.md](../../agenticai.md)).

## Tools

| Tool | i3X endpoint | Purpose |
|------|--------------|---------|
| `get_server_info` | `GET /v1/info` | Health / capabilities check. |
| `list_namespaces` | `GET /v1/namespaces` | List OPC UA namespaces. |
| `list_object_types` | `GET /v1/objecttypes` | List the information model (types). |
| `list_root_objects` | `GET /v1/objects?root=true` | Top of the ISA-95 asset hierarchy. |
| `list_objects_of_type` | `GET /v1/objects?typeElementId=` | All objects of a given type. |
| `get_related_objects` | `POST /v1/objects/related` | Children/variables of the given elements. |
| `get_current_values` | `POST /v1/objects/value` | Latest value/quality/timestamp (VQT). |
| `get_value_history` | `POST /v1/objects/history` | Historical values over a time range. |

## Configuration

The server reads its connection settings from environment variables:

| Variable | Required | Description |
|----------|----------|-------------|
| `I3X_BASE_URL` | yes | Base URL of the i3X API, e.g. `https://<resourcesName>-i3x4kusto.<region>.azurecontainerapps.io`. |
| `I3X_USERNAME` | if the API requires auth | HTTP Basic auth user (the deployment `adminUsername`). |
| `I3X_PASSWORD` | if the API requires auth | HTTP Basic auth password (the deployment `adminPassword`). |

## Deployed (Azure Container Apps) — automatic

You don't need to build or deploy the Plant Copilot yourself. Its container image is built and published automatically by the [Plant Copilot GitHub Actions workflow](../../.github/workflows/plant-copilot.yml) to `ghcr.io/digitaltwinconsortium/manufacturingontologies/plantcopilot:main`, and the reference solution's ARM template ([`Deployment/arm.json`](../../Deployment/arm.json)) provisions it as an Azure Container App wired to the in-cluster `i3x4kusto` app. The deployment exposes the remote MCP endpoint as the `plantCopilotMcpUrl` output, e.g. `https://<resourcesName>-plantcopilot.<region>.azurecontainerapps.io/mcp`. Just point your agent runtime (Azure AI Foundry, Copilot, VS Code) at that URL.

The sections below are only needed if you want to run or extend the server locally.

## Run it locally (optional)

Supply the i3X connection settings as environment variables:

```bash
docker run --rm -p 8080:8080 \
  -e I3X_BASE_URL="https://<resourcesName>-i3x4kusto.<region>.azurecontainerapps.io" \
  -e I3X_USERNAME="<adminUsername>" \
  -e I3X_PASSWORD="<adminPassword>" \
  ghcr.io/digitaltwinconsortium/manufacturingontologies/plantcopilot:main
```

The MCP endpoint is then available at `http://localhost:8080/mcp`.

## Register with an MCP host

The server uses the Streamable HTTP transport, so register it by URL. For VS Code, add an entry under `"mcp": { "servers": { ... } }` in your settings:

```json
{
  "servers": {
	"plant-copilot": {
	  "type": "http",
	  "url": "https://<resourcesName>-plantcopilot.<region>.azurecontainerapps.io/mcp"
	}
  }
}
```

Once registered, ask the agent plant questions and it will call the tools above and ground its answers in the returned data.

## Notes

- The server listens on port `8080` and exposes the MCP endpoint at `/mcp` (Streamable HTTP transport).
- See [agenticai.md](../../agenticai.md) for the broader agentic-AI architecture, scenarios and safety guardrails.
