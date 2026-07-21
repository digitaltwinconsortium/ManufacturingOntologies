# Factory Line Simulation (Station)

The **Station** project is the factory-floor simulation. It emulates a production line as a set of [OPC UA](https://opcfoundation.org/about/opc-technologies/opc-ua/) servers driven by a simple **Manufacturing Execution System (MES)**, producing realistic, standards-based OPC UA telemetry that the rest of the solution ingests, normalizes and analyzes (Azure IoT Operations → Event Hubs → Azure Data Explorer / Microsoft Fabric / Azure Databricks).

Both the stations and the MES are containerized so a production line can be deployed with nothing more than environment variables.

## What it simulates

A production line is made up of three stations wired together by the MES:

| Station | Role |
|---------|------|
| **Assembly** | Assembles a new product and stamps it with a serial number. |
| **Test** | Tests the assembled product; may produce a fault or scrap. |
| **Packaging** | Packages the good product and completes the cycle. |

The MES orchestrates the flow: it calls each station's OPC UA methods to start work, watches each station's status, and moves a product from Assembly → Test → Packaging. Two production lines are deployed with different pacing:

| Production Line | Ideal Cycle Time (seconds) |
|-----------------|----------------------------|
| Munich | 6 |
| Seattle | 10 |

Work only runs during shifts (defined in [`ShiftTimes.csv`](ShiftTimes.csv)), in the local time zone of each site, with one-hour breaks between shifts:

| Shift | Start | End |
|-------|-------|-----|
| Morning | 07:00 | 14:00 |
| Afternoon | 15:00 | 22:00 |
| Night | 23:00 | 06:00 |

## OPC UA information model

Each station is an OPC UA server that exposes the [station information model](Station.NodeSet2.xml). The following node IDs are published as telemetry to the cloud:

| Node ID | Meaning |
|---------|---------|
| `i=379` | Manufactured product serial number |
| `i=385` | Number of manufactured products |
| `i=391` | Number of discarded products |
| `i=398` | Running time |
| `i=399` | Faulty time |
| `i=400` | Status (0=ready, 1=work in progress, 2=work done / good part, 3=work done / scrap, 4=fault) |
| `i=406` | Energy consumption |
| `i=412` | Ideal cycle time |
| `i=418` | Actual cycle time |
| `i=434` | Pressure |

These variables provide everything needed downstream to compute Overall Equipment Effectiveness (OEE), detect anomalies, and monitor condition and energy use.

## Capabilities

- **Realistic manufacturing behavior** — serial-number tracking, good/scrap parts, running vs. faulty time, and per-line cycle-time pacing.
- **Shift-aware operation** — stations only produce during configured shifts, per site time zone.
- **Digital feedback loop** — the Assembly station simulates rising **pressure**; when a cloud-side threshold is reached, a command is triggered back onto the station's OPC UA server to open a pressure-relief valve (`OpenPressureReleaseValve`). This demonstrates a closed-loop, cloud-to-edge control pattern (in production, such a safety-critical action would run on-premises).
- **Fault and scrap simulation** — the Test and Packaging stations can enter fault states and discard parts, producing the variability needed to exercise anomaly detection and OEE.
- **Standards-based security** — stations accept anonymous/untrusted OPC UA sessions only while in provisioning mode; once trust material is present in their PKI stores they require peer certificates to be trusted (see the main [README](../../../README.md) for the full trust-provisioning flow).

## Roles: station vs. MES

The same container image runs as either a **station** or the **MES**, selected via the `StationType` environment variable:

- `StationType=assembly` | `test` | `packaging` — runs an OPC UA **station** server.
- `StationType=mes` — runs the **MES** client that orchestrates the three stations.

Configuration for the OPC UA servers, endpoints and station metadata lives in the `Opc.Ua.*.xml` files, and per-site publisher configuration is under [`Tools/FactorySimulation/PublisherConfig`](Tools/FactorySimulation/PublisherConfig).

## Running a station locally (optional)

Run a single Assembly station locally:

```bash
docker run --rm -e StationType="assembly" ghcr.io/digitaltwinconsortium/manufacturingontologies:main
```

When deployed as part of the reference solution, the stations and MES are provisioned automatically on the simulation VM; see the main [README](../../../README.md) for the end-to-end deployment. To reduce cost the deployment hosts both the production line simulation and the edge infrastructure on a single Linux VM; in a real deployment the simulation is not required.
