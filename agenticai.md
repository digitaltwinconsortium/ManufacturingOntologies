# Agentic AI for the reference solution

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

This reference solution includes a small MCP server, **Plant Copilot**, under [`Tools/PlantCopilot`](Tools/PlantCopilot). It is a thin, **read-only** wrapper over the I3X API that presents the factory data as a handful of well-described tools. It is packaged as a Docker image and deployed as an Azure Container App, using the MCP **Streamable HTTP** transport so remote agent runtimes can reach it over HTTPS at `/mcp`.

## Architecture

```text
   ┌──────────────┐        natural language        ┌──────────────────────┐
   │    User      │  ───────────────────────────►  │   Agent runtime      │
   │ (chat / app) │  ◄───────────────────────────  │ (Microsoft 365       │
   └──────────────┘        grounded answer         │  Copilot, Foundry…)  │
													└───────────┬──────────┘
																│ MCP over HTTPS (/mcp)
																▼
													┌──────────────────────┐
													│   Plant Copilot       │
													│   MCP server          │
													│  (read-only tools)    │
													└───────────┬──────────┘
																│ HTTPS + Basic auth
																▼
													┌──────────────────────┐
													│   I3X API (i3x4kusto) │
													└───────────┬──────────┘
																│ KQL
																▼
													┌──────────────────────┐
													│  Azure Data Explorer  │
													│  / Fabric Eventhouse  │
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

The Plant Copilot is deployed for you as part of the reference solution — there is nothing extra to set up. Its container image is built and published automatically to `ghcr.io/digitaltwinconsortium/manufacturingontologies/plantcopilot:main`, and the ARM template ([`Deployment/arm.json`](Deployment/arm.json)) provisions it as an Azure Container App wired to the in-cluster i3X app. The deployment exposes its remote MCP endpoint as the `plantCopilotMcpUrl` output, e.g. `https://<resourcesName>-plantcopilot.<region>.azurecontainerapps.io/mcp`.

To use it, add the Plant Copilot as a tool for the **Microsoft 365 Copilot** experience. Using [Microsoft Copilot Studio](https://learn.microsoft.com/microsoft-copilot-studio/agent-extend-action-mcp), add a new **Model Context Protocol** tool that points at the deployed endpoint, then publish the agent to Microsoft 365 Copilot:

- **Server name:** `Plant Copilot`
- **Server URL:** `https://<resourcesName>-plantcopilot.<region>.azurecontainerapps.io/mcp`
- **Transport:** Streamable HTTP

Once the agent is published, users can ask the plant questions directly in Microsoft 365 Copilot (in Teams, Outlook or the Microsoft 365 Copilot app), and Copilot grounds its answers in the tool results returned by the Plant Copilot.

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
