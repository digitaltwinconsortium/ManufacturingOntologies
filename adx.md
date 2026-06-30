
# Industrial IoT reference solution

Manufacturers want to deploy an overall industrial IoT solution on a global scale and connect all of their production sites to this solution to increase efficiencies for each individual production site.

These increased efficiencies lead to faster production and lower energy consumption, which all lead to lowering the cost for the produced goods while increasing their quality in most cases.

The solution must be as efficient as possible and enable all required use cases such as condition monitoring, overall equipment effectiveness (OEE) calculation, forecasting, and anomaly detection. By using the insights gained from these use cases, you can then create a digital feedback loop which can then apply optimizations and other changes to the production processes.

Interoperability is the key to achieving a fast rollout of the solution architecture. The use of open standards such as OPC UA significantly helps to achieve this interoperability.

![Architecture diagram of the industrial IoT reference solution](Docs/arch.png)

## Components

- **Industrial assets**: A set of simulated and OPC UA-enabled production line stations and MES, hosted in Docker containers found in the [Station](Tools/FactorySimulation/Station) directory.
- [**UA Cloud Publisher**](https://github.com/barnstee/UA-CloudPublisher) Publishers data from your OPC UA-enabled assets to the cloud in OPC UA PubSub format.
- [**UA Cloud Commander**](https://github.com/opcfoundation/UA-CloudCommander) Receives commands from the cloud and executes them on your OPC UA-enabled assets.
- [**UA Cloud Action**](https://github.com/opcfoundation/UA-CloudAction) is an open-source reference cloud application that queries the Azure Data Explorer for a specific data value. The data value is the pressure in one of the simulated production line machines. It calls UA Cloud Commander via Azure Event Hubs when a certain threshold is reached (4,000 mbar). UA Cloud Commander then calls the OpenPressureReliefValve method on the machine via OPC UA.
- [**UA Cloud Library**](https://github.com/opcfoundation/UA-CloudLibrary) is an online store of [OPC UA Information Models, hosted by the OPC Foundation](https://uacloudlibrary.opcfoundation.org/).
- **WoT-Connectivity Solution** is a third-party containerized industrial connectivity solution supporting the [WoT-Connectivity](https://reference.opcfoundation.org/specs/OPC-10100-1/full) interface that translates from proprietary asset interfaces to OPC UA. The solution uses the W3C Web of Things descriptions as the schema to describe the industrial asset interface. Commercial implementations include ProsysOPC Forge and an open-source reference implementation is [UA Edge Translator](https://github.com/opcfoundation/ua-edgetranslator).
- [**Azure Event Hubs**](https://learn.microsoft.com/en-us/azure/event-hubs/azure-event-hubs-apache-kafka-overview) is Azure's Kafka message broker implementation.
- [**Azure Data Explorer**](https://learn.microsoft.com/en-us/azure/data-explorer/data-explorer-overview) is Azure's time-series database with rich analytics, graph support and built-in dashboards.
- [**Azure Databricks**](https://learn.microsoft.com/en-us/azure/databricks/databricks-overview) is Azure's unified analytics platform built on Apache Spark, with native support Kafka ingestion, Delta Lake, structured streaming, and scalable data engineering.

## Install the production line simulation and cloud services

Select the **Deploy** button to deploy all required resources to your Azure subscription:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fdigitaltwinconsortium%2FManufacturingOntologies%2Fmain%2FDeployment%2Farm.json)

The deployment process prompts you to provide a password for the virtual machine (VM) that hosts the production line simulation and the Edge infrastructure.

To reduce cost, the deployment creates a single Linux VM for both the production line simulation and the edge infrastructure. In a production scenario, the production line simulation isn't required.

### Optional: Add Microsoft Fabric as an analytics option

Azure Data Explorer (and optionally Azure Databricks) are the analytics paths enabled by the deployment above. After it completes, you can optionally add **Microsoft Fabric** as a third analytics option by deploying Fabric services into the **same resource group**, using the same `resourcesName` and `adminUsername`. It reuses the managed identity, Event Hubs and Container Apps environment created above and provisions a Fabric capacity, Eventhouse, eventstreams, a Lakehouse, a Real-Time Dashboard and an I3X API. **See [Fabric](fabric.md)**.

## Azure IoT Operations

The ADX update policies that expand the raw data (`OPCUATelemetryExpand` and `OPCUAMetaDataExpand`, created by the deployment) read the dataset identity and timestamp **from the message body**. They expect each event hub message to be an OPC UA PubSub DataSet message shaped like this:

```json
{
  "DataSetWriterId": "<dataset / writer id>",
  "Timestamp": "2024-01-01T00:00:00Z",
  "Payload": { "<FieldName>": { "Value": "<value>" } }
}
```

(metadata messages carry a `MetaData` object instead of `Payload`). With Azure IoT Operations, the identity instead arrives in the CloudEvent attributes (`subject`, `time`) as `ce-`/MQTT user properties, so it is missing from the body. The steps below add a data flow `map` transform that copies those attributes into the body, so ADX - and the identical logic on Fabric and Databricks - keeps working unchanged.

1. **Keep the CloudEvent attributes available to the data flow.** On the endpoints this flow uses (the local MQTT broker source and the Event Hubs/Kafka destination), set `cloudEventAttributes` to `Propagate` so `subject`, `time`, and the other attributes survive as message metadata. For the MQTT source endpoint:

   ```json
   {
     "endpointType": "Mqtt",
     "mqttSettings": {
       "host": "aio-broker:18883",
       "cloudEventAttributes": "Propagate"
     }
   }
   ```

   The Event Hubs (Kafka) destination endpoint takes the same `"cloudEventAttributes": "Propagate"` under `kafkaSettings`. See the advanced settings for the [MQTT](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-configure-mqtt-endpoint#advanced-settings) and [Kafka / Event Hubs](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-configure-kafka-endpoint#advanced-settings) endpoints.

2. **Create the data flow.** Create a data flow whose source is the AIO MQTT broker topic carrying the OPC UA telemetry and whose destination is the `data` event hub (and a second, identical flow for the `metadata` event hub). Every data flow must use the local MQTT broker endpoint as its source or destination. You can use the [operations experience](https://iotoperations.azure.com/) visual editor, `az iot ops dataflow apply --config-file <file>.json`, or Bicep - see [Create data flows](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-create-dataflow).

3. **Add the map transform.** Add a `BuiltInTransformation` operation between the source and destination. The first rule wraps every incoming dataset value field under `Payload`; the next two copy the CloudEvent identity and timestamp from the message metadata into the body:

   ```json
   {
     "operationType": "BuiltInTransformation",
     "builtInTransformationSettings": {
       "map": [
         {
           "inputs": ["*"],
           "output": "Payload.*",
           "description": "Wrap all dataset value fields under Payload"
         },
         {
           "inputs": ["$metadata.user_properties.subject"],
           "output": "DataSetWriterId",
           "description": "CloudEvent subject -> dataset identity"
         },
         {
           "inputs": ["$metadata.user_properties.time"],
           "output": "Timestamp",
           "description": "CloudEvent time -> Timestamp"
         }
       ]
     }
   }
   ```

   Notes:
   - The wildcard rule must be the **first** rule and only one is allowed per map. `"inputs": ["*"]` with `"output": "Payload.*"` nests all top-level fields under `Payload` - see the [map transform](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-dataflow-graphs-map) and the [expressions reference](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/concept-dataflow-graphs-expressions#wildcards).
   - `$metadata.user_properties.<attribute>` reads a CloudEvent attribute (an MQTT user property). In the operations experience editor, enter it with a leading `@`, for example `@$metadata.user_properties.subject`. Adjust the path to match how your endpoint surfaces the attribute (a bare `subject` user property on MQTT, or a `ce-subject` header on Kafka / Event Hubs).
   - The expansion reads `Payload.<Field>.Value`, so each value must be an object with a `Value` member (the native OPC UA dataset shape). If your connector emits flat values, add a per-field rule (or an expression) that wraps each as `{ "Value": ... }`.

4. **Repeat for metadata.** In the metadata flow, wrap the incoming metadata under `MetaData` (`"output": "MetaData.*"`) and set the same `DataSetWriterId`/`Timestamp`. Shape the `MetaData` object to match `OPCUAMetaDataExpand` - a `Name`, a `ConfigurationVersion` with `MajorVersion`/`MinorVersion`, and a `Fields` array - as defined by the `OPCUA-parsing-script` in [Deployment/arm.json](Deployment/arm.json).

After the transform, each event hub message carries the `DataSetWriterId`, `Timestamp`, and `Payload`/`MetaData` the update policy expects, so the existing ADX expansion - and the identical logic on Fabric and Databricks - works without change.

## Run the production line simulation

Use SSH to connect to the deployed VM by using the credentials you provide during the deployment. You might need to enable Just-in-time access in the Azure portal first. Go to the `/opt/ManufacturingOntologies-main/Tools/FactorySimulation` directory and run the **StartSimulation** shell script:

```bash
sudo ./StartSimulation.sh "<Your Event Hubs connection string>"
```

`<Your Event Hubs connection string>` is your Event Hubs namespace connection string. A connection string looks like:
`Endpoint=sb://ontologies.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=abcdefgh=`

If the external IP address for some Kubernetes services shows as `<pending>`, use the following command to assign the external IP address of the `traefik` service: `sudo kubectl patch service <theService> -n <the service's namespace> -p '{"spec": {"type": "LoadBalancer", "externalIPs":["<the traefik external IP address>"]}}'`.

## Use cases for condition monitoring, OEE calculation, anomaly detection, and predictions in Azure Data Explorer

You can deploy a [sample dashboard](https://github.com/digitaltwinconsortium/ManufacturingOntologies/blob/main/Tools/ADXQueries/dashboard-ontologies.json). To learn how to deploy a dashboard, see [Visualize data with Azure Data Explorer dashboards &gt; create from file](/en-us/azure/data-explorer/azure-data-explorer-dashboards#to-create-new-dashboard-from-a-file). After you import the dashboard, update its data source. Specify the HTTPS endpoint of your Azure Data Explorer server cluster in the top-right corner of the dashboard. The HTTPS endpoint looks like: `https://<ADXInstanceName>.<AzureRegion>.kusto.windows.net/`.

To display the OEE for a specific shift, select **Custom Time Range** in the **Time Range** drop-down in the top-left corner of the Azure Data Explorer Dashboard and enter the date and time from start to end of the shift you're interested in.

The production line simulation is made up of several stations, using the station OPC UA information model, and a simple manufacturing execution system (MES). Both the stations and the MES are containerized for easy deployment.

You configure the simulation to include two production lines. The default configuration is:

| Production Line | Ideal Cycle Time (in seconds) |
| --- | --- |
| Munich | 6 |
| Seattle | 10 |

| Shift Name | Start | End |
| --- | --- | --- |
| Morning | 07:00 | 14:00 |
| Afternoon | 15:00 | 22:00 |
| Night | 23:00 | 06:00 |

Shift times are in local time, specifically the time zone the virtual machine (VM) hosting the production line simulation is set to.

The station OPC UA server uses the following OPC UA node IDs for telemetry to the cloud:

- `i=379` - manufactured product serial number
- `i=385` - number of manufactured products
- `i=391` - number of discarded products
- `i=398` - running time
- `i=399` - faulty time
- `i=400` - status (0=station ready to do work, 1=work in progress, 2=work done and good part manufactured, 3=work done and scrap manufactured, 4=station in fault state)
- `i=406` - energy consumption
- `i=412` - ideal cycle time
- `i=418` - actual cycle time
- `i=434` - pressure

The solution uses a digital feedback loop to manage the pressure in a simulated station. To implement the feedback loop, the solution triggers a command from the cloud on one of the OPC UA servers in the simulation. The trigger activates when simulated time-series pressure data reaches a certain threshold. You can see the pressure of the assembly machine in the Azure Data Explorer dashboard. The pressure is released at regular intervals for the Seattle production line.

In a real-world deployment, something as critical as opening a pressure relief valve would be done on-premises. This example simply demonstrates how to achieve the digital feedback loop.

## Render the built-in Unified NameSpace (UNS) and ISA-95 model graph in Kusto Explorer

This solution implements a Unified Namespace (UNS), based on the OPC UA metadata sent to the Azure Data Explorer time-series database in the cloud. This OPC UA metadata includes the ISA-95 asset hierarchy. You can visualize the resulting graph in the [Kusto Explorer tool](/en-us/azure/data-explorer/kusto/tools/kusto-explorer).

Add a new connection to your Azure Data Explorer instance and then run the following query in Kusto Explorer:

```kql
let edges = opcua_metadata_lkv
| project source = DisplayName, target = Workcell
| join kind=fullouter (opcua_metadata_lkv
    | project source = Workcell, target = Line) on source
    | join kind=fullouter (opcua_metadata_lkv
        | project source = Line, target = Area) on source
        | join kind=fullouter (opcua_metadata_lkv
            | project source = Area, target = Site) on source
            | join kind=fullouter (opcua_metadata_lkv
                | project source = Site, target = Enterprise) on source
                | project source = coalesce(source, source1, source2, source3, source4), target = coalesce(target, target1, target2, target3, target4);
let nodes = opcua_metadata_lkv;
edges | make-graph source --> target with nodes on DisplayName
```

For best results, change the `Layout` option to `Grouped`.
