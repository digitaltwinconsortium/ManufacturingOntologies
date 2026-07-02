# Connect Microsoft Fabric to the Reference Solution

[Microsoft Fabric](https://learn.microsoft.com/en-us/fabric/get-started/microsoft-fabric-overview) is an all-in-one analytics solution that covers everything from data movement to data science, analytics, and business intelligence. It offers a comprehensive suite of services, including data lake, data engineering, and data integration, all in one place. You don't even need an Azure subscription for it, let alone deploy or manage any apps or services. You can get started with Microsoft Fabric [here](https://learn.microsoft.com/en-us/fabric/get-started/fabric-trial).

![Architecture diagram of the reference solution](Docs/fabric.png)

## Automated deployment

The reference solution's deployment script can automatically deploy and configure Microsoft Fabric for you, as a **third analytics option** next to Azure Data Explorer and Azure Databricks.

**Prerequisites (required)**
>
> - **Deploy the main solution first:** Fabric reuses the managed identity (`<resourcesName>-Identity`), Event Hubs namespace, Container Apps environment and the `fabric` capacity created by the ADX/Databricks deployment. Deploy that first (see [adx.md](adx.md)).
> - **Enable Fabric for the tenant:** Deploying the F2 capacity in Azure does **not** turn Fabric on for your tenant. If `fabric.microsoft.com` keeps switching back to Power BI, a Fabric admin still needs to enable Fabric: Fabric portal -> Settings (gear) -> Admin portal -> Tenant settings -> Microsoft Fabric -> **Users can create Fabric items** -> Enabled (requires the *Fabric administrator* role).
> - **Enable the Fabric API setting:** The Fabric setup script calls the Fabric REST APIs as the solution's user-assigned managed identity (`<resourcesName>-Identity`), so a Fabric tenant admin must enable **Service principals can use Fabric APIs** (also shown as *Service principals can call Fabric public APIs*) under Fabric admin portal -> Tenant settings -> Developer settings.
> - **Enable service-principal workspace creation setting:** The setup script creates a Fabric workspace, which is gated by a *different* developer setting that is **disabled by default**: **Service principals can create workspaces, connections, and deployment pipelines** (Fabric admin portal -> Tenant settings -> Developer settings).

Select the **Deploy to Azure** button and choose the **same resource group you used for the main deployment**:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fdigitaltwinconsortium%2FManufacturingOntologies%2Fmain%2FDeployment%2Ffabric.json)

The deployment process prompts you to provide a password for the virtual machine (VM) that hosts the production line simulation and the Edge infrastructure.

To reduce cost, the deployment creates a single Linux VM for both the production line simulation and the edge infrastructure. In a production scenario, the production line simulation isn't required.

The Fabric template provisions:

- a deployment script (running as the solution's managed identity) that creates a Fabric workspace (`<resourcesName>-Fabric`) assigned to the existing Fabric capacity deployed earlier, an **Eventhouse** (`opcua`)
- an **I3X (Information Interoperability) API** container app named `<resourcesName>-i3x4kusto-fabric` (the same `ghcr.io/azure-samples/i3x4kusto:main` image used for ADX) that exposes the Eventhouse over the I3X REST API. Its URL is returned as the `i3x4KustoFabricUrl` template output.

## Use the sample dashboard

The reference solution ships a sample **Fabric RTI dashboard** that mirrors the use cases of the Azure Data Explorer dashboard: condition monitoring, OEE calculation, energy consumption, production and diagnostics for the Munich and Seattle production lines. The dashboard is already imported and published against the deployed EventHouse - just open it from **Dashboards** in your workspace. 

## Run a Query

Open your KQL database and select its `opcua_queryset`. Because the telemetry `Subject` is the numeric `DataSetWriterId`, the station and production line are matched on the metadata `DataSetName` (built from the OPC UA server's ApplicationUri and NodeId) and then joined to the telemetry on `Subject`. (With Azure IoT Operations, the station and line usually aren't encoded in `DataSetName`, so point these filters at whatever your asset or dataset naming carries instead.) Delete the sample queries, enter the following query in the text box, and select `Run`:

        let _startTime = ago(1h);
        let _endTime = now();
        opcua_metadata_lkv
        | where DataSetName contains "assembly"
        | where DataSetName contains "munich"
        | join kind=inner (
            opcua_telemetry
            | where Name == "Status"
            | where Timestamp > _startTime and Timestamp < _endTime
        ) on Subject
        | extend energy = todouble(Value)
        | project Timestamp1, energy
        | sort by Timestamp1 desc
        | render linechart
