# Agentic AI for the Reference Solution

Once the reference solution is deployed, the factory's OPC UA telemetry is connected, normalized against the ISA-95 asset hierarchy, and made queryable through Azure Data Explorer (or a Microsoft Fabric Eventhouse) and the [I3X](https://api.i3x.dev) API. This is exactly the kind of grounded, well-structured, real-time data that an **agentic AI** solution needs. This article describes how an AI agent on top of the reference solution works, starting with an automatically deployed, read-only **Plant Copilot** that answers natural-language questions about the plant, and outlines a safe path toward agents that can take action.

## Why agentic AI needs an information model

Large language models are powerful reasoners but they do not know your plant. They do not know that "work cell 3" is an assembly station on the Seattle assembly line, what its current energy consumption is, or how its throughput trended over the last shift. If you ask a raw model these questions it will guess, and guessing is unacceptable on a factory floor.

The reference solution solves this by giving the agent **tools** instead of asking it to remember facts:

- The **ISA-95 asset hierarchy** (enterprise → site → area → line → cell → asset) gives the agent a map of the plant it can browse.
- The **OPC UA information model** (object and variable types) tells the agent what kinds of assets exist and what each one measures.
- **Live values** and **historical trends** give the agent the actual numbers, with quality and timestamps, at the moment it needs them.

Because every answer is grounded in a tool result, the agent can cite the exact asset, value and time it used, which is essential for trust and auditability.

## The Model Context Protocol (MCP)

