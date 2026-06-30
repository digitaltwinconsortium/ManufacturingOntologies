# Connect Azure Databricks to the Reference Solution

> [!IMPORTANT]
> This article is part of the [**OPC UA Reference Architecture**](README.md#opc-ua-reference-architecture), which uses **IEC 62541 standard OPC UA PubSub** to send telemetry data from the edge to the cloud. It is **not** the primary architecture. The primary architecture is [**Azure IoT Operations Overview**](https://learn.microsoft.com/en-us/azure/iot-operations/overview-iot-operations#architecture-overview), where an edge data flow sends telemetry data to the cloud over the endpoint's native protocol - so **OPC UA PubSub is not required between Azure IoT Operations and cloud endpoints**.

## Introduction

Most Azure users looking to store and analyze OPC UA PubSub telemetry data sent from industrial sites via a cloud broker have a powerful cloud store and analytics platform in **Azure Databricks**. Databricks provides a unified analytics platform built on Apache Spark, with native support for Delta Lake, structured streaming, and scalable data engineering — making it an excellent fit for industrial IoT workloads.

This guide uses the same body-based message format as the Azure Data Explorer (ADX) and Microsoft Fabric guides, so a **single configuration drives all three databases**. Every telemetry and metadata message carries its identity (`DataSetWriterId`), timestamp and payload **inside the JSON body**. The same `data` and `metadata` event hubs therefore feed ADX, Fabric, and Databricks identically, and the Databricks expansion below mirrors the ADX/Fabric expansion functions.

## Automated deployment

The reference solution's deployment script can automatically deploy and configure Azure Databricks for you, as a **second analytics option next to Azure Data Explorer**. To enable Databricks, set the **Deploy Databricks** (`deployDatabricks`) parameter to `true`. ADX remains the default and is unaffected: Databricks reads the same `data` and `metadata` event hubs through a separate `databricks` consumer group, so both databases ingest the data side by side.

With the option enabled, the template additionally provisions:

- an **Azure Databricks workspace** named `<resourcesName>-Databricks`,
- the `databricks` consumer group on each of the `data` and `metadata` event hubs,
- a deployment script (running as the solution's managed identity) that imports the [`opcua_setup`](Tools/DatabricksQueries/opcua_setup.py) notebook and the [sample dashboard](Tools/DatabricksQueries/dashboard-ontologies.lvdash.json), creates a serverless SQL warehouse, publishes the dashboard, and starts a **continuous job** that runs the notebook.

The notebook creates the Delta tables, ingests both event hubs, expands the OPC UA PubSub messages, and creates the `opcua_metadata_lkv` view together with the `CalculateOEEForStation`/`CalculateOEEForLine` functions used by the dashboard.
Everything is created in a Unity Catalog schema named `ontologies` in your **workspace catalog** by default (the deployment resolves the catalog from the SQL warehouse's `current_catalog()`; override it with the `UC_CATALOG`/`UC_SCHEMA` deployment settings), since the legacy `hive_metastore` catalog is disabled on Unity Catalog-only workspaces and the built-in `main` catalog isn't available on workspaces that use Default Storage.
Once the deployment finishes, open the published **Ontologies** dashboard in your workspace to explore condition monitoring, OEE, energy, production and diagnostics tiles for the Munich and Seattle production lines - the Databricks equivalent of the [ADX dashboard](Tools/ADXQueries/dashboard-ontologies.json). See [Use the sample dashboard](#use-the-sample-dashboard) for details.

## Use the sample dashboard

The reference solution ships a sample **AI/BI dashboard** that mirrors the use cases of the Azure Data Explorer dashboard: condition monitoring, OEE calculation, energy consumption, production and diagnostics for the Munich and Seattle production lines. The dashboard is already imported and published against a SQL warehouse - just open it from **Dashboards** in your workspace. 

## Run a Query

With your data flowing into Delta Lake, you can query it using SQL or PySpark. Here is an example query that joins metadata and telemetry — equivalent to the ADX/Fabric queries. Because the telemetry `Subject` is the numeric `DataSetWriterId`, the station and production line are matched on the metadata `DataSetName` (built from the OPC UA server's ApplicationUri and NodeId) and then joined to the telemetry on `Subject`. (With Azure IoT Operations, the station and line usually aren't encoded in `DataSetName`, so point these filters at whatever your asset or dataset naming carries instead.)

```sql
-- The notebook creates these objects in the `ontologies` schema of your workspace catalog by default.
-- Replace <your_catalog> with your workspace catalog name (run `SELECT current_catalog()` to find it).
USE CATALOG `<your_catalog>`;
USE SCHEMA ontologies;

-- Find the status of all assembly stations in Munich in the last hour
SELECT
    m.DataSetName,
    m.DisplayName,
    m.Workcell,
    m.Line,
    t.Timestamp,
    t.Value
FROM opcua_metadata_lkv m
INNER JOIN opcua_telemetry t
    ON m.Subject = t.Subject
WHERE m.DataSetName LIKE '%assembly%'
  AND m.DataSetName LIKE '%munich%'
  AND t.Name = 'Status'
  AND t.Timestamp > current_timestamp() - INTERVAL 1 HOUR;
```
