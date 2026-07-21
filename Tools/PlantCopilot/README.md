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
| `AUTH_ENABLED` | no | OAuth 2.0 on `/mcp` is **enabled by default**. Set to `false` to leave the endpoint open. |
| `AUTH_ISSUER` | no | Public base URL of this server, e.g. `https://<fqdn>`. Used as the token issuer/audience and to build discovery URLs. If unset it is derived from the incoming request. |
| `AUTH_TOKEN_LIFETIME_MINUTES` | no | Access-token lifetime in minutes (default: `60`). Built-in authorization server only. |
| `AUTH_AUTHORITY` | no | OIDC authority of an **external** identity provider (e.g. Microsoft Entra ID, `https://login.microsoftonline.com/<tenant>/v2.0`). When set, the server validates tokens from that provider and disables its own authorization server / Dynamic Client Registration. |
| `AUTH_AUDIENCE` | no | Expected audience (`aud`) claim(s), comma-separated. Recommended when `AUTH_AUTHORITY` is set. |

## Authentication (OAuth 2.0 with Dynamic Client Registration)

By default the `/mcp` endpoint **requires OAuth 2.0**. The server acts as self-contained OAuth 2.0 Authorization Server **and** Resource Server so that MCP hosts which support [Dynamic Client Registration (RFC 7591)](https://www.rfc-editor.org/rfc/rfc7591) — Microsoft 365 Copilot, Copilot Studio, Claude — can register and obtain a token automatically, with no external identity provider to configure. Set `AUTH_ENABLED=false` to leave the endpoint open (any caller that can reach the ingress may call the read-only tools).

The following endpoints are exposed while OAuth is enabled (the default):

| Endpoint | Standard | Purpose |
|----------|----------|---------|
| `GET /.well-known/oauth-protected-resource` | [RFC 9728](https://www.rfc-editor.org/rfc/rfc9728) | Protected-resource metadata; advertises the authorization server. |
| `GET /.well-known/oauth-authorization-server` | [RFC 8414](https://www.rfc-editor.org/rfc/rfc8414) | Authorization-server metadata (endpoints, PKCE, grant types). |
| `GET /.well-known/jwks.json` | JWKS | Public key used to validate access tokens. |
| `POST /register` | [RFC 7591](https://www.rfc-editor.org/rfc/rfc7591) | Dynamic Client Registration. |
| `GET /authorize` | OAuth 2.0 | Authorization Code grant with **PKCE (S256, required)**. |
| `POST /token` | OAuth 2.0 | Exchanges the code for a signed RS256 JWT access token. |

Typical MCP flow: the host calls `/mcp` without a token, receives `401` with a `WWW-Authenticate: Bearer resource_metadata="…/.well-known/oauth-protected-resource"` header, discovers the authorization server, performs DCR at `/register`, runs the authorization-code + PKCE flow (`/authorize` → `/token`), then retries `/mcp` with the bearer token.

> **Demo-grade authorization server.** The built-in `/authorize` endpoint **auto-approves** requests — there is no interactive user login or consent UI, clients and codes are held in-memory (they reset on restart and do not span multiple instances), and tokens are signed with an in-process key. This is intended to make DCR-capable hosts work against the reference solution out of the box. For production, use the external identity provider mode below instead.

### Production: external identity provider (Microsoft Entra ID)

For production, front the MCP server with a real identity provider and validate its tokens instead of relying on the built-in authorization server. Set `AUTH_AUTHORITY` (and, recommended, `AUTH_AUDIENCE`) to switch the server into **Resource Server only** mode: it validates JWT access tokens issued by that provider and stops exposing the built-in `/register`, `/authorize` and `/token` endpoints.

Because Microsoft Entra ID does not support open, unauthenticated Dynamic Client Registration, you register the client yourself rather than relying on DCR:

1. In Entra ID, create an **app registration for the MCP server** (the API/resource) that exposes a scope, e.g. `PlantCopilot.Read`, and note its Application ID URI (used as the token `aud`).
2. Create (or reuse) an **app registration for the client** (the Copilot Studio connector) and grant it that scope.
3. Run the server with, for example:
   - `AUTH_AUTHORITY=https://login.microsoftonline.com/<tenant-id>/v2.0`
   - `AUTH_AUDIENCE=api://<mcp-app-id>` (or the exposed scope's audience)
4. In Copilot Studio, configure the MCP tool with a **manual OAuth 2.0 connection** (client id, client secret, authorization/token URLs and scope) instead of "OAuth 2.0 with dynamic discovery".

In this mode there is no DCR and no built-in login/consent — authentication, consent and per-user/per-client identity are all handled by Entra ID.

To disable authentication locally (e.g. for quick testing), add `-e AUTH_ENABLED=false` to the `docker run` command below; optionally set `-e AUTH_ISSUER=...` to pin the public issuer URL.

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