The agent talks to these tools through the [Model Context Protocol (MCP)](https://modelcontextprotocol.io), an open standard for exposing tools and data to LLM agents. MCP is supported by Microsoft 365 Copilot, Microsoft Copilot Studio, Azure AI Foundry, Claude and a growing list of hosts, so a single MCP server can be reused across many agent experiences.

This reference solution includes an MCP server, **Plant Copilot**, under [`Tools/PlantCopilot`](Tools/PlantCopilot). It is a thin, **read-only** wrapper over the I3X API that presents the factory data as a handful of well-described tools. It is packaged as a Docker image and deployed as an Azure Container App, using the MCP **Streamable HTTP** transport so remote agent runtimes can reach it over HTTPS at `/mcp`.

## Architecture

```text
   ┌──────────────┐        natural language        ┌──────────────────────┐
   │    User      │  ───────────────────────────►  │   Agent runtime      │
   │ (chat / app) │  ◄───────────────────────────  │   (Microsoft 365     │
   └──────────────┘        grounded answer         │   Copilot, Foundry…) │
												   └──────────┬───────────┘
													   	      │ MCP
															  ▼
												   ┌──────────────────────┐
												   │     Plant Copilot    │
												   │      MCP server      │
												   └──────────┬───────────┘
													   	      │ I3X
															  ▼
												   ┌──────────────────────┐
												   │       I3X4Kusto      │
												   └──────────┬───────────┘
													  	      │ KQL
															  ▼
												   ┌──────────────────────┐
												   │ Azure Data Explorer  │
												   │ / Fabric Eventhouse  │
												   └──────────────────────┘
```

The agent never touches the database directly. It only sees the curated, read-only tools, and the I3X layer enforces authentication and the ISA-95 shape of the data.

## Plant Copilot tools

| Tool | Purpose |
|------|---------|
| `get_server_info` | Health / capabilities check. |
| `list_namespaces` | List OPC UA namespaces in the data. |
| `list_object_types` | List the information model (types). |
| `list_root_objects` | Browse the top of the ISA-95 asset hierarchy. |
| `list_objects_of_type` | Find all assets/variables of a given type. |
| `get_related_objects` | Drill into the children/variables of an asset. |
| `get_current_values` | Read the latest value/quality/timestamp. |
| `get_value_history` | Read historical trends over a time range. |

With just these tools an agent can answer questions such as:

- "What is the current energy consumption of work cell 3?"
- "How did the Munich production line's throughput trend over the last shift?"
- "Which assets are test stations, and which ones have high pressure right now?"
- "List the sites and lines in the plant."

## Running the Plant Copilot

The Plant Copilot is deployed for you as part of the reference solution. There is nothing extra to set up. Its container image is built and published automatically to `ghcr.io/digitaltwinconsortium/manufacturingontologies/plantcopilot:main`, and the deployment template provisions it as an Azure Container App wired to the in-cluster I3X app. The deployment exposes its remote MCP endpoint as the `plantCopilotMcpUrl` output, e.g. `https://<resourcesName>-plantcopilot.<region>.azurecontainerapps.io/mcp`.

To surface the Plant Copilot inside the **Microsoft 365 Copilot** experience, you register it as a Model Context Protocol tool, add it to a custom agent, and publish that agent to Microsoft 365 Copilot.

> **Permissions and governance prerequisites.** Registering a custom MCP connector and publishing an agent are governed by tenant-level policies that only administrators can configure. Before you start, make sure a **Power Platform administrator** (and, where noted, a **Microsoft 365 administrator** and an **Entra ID administrator**) has arranged the following, otherwise the connection fails at creation or sign-in:
>
> - **Copilot Studio maker access** — a Power Platform environment you can build agents in (Environment Maker role), ideally a dedicated dev/sandbox environment.
> - **DLP data policy** — the Plant Copilot custom connector must be classified into an allowed group (Business or Non-Business, matching the agent's other connectors), not **Blocked**. Configured under **Security → Data policies** in the Power Platform admin center.
> - **Tenant isolation / connector endpoint filtering** — outbound OAuth to the Plant Copilot host (`https://<resourcesName>-plantcopilot.<region>.azurecontainerapps.io`) must be allowed. These are **tenant-scoped** settings that only a Global or Power Platform administrator can view or change.
> - **Entra ID (production auth mode only)** — if the server runs with `AUTH_AUTHORITY` set to Entra ID, an admin registers the connector app and must ensure no Conditional Access policy blocks the sign-in. The exact blocking policy is shown in **Entra ID → Sign-in logs**.
> - **Microsoft 365 admin approval** — publishing the agent to the Microsoft 365 Copilot channel may require approval in the [Microsoft 365 admin center](https://admin.microsoft.com/) under **Settings → Integrated apps**.
>
> If you are not an administrator, share this list (plus the connector name and host URL) with your tenant admin. Nothing in the Plant Copilot code or deployment can bypass these tenant governance controls.

### 1. Register the MCP server as a tool

In [Microsoft Copilot Studio](https://copilotstudio.microsoft.com/), select **Tools → New tool → Model Context Protocol** and provide:

- **Server name:** `Plant Copilot`
- **Server description:** `A read-only MCP server that exposes the plant's ISA-95 asset hierarchy, OPC UA information model, and live/historical telemetry.`
- **Server URL:** `https://<resourcesName>-plantcopilot.<region>.azurecontainerapps.io/mcp`
- **Authentication:** OAuth 2.0 with dynamic discovery (the Plant Copilot advertises its authorization server and supports Dynamic Client Registration, so no client id/secret needs to be entered)

Create the tool. On first connection Copilot Studio performs the OAuth flow against the Plant Copilot; approve it to establish the connection.

### 2. Create the agent

1. In Copilot Studio, select **Create → New agent** (or **Agents → New agent**).
2. Give the agent a name (e.g. `Plant Copilot`) and a description, and set instructions that steer it to answer only from the tool results, for example: *"You are a plant assistant. Use the Plant Copilot tools to answer questions about assets, live values and history. Always ground answers in tool results and cite the asset id, value and timestamp you used. Never invent data."*
3. Under the agent's **Tools**, select **Add tool** and choose the `Plant Copilot` MCP tool registered in step 1.
4. Use the **Test** pane to confirm the agent calls the tools and returns grounded answers (e.g. ask *"List the sites and lines in the plant."*).

### 3. Publish to Microsoft 365 Copilot

1. Select **Publish** to publish the agent.
2. Open the **Channels** tab and enable **Microsoft 365 Copilot** (Teams and Microsoft 365 Copilot).
3. Submit the agent for admin approval if your tenant requires it; a Microsoft 365 admin approves it in the [Microsoft 365 admin center](https://admin.microsoft.com/) under **Settings → Integrated apps**.

Once published and approved, users can select the agent in Microsoft 365 Copilot (in Teams, Outlook or the Microsoft 365 Copilot app) and ask the plant questions directly. Copilot grounds its answers in the tool results returned by the Plant Copilot.

## Beyond read-only: agents that take action

Answering questions is only the first scenario. Because the reference solution already contains normalized, model-driven data, several higher-value agentic scenarios become possible:

- **Anomaly triage** — when the anomaly detection or prediction pipeline flags an asset, an agent gathers the related context (recent history, sibling assets, asset type) and drafts an explanation and recommended next step for an operator to review.
- **Predictive-maintenance work orders** — an agent turns a prediction into a proposed work order in [Microsoft Dynamics 365 Field Service](fieldservice.md), which a planner approves.
- **Human-in-the-loop optimization** — an agent proposes a set-point change or schedule adjustment; the change is only applied after a human approves it and is actuated through a separate, authenticated command path (for example an OPC UA command via a dedicated, approval-gated service).
- **Self-documenting assets** — an agent uses the standardized OPC UA information models imported from the [UA Cloud Library](cloudlib.md) to describe unfamiliar assets in plain language.

## Safety and guardrails

Actuation on a factory floor carries real physical risk, so the reference solution keeps a strict separation between reading and acting:

- **Read-only by default.** The Plant Copilot MCP server exposes browsing and querying tools only. It has no tool that changes a set-point, acknowledges an alarm or otherwise actuates the plant.
- **Approval-gated writes.** Any action that changes the plant must go through a separate, authenticated, human-approved path. The agent may *propose* an action, but a person authorizes it.
- **Grounding.** Tools return data with explicit values, quality and timestamps, and the tool descriptions instruct the agent to answer only from that data rather than inventing asset ids, values or times.
- **Least privilege.** The I3X API is protected with authentication, and the agent runs with the minimum access required for its scenario.
- **Auditability.** Every tool call and every proposed or approved action should be logged to your SIEM. This directly supports the *Repudiation* mitigations in the reference solution's [security review](README.md).

Starting with a grounded, read-only copilot lets you demonstrate value quickly and safely, then add approval-gated actions one scenario at a time as trust is established.
