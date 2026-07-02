# Connect Azure Databricks to the Reference Solution

![Architecture diagram of the reference solution](Docs/arch.png)

## Automated deployment

The reference solution's deployment script can automatically deploy and configure Azure Databricks for you, as a **second analytics option next to Azure Data Explorer**. To enable Databricks, set the **Deploy Databricks** (`deployDatabricks`) parameter to `true`. ADX remains the default and is unaffected: Databricks reads the same `data` and `metadata` event hubs through a separate `databricks` consumer group, so both databases ingest the data side by side.

With the option enabled, the template additionally provisions:

- an **Azure Databricks workspace** named `<resourcesName>-Databricks`,
- the `databricks` consumer group on each of the `data` and `metadata` event hubs,
- a deployment script (running as the solution's managed identity) that imports the [`opcua_setup`](Tools/DatabricksQueries/opcua_setup.py) notebook and the [sample dashboard](Tools/DatabricksQueries/dashboard-ontologies.lvdash.json), creates a serverless SQL warehouse, publishes the dashboard, and starts a **continuous job** that runs the notebook.

The notebook creates the Delta tables, ingests both event hubs, expands the OPC UA PubSub messages, and creates the `opcua_metadata_lkv` view together with the `CalculateOEEForStation`/`CalculateOEEForLine` functions used by the dashboard.
Everything is created in a Unity Catalog schema named `ontologies` in your **workspace catalog** by default (the deployment resolves the catalog from the SQL warehouse's `current_catalog()`; override it with the `UC_CATALOG`/`UC_SCHEMA` deployment settings), since the legacy `hive_metastore` catalog is disabled on Unity Catalog-only workspaces and the built-in `main` catalog isn't available on workspaces that use Default Storage.
Once the deployment finishes, open the published **Ontologies** dashboard in your workspace to explore condition monitoring, OEE, energy, production and diagnostics tiles for the Munich and Seattle production lines - the Databricks equivalent of the [ADX dashboard](Tools/ADXQueries/dashboard-ontologies.json). See [Use the sample dashboard](#use-the-sample-dashboard) for details.

Select the **Deploy** button to deploy all required resources to your Azure subscription:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fdigitaltwinconsortium%2FManufacturingOntologies%2Fmain%2FDeployment%2Farm.json)

The deployment process prompts you to provide a password for the virtual machine (VM) that hosts the production line simulation and the Edge infrastructure.

To reduce cost, the deployment creates a single Linux VM for both the production line simulation and the edge infrastructure. In a production scenario, the production line simulation isn't required.

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
