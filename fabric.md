# Connect Microsoft Fabric to the Reference Solution

[Microsoft Fabric](https://learn.microsoft.com/en-us/fabric/get-started/microsoft-fabric-overview) is an all-in-one analytics solution that covers everything from data movement to data science, analytics, and business intelligence. It offers a comprehensive suite of services, including data lake, data engineering, and data integration, all in one place. You don't even need an Azure subscription for it, let alone deploy or manage any apps or services. You can get started with Microsoft Fabric [here](https://learn.microsoft.com/en-us/fabric/get-started/fabric-trial).

![Architecture diagram of the industrial IoT reference solution](Docs/fabric.png)

## Automated deployment

You can let the reference solution deploy and configure Microsoft Fabric for you, as a **third analytics option** next to Azure Data Explorer and Azure Databricks.

**Prerequisites and notes**
>
> - **Deploy the main solution first.** Fabric reuses the managed identity (`<resourcesName>-Identity`), Event Hubs namespace, Container Apps environment and the `fabric` consumer groups created by the ADX/Databricks deployment. Deploy that first (see [adx.md](adx.md)) and note the `resourcesName` and `adminUsername` you used, then deploy the Fabric template **into the same resource group**:
> - **Tenant setting (required):** The Fabric setup script calls the Fabric REST APIs as the solution's user-assigned managed identity (`<resourcesName>-Identity`), so a Fabric tenant admin must enable **Service principals can use Fabric APIs** (Fabric admin portal -> Tenant settings -> Developer settings). That setting can only be scoped to **the whole organization** or to **specific security groups** - it can't target an identity by name - so to limit it, create a Microsoft Entra security group, add the managed identity to it, and select that group. Without this, the setup script's Fabric API calls fail with `401`/`403`. Allow a few minutes after changing the tenant setting for it to propagate. (If you deploy Fabric before the setting is in place, the setup step fails with `401`/`403`; fix the setting and redeploy the Fabric template - it is idempotent and reuses any items it already created.)
> - **Capacity administration:** the solution's managed identity and the deployment's `adminUsername` are both added as capacity administrators, so you can administer the `<resourcesName>fabric` capacity from the Fabric portal as that user.

Select the **Deploy to Azure** button and supply the same `resourcesName` and `adminUsername`:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fdigitaltwinconsortium%2FManufacturingOntologies%2Fmain%2FDeployment%2Ffabric.json)

The Fabric template provisions:

- a **Microsoft Fabric F-SKU capacity** named `<resourcesName>fabric` (`F2` - the smallest and cheapest SKU),
- a deployment script (running as the solution's managed identity) that creates a Fabric workspace (`<resourcesName>-Fabric`) assigned to that capacity, an **Eventhouse** (`opcua`)
- an **I3X (Information Interoperability) API** container app named `<resourcesName>-i3x4kusto-fabric` (the same `ghcr.io/azure-samples/i3x4kusto:main` image used for ADX) that exposes the Eventhouse over the I3X REST API. Its URL is returned as the `i3x4KustoFabricUrl` template output.

## Run a Sample Data Query

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
