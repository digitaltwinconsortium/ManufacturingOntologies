# Connect Microsoft Fabric to the Reference Solution

[Microsoft Fabric](https://learn.microsoft.com/en-us/fabric/get-started/microsoft-fabric-overview) is an all-in-one analytics solution that covers everything from data movement to data science, analytics, and business intelligence. It offers a comprehensive suite of services, including data lake, data engineering, and data integration, all in one place. You don't even need an Azure subscription for it, let alone deploy or manage any apps or services. You can get started with Microsoft Fabric [here](https://learn.microsoft.com/en-us/fabric/get-started/fabric-trial).

## Create a Fabric Eventhouse to Store your Production Line Data

1. Log into Microsoft Fabric [here](https://fabric.microsoft.com).
1. Create an `Eventhouse` by opening your workspace, selecting `New item`, then searching for and selecting `Eventhouse`. Give it a name, e.g. `opcua`, and click `Create`. Both the eventhouse and a default KQL database with the same name are created.
1. Select your KQL database. In the `Database details` pane, under the `OneLake` section, set `Availability` to `Enabled`. This will enable sharing your OPC UA time-series data from your production line within your organization via [OneLake](https://learn.microsoft.com/en-us/fabric/onelake/onelake-overview) in [Parquet file format](https://parquet.apache.org/docs/file-format/).

## Configure OPC UA PubSub Data Ingestion

These tables, mappings, functions and the materialized view mirror the ones the reference solution creates in Azure Data Explorer, so Fabric processes the OPC UA PubSub data exactly the same way ADX does.

Create the tables you need for ingesting the OPC UA PubSub data by clicking `opcua_queryset`, deleting the sample data in the text box, entering the following Kusto commands one-by-one, and then clicking `Run` for each command:

        // Create a landing table for the raw OPC UA telemetry JSON body
        .create table opcua_raw (payload: dynamic)

        // Create our final OPC UA telemetry table (one row per field, keyed by Subject + Name)
        .create table opcua_telemetry (Subject: string, Timestamp: datetime, Name: string, Value: dynamic)

        // Create a landing table for the raw OPC UA metadata JSON body
        .create table opcua_metadata_raw (payload: dynamic)

        // Create our final OPC UA metadata table (one row per field, keyed by Subject + Name)
        .create table opcua_metadata (Subject: string, Timestamp: datetime, DataSetName: string, MajorVersion: long, MinorVersion: long, Name: string, BuiltInType: int, DataType: string, ValueRank: int)

Then run the following Kusto commands one-by-one:

        // Expand telemetry into one row per field. Everything (identity, timestamp and values) lives in the JSON body, so the union just branches on the body shape: an array of DataSet messages or a single DataSet message. Both carry the DataSetWriterId and Timestamp inside the body.
        .create-or-alter function OPCUATelemetryExpand() { union (opcua_raw | where gettype(payload) == "array" | mv-expand record = payload | mv-apply field = todynamic(record["Payload"]) on (extend key = tostring(bag_keys(field)[0]) | extend p = field[key] | project Name = key, Value = todynamic(p["Value"])) | project Subject = tostring(record["DataSetWriterId"]), Timestamp = todatetime(record["Timestamp"]), Name, Value), (opcua_raw | where gettype(payload) == "dictionary" | mv-apply field = todynamic(payload["Payload"]) on (extend key = tostring(bag_keys(field)[0]) | extend p = field[key] | project Name = key, Value = todynamic(p["Value"])) | project Subject = tostring(payload["DataSetWriterId"]), Timestamp = todatetime(payload["Timestamp"]), Name, Value) | project Subject, Timestamp, Name, Value }

        // Expand the metadata message. The body is the DataSetMetaData wrapped with its DataSetWriterId and Timestamp; mv-expand over Fields produces one row per field, keyed by Subject + Name.
        .create-or-alter function OPCUAMetaDataExpand() { opcua_metadata_raw | extend meta = todynamic(payload["MetaData"]) | extend DataSetName = tostring(meta["Name"]), MajorVersion = tolong(meta["ConfigurationVersion"]["MajorVersion"]), MinorVersion = tolong(meta["ConfigurationVersion"]["MinorVersion"]) | mv-expand Field = meta["Fields"] | project Subject = tostring(payload["DataSetWriterId"]), Timestamp = todatetime(payload["Timestamp"]), DataSetName, MajorVersion, MinorVersion, Name = tostring(Field["Name"]), BuiltInType = toint(Field["BuiltInType"]), DataType = tostring(Field["DataType"]), ValueRank = toint(Field["ValueRank"]) }

        // Create a materialized view for the last known value (LKV) of our metadata
        .create materialized-view opcua_metadata_lkv on table opcua_metadata { opcua_metadata | summarize arg_max(Timestamp, *) by Subject, Name }

Then run the following Kusto commands one-by-one:

        // Create mapping from JSON ingestion to the landing table  
        .create-or-alter table opcua_raw ingestion json mapping 'opcua_mapping' '[{"column":"payload","path":"$","datatype":"dynamic"}]'
          
        // Apply the telemetry expansion function to the OPC UA raw table
        .alter table opcua_telemetry policy update @'[{"Source": "opcua_raw", "Query": "OPCUATelemetryExpand()", "IsEnabled": "True"}]'

        // Create mapping from JSON ingestion to the metadata landing table
        .create-or-alter table opcua_metadata_raw ingestion json mapping 'opcua_metadata_mapping' '[{"column":"payload","path":"$","datatype":"dynamic"}]'

        // Apply the raw metadata expansion function to the metadata landing table
        .alter table opcua_metadata policy update @'[{"Source": "opcua_metadata_raw", "Query": "OPCUAMetaDataExpand()", "IsEnabled": "True"}]'

## Connect Fabric to your existing Azure Event Hubs

The reference solution deploys an Azure Event Hubs namespace named `<resourcesName>-EventHubs` (where `<resourcesName>` is the name you chose during deployment) that already receives your OPC UA PubSub data on two event hubs:

| Event hub  | Contents                | KQL landing table    | Ingestion mapping        |
| ---------- | ----------------------- | -------------------- | ------------------------ |
| `data`     | OPC UA PubSub telemetry | `opcua_raw`          | `opcua_mapping`          |
| `metadata` | OPC UA PubSub metadata  | `opcua_metadata_raw` | `opcua_metadata_mapping` |

Both the `data` and the `metadata` messages carry their identity and time **inside the JSON body**, so each eventstream only has to route the raw body into the `payload` column - there are no message properties to surface as extra columns. The `OPCUATelemetryExpand` and `OPCUAMetaDataExpand` functions read the `DataSetWriterId`, `Timestamp` and `MetaData` straight out of `payload`.

The Azure Data Explorer (ADX) cluster deployed by the solution consumes these Event Hubs through a dedicated `adx` consumer group. To let Fabric read the same data without interfering with ADX, create a separate consumer group for Fabric on each event hub.
You will also need a connection string with at least `Listen` rights. The simplest option is the namespace-level `RootManageSharedAccessKey` policy: in the Azure portal, open your `<resourcesName>-EventHubs` namespace, select `Shared access policies` -> `RootManageSharedAccessKey` and copy the `Connection string-primary key`.

### Ingest the telemetry event hub (`data` -> `opcua_raw`)

1. In your Fabric workspace, select `New item`, then search for and select `Eventstream`. Name it e.g. `eventstream_opcua_data` and click `Create`.
1. Select `Add source` -> `Azure Event Hubs`. Under `Connection`, select `New connection` and enter your `<resourcesName>-EventHubs` namespace, the `data` event hub, and the `RootManageSharedAccessKey` shared access key name and key. Back on the source page, select the `fabric` consumer group (or `$Default`) and set `Data format` to `Json`. Select `Next`, then on the `Review + connect` page select `Add`. Finally, select `Publish` to publish the eventstream.
1. Select `Add destination` -> `Eventhouse`. Choose `Direct ingestion`, enter a `Destination name`, then select your `Workspace`, `Eventhouse`, and the KQL database you created earlier. Select `Save`, connect the destination card to your stream output if it isn't already, and select `Publish`.
1. In `Live view`, select `Configure` on the Eventhouse destination node to open the `Get data` screen. Select the existing `opcua_raw` table, keep or edit the `Data connection name`, and select `Next`. On the `Inspect the data` screen, confirm the `Format` is `JSON` (the existing `opcua_mapping` routes the raw payload into the `payload` column; you can review it via the `Table_mapping` dropdown or `Advanced` options). Select `Finish`, then select `Close` on the `Summary` screen.

### Ingest the metadata event hub (`metadata` -> `opcua_metadata_raw`)

1. Create a second eventstream by selecting `New item` -> `Eventstream`, name it e.g. `eventstream_opcua_metadata` and click `Create`.
1. Select `Add source` -> `Azure Event Hubs`. Create or select a connection exactly as above, but set the event hub to `metadata` (consumer group `fabric` or `$Default`). Set `Data format` to `Json`, select `Next`, then `Add` on the `Review + connect` page, and `Publish` the eventstream.
1. Select `Add destination` -> `Eventhouse`. Choose `Direct ingestion`, enter a `Destination name`, then select your `Workspace`, `Eventhouse`, and the same KQL database. Select `Save`, connect the destination card to your stream output if it isn't already, and select `Publish`.
1. In `Live view`, select `Configure` on the Eventhouse destination node to open the `Get data` screen. Select the existing `opcua_metadata_raw` table, keep or edit the `Data connection name`, and select `Next`. On the `Inspect the data` screen, confirm the `Format` is `JSON` (the existing `opcua_metadata_mapping` routes the raw payload into the `payload` column; you can review it via the `Table_mapping` dropdown or `Advanced` options). Select `Finish`, then select `Close` on the `Summary` screen.

Once both eventstreams are running, the update policies and the `opcua_metadata_lkv` materialized view you created above automatically expand the raw OPC UA PubSub messages into the `opcua_telemetry` and `opcua_metadata` tables, exactly like the ADX deployment.

## Create a Fabric Lakehouse to Share Your OPC UA Data within Your Organization

To share your OPC UA data via OneLake, create a `Lakehouse` by selecting `New item` in your workspace, then searching for and selecting `Lakehouse`. Give it a name, e.g. `opcua_lake`, and click `Create`.
1. Under `Tables`, select `New shortcut`, select `Microsoft OneLake`, select your KQL database, expand the `Tables` node and select `opcua_telemetry`.
1. Under `Tables`, select `New shortcut`, select `Microsoft OneLake`, select your KQL database, expand the `Tables` node and select `opcua_metadata`.

## View Your OPC UA Data Flow in Fabric

Click on your workspace, select `Lineage view` to see the entire flow of OPC UA data you have just setup in Microsoft Fabric.

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

## Useful KQL Database Helper-Functions for Advanced Queries

        .create-or-alter function QuerySpecificValue(stationName: string, productionLineName: string, valueToQuery: string, desiredValue: real) {
        opcua_metadata_lkv
        | where DataSetName contains stationName
        | where DataSetName contains productionLineName
        | join kind=inner (
            opcua_telemetry
            | where Name == valueToQuery
            | where Value == desiredValue
            | where Timestamp > ago(5m)
        ) on Subject
        | project Timestamp1
        | sort by Timestamp1 desc
        | take 1
        }

        .create-or-alter function QuerySpecificTime(stationName: string, productionLineName: string, valueToQuery: string, timeToQuery: datetime, idealCycleTime: timespan) {
        opcua_metadata_lkv
        | where DataSetName contains stationName
        | where DataSetName contains productionLineName
        | join kind=inner (
            opcua_telemetry
            | where Name == valueToQuery
            | where Timestamp > ago(5m)
        ) on Subject
        | where around(Timestamp1, timeToQuery, idealCycleTime)
        | sort by Timestamp1 desc
        | project Value
        | take 1
        }

        .create-or-alter function EnergyPerPart(productionLineName: string, idealCycleTime: timespan) {
        // check if a new part was produced (last machine in the production line, i.e. packaging, is in state 2 ("done") with a passed QA)
        // and get the part's serial number and energy consumption at that time
        let timeLatestProductWasProduced = toscalar(QuerySpecificValue("packaging", productionLineName, "Status", "2"));
        let serialNumber = toscalar(QuerySpecificTime("packaging", productionLineName, "ProductSerialNumber", timeLatestProductWasProduced, idealCycleTime));
        //
        let timePartWasProducedPackaging = toscalar(timeLatestProductWasProduced);
        let energyPackaging = toscalar(QuerySpecificTime("packaging", productionLineName, "EnergyConsumption", timePartWasProducedPackaging, idealCycleTime));
        //
        // check each other machine for the time when the product with this serial number was in the machine and get its energy comsumption at that time
        let timePartWasProducedTest = toscalar(QuerySpecificValue("test", productionLineName, "ProductSerialNumber", serialNumber));
        let energyTest = toscalar(QuerySpecificTime("test", productionLineName, "EnergyConsumption", timePartWasProducedTest, idealCycleTime));
        //
        let timePartWasProducedAssembly = toscalar(QuerySpecificValue("assembly", productionLineName, "ProductSerialNumber", serialNumber));
        let energyAssembly = toscalar(QuerySpecificTime("assembly", productionLineName, "EnergyConsumption", timePartWasProducedAssembly, idealCycleTime));
        //
        // calculate the total energy consumption for the product by summing up all the machines' energy consumptions (in kW), multiply by 1000 to get Watts and then multiply by the ideal cycle time (which is in seconds) divided by 3600 to get Wh
        let totalenergy = (todouble(energyAssembly) + todouble(energyTest) + todouble(energyPackaging)) * 1000 * todouble(format_timespan(idealCycleTime, "s")) / 3600;
        print serialNumber, timeLatestProductWasProduced, totalenergy
        }
