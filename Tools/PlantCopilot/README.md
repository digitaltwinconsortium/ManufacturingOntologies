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
| `list_relationship_types` | `GET /v1/relationshiptypes` | List the relationship types in the model. |
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
| `AUTH_BASIC_PASSWORD` | yes (unless using OAuth) | Password for HTTP **Basic** authentication on `/mcp`. Basic authentication is the default method and becomes active as soon as this is set. The deployment supplies it from `adminPassword`. |
| `AUTH_BASIC_USERNAME` | no | User name for HTTP Basic authentication (default: `admin`). The deployment sets it from `adminUsername`. |
| `AUTH_AUTHORITY` | no | OIDC authority of an **external** identity provider (e.g. Microsoft Entra ID, `https://login.microsoftonline.com/<tenant>/v2.0`). When set, the server also accepts OAuth 2.0 bearer tokens issued by that provider. |
| `AUTH_AUDIENCE` | no | Expected audience (`aud`) claim(s), comma-separated. Strongly recommended when `AUTH_AUTHORITY` is set. |
| `RATE_LIMIT_PERMITS_PER_MINUTE` | no | Sustained requests per minute allowed **per caller** on `/mcp` (default: `120`). |
| `RATE_LIMIT_BURST` | no | Additional requests queued during a burst before callers are rejected with `429` (default: `20`). |

## Rate limiting

The `/mcp` endpoint is rate limited to protect the server and the shared upstream (i3X → Azure Data Explorer / Fabric Eventhouse) from request amplification and abuse.

- **Per-caller partitioning.** Each caller gets its own bucket, keyed by the authenticated identity when available and otherwise by remote IP address, so one noisy client cannot starve the others.
- **Sliding window.** The default allows **120 requests per minute per caller** with a queue for a further **20** burst requests, using a 1-minute sliding window split into six 10-second segments (so capacity replenishes smoothly rather than resetting all at once).
- **Why these numbers.** An agent typically issues a short burst of tool calls to answer a single question and then pauses while the model reasons. 120/minute (2/second sustained) comfortably covers interactive use and multi-step agent runs, while still capping the amplification a single client can cause upstream. Raise `RATE_LIMIT_PERMITS_PER_MINUTE` for heavier automation, or lower it if your Eventhouse/ADX capacity is constrained.
- **Rejection behavior.** Over-limit requests receive **HTTP 429 (Too Many Requests)** with a `Retry-After` header so well-behaved clients back off instead of retrying immediately.

## Authentication

Authentication on `/mcp` is **mandatory**. Two methods are supported; when both are configured they are accepted side by side and the scheme is chosen per request from the `Authorization` header.

The server is **never an authorization server**: it does not issue tokens, and there is no Dynamic Client Registration. Register any OAuth client in your own identity provider.

> **Fails closed.** If neither method is configured, `/mcp` does not serve the tools — it returns **HTTP 503** explaining which variables to set. The plant data is never exposed anonymously.

### HTTP Basic authentication (enabled by default)

Basic authentication is the default method: set `AUTH_BASIC_PASSWORD` and it is active (`AUTH_BASIC_USERNAME` defaults to `admin`). The reference deployment configures both automatically from the deployment's `adminUsername` / `adminPassword` (the password is delivered through a Container Apps secret), so the deployed endpoint is protected out of the box. Microsoft Copilot Studio and most MCP hosts can connect using Basic authentication.

```bash
curl -u <adminUsername>:<adminPassword> https://<fqdn>/mcp
```

Credentials are compared in fixed time so a failed comparison does not leak how much of the credential was correct. Because Basic authentication only base64-encodes the credential, **always use it over HTTPS** (the Container Apps ingress terminates TLS and rejects plain HTTP).

```bash
curl -u <adminUsername>:<adminPassword> https://<fqdn>/mcp
```

Credentials are compared in fixed time so a failed comparison does not leak how much of the credential was correct. Because Basic authentication only base64-encodes the credential, **always use it over HTTPS** (the Container Apps ingress terminates TLS and rejects plain HTTP).

### OAuth 2.0 with an external identity provider (optional)

As a second option the server can validate OAuth 2.0 bearer tokens issued by an external identity provider such as Microsoft Entra ID. In this mode it acts purely as an OAuth 2.0 **Resource Server**.

1. In Entra ID, create an **app registration for the MCP server** (the API/resource) and note its Application ID URI (used as the token `aud`).
2. Create (or reuse) an **app registration for the client** (for example the Copilot Studio connector) and grant it access to that API.
3. Configure the server with:
   - `AUTH_AUTHORITY=https://login.microsoftonline.com/<tenant-id>/v2.0`
   - `AUTH_AUDIENCE=api://<mcp-app-id>`
4. In Copilot Studio, configure the tool with a **manual OAuth 2.0 connection** (client id, client secret, authorization/token URLs and scope).

Tokens are validated for issuer, audience, lifetime and signature against the provider's published keys. Authentication, consent and per-user/per-client identity are all handled by the identity provider. If you rely on OAuth alone, leave `AUTH_BASIC_PASSWORD` unset so the shared Basic credential is not accepted.


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
