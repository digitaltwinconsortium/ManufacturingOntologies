# Connect Azure Databricks to the Reference Solution

## Introduction

Most Azure users looking to store and analyze OPC UA PubSub telemetry data sent from industrial sites via a cloud broker have a powerful cloud store and analytics platform in **Azure Databricks**. Databricks provides a unified analytics platform built on Apache Spark, with native support for Delta Lake, structured streaming, and scalable data engineering — making it an excellent fit for industrial IoT workloads.

This guide uses the same body-based message format as the Azure Data Explorer (ADX) and Microsoft Fabric guides, so a **single configuration drives all three databases**. Every telemetry and metadata message carries its identity (`DataSetWriterId`), timestamp and payload **inside the JSON body**. The same `data` and `metadata` event hubs therefore feed ADX, Fabric, and Databricks identically, and the Databricks expansion below mirrors the ADX/Fabric expansion functions.

## Automated deployment

You can let the reference solution deploy and configure Azure Databricks for you, as a **second analytics option next to Azure Data Explorer**. When you deploy the [ARM template](Deployment/arm.json), set the **Deploy Databricks** (`deployDatabricks`) parameter to `true`. ADX remains the default and is unaffected: Databricks reads the same `data` and `metadata` event hubs through a separate `databricks` consumer group, so both databases ingest the data side by side.

With the option enabled, the template additionally provisions:

- an **Azure Databricks workspace** named `<resourcesName>-Databricks`,
- the `databricks` consumer group on each of the `data` and `metadata` event hubs,
- a deployment script (running as the solution's managed identity) that imports the [`opcua_setup`](Tools/DatabricksQueries/opcua_setup.py) notebook and the [sample dashboard](Tools/DatabricksQueries/dashboard-ontologies.lvdash.json), creates a serverless SQL warehouse, publishes the dashboard, and starts a **continuous job** that runs the notebook.

The notebook creates the Delta tables, ingests both event hubs, expands the OPC UA PubSub messages, and creates the `opcua_metadata_lkv` view together with the `CalculateOEEForStation`/`CalculateOEEForLine` functions used by the dashboard.
Everything is created in a Unity Catalog schema (`main.ontologies` by default; override with the `UC_CATALOG`/`UC_SCHEMA` deployment settings), since the legacy `hive_metastore` catalog is disabled on Unity Catalog-only workspaces.
Once the deployment finishes, open the published **Ontologies** dashboard in your workspace to explore condition monitoring, OEE, energy, production and diagnostics tiles for the Munich and Seattle production lines - the Databricks equivalent of the [ADX dashboard](Tools/ADXQueries/dashboard-ontologies.json). See [Use the sample dashboard](#use-the-sample-dashboard) for details.

## Query Your OPC UA Data

With your data flowing into Delta Lake, you can query it using SQL or PySpark. Here is an example query that joins metadata and telemetry — equivalent to the ADX/Fabric queries. Because the telemetry `Subject` is the numeric `DataSetWriterId`, the station and production line are matched on the metadata `DataSetName` (built from the OPC UA server's ApplicationUri and NodeId) and then joined to the telemetry on `Subject`. (With Azure IoT Operations, the station and line usually aren't encoded in `DataSetName`, so point these filters at whatever your asset or dataset naming carries instead.)

```sql
-- The notebook creates these objects in the `main.ontologies` Unity Catalog schema by default.
USE CATALOG main;
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

## Use the sample dashboard

The reference solution ships a sample **AI/BI dashboard**, [`dashboard-ontologies.lvdash.json`](Tools/DatabricksQueries/dashboard-ontologies.lvdash.json), that mirrors the use cases of the [Azure Data Explorer dashboard](Tools/ADXQueries/dashboard-ontologies.json): condition monitoring, OEE calculation, energy consumption, production and publisher diagnostics for the Munich and Seattle production lines.

If you used the [automated deployment](#automated-deployment-recommended), the dashboard is already imported and published against a SQL warehouse - just open it from **Dashboards** in your workspace. To import it manually instead:

1. In your workspace, click **Workspace**, navigate to a folder, then choose **Import** and upload `dashboard-ontologies.lvdash.json` (or use the [Workspace Import API](https://learn.microsoft.com/azure/databricks/dashboards/tutorials/workspace-dashboard-api) with `"format": "AUTO"` and a `.lvdash.json` path).
2. Open the dashboard, attach it to a running **SQL warehouse**, and click **Publish**.

The dashboard queries the `opcua_telemetry`, `opcua_metadata_lkv`, `CalculateOEEForStation` and `CalculateOEEForLine` objects created by the notebook, in the `main.ontologies` Unity Catalog schema by default (the dataset queries are fully qualified with that catalog and schema; the automated deployment rewrites them if you override `UC_CATALOG`/`UC_SCHEMA`). Each tile filters on a fixed time window; adjust the `INTERVAL` in the dataset queries, or add a date-range dashboard parameter, to display a specific shift. The OEE cards use an ideal cycle time of 6000 ms (the default Munich line cycle time); change it in the OEE dataset queries if your simulation uses a different value.
