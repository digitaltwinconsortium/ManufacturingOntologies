
# Connect Azure Data Explorer to the Reference Solution

![Architecture diagram of the reference solution](Docs/arch.png)

## Automated deployment

Select the **Deploy** button to deploy all required resources to your Azure subscription:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fdigitaltwinconsortium%2FManufacturingOntologies%2Fmain%2FDeployment%2Farm.json)

The deployment process prompts you to provide a password for the virtual machine (VM) that hosts the production line simulation and the Edge infrastructure.

To reduce cost, the deployment creates a single Linux VM for both the production line simulation and the edge infrastructure. In a production scenario, the production line simulation isn't required.

> [!NOTE]
> Please be patient! The deployment takes about 95 minutes to complete. After the deployment is complete, you can access the VM via SSH using the credentials you provided during deployment.

## Use cases for condition monitoring, OEE calculation, anomaly detection, and predictions in Azure Data Explorer

You can deploy a [sample dashboard](https://github.com/digitaltwinconsortium/ManufacturingOntologies/blob/main/Tools/ADXQueries/dashboard-ontologies.json). To learn how to deploy a dashboard, see [Visualize data with Azure Data Explorer dashboards &gt; create from file](/en-us/azure/data-explorer/azure-data-explorer-dashboards#to-create-new-dashboard-from-a-file). After you import the dashboard, update its data source. Specify the HTTPS endpoint of your Azure Data Explorer server cluster in the top-right corner of the dashboard. The HTTPS endpoint looks like: `https://<ADXInstanceName>.<AzureRegion>.kusto.windows.net/`.

To display the OEE for a specific shift, select **Custom Time Range** in the **Time Range** drop-down in the top-left corner of the Azure Data Explorer Dashboard and enter the date and time from start to end of the shift you're interested in.

The sample dashboard also includes a **Unified NameSpace (UNS) / ISA-95 Graph** tile that renders the Unified Namespace / ISA-95 asset hierarchy as an interactive node-link graph.

## I3X API

An [**I3X API**](https://i3x.dev) container app named `<resourcesName>-i3x4kusto` is deployed, exposing ADX over the I3X REST API. Its URL can be retrieved from the Azure portal and the Swagger endpoint is accessible by adding /swagger to its URL.
