# Microsoft Fabric

[Microsoft Fabric](https://learn.microsoft.com/en-us/fabric/get-started/microsoft-fabric-overview) is an all-in-one analytics solution that covers everything from data movement to data science, analytics, and business intelligence. It offers a comprehensive suite of services, including data lake, data engineering, and data integration, all in one place. You don't even need an Azure subscription for it, let alone deploy or manage any apps or services. You can get started with Microsoft Fabric [here](https://learn.microsoft.com/en-us/fabric/get-started/fabric-trial).

## Create a Fabric Eventhouse to Store your Production Line Data

To configure Microsoft Fabric for production line data, you need at least 1 OPC UA server integrated into your produciton line that support OPC UA PubSub. Alternatively, you can use an OPC UA Client/Server to OPC UA PubSub adapter app like UA Cloud Publisher used in this reference solution. Then follow these steps:

1. Log into Microsoft Fabric [here](https://fabric.microsoft.com).
1. Create a `Eventhouse` by clicking `Create` -> `See all` -> `Eventhouse` and give it a name, e.g. `opcua`. Click `Create`.
1. Under `KQL Database` and `Database details` activate the setting `OneLake availability`. This will enable sharing your OPC UA time-series data from your production line within your organization via [OneLake](https://learn.microsoft.com/en-us/fabric/onelake/onelake-overview) in [Parquet file format](https://parquet.apache.org/docs/file-format/). Click `Done`.

## Configure OPC UA PubSub Data Ingestion

Create the tables you need for ingesting the OPC UA PubSub data by clicking `Explore your data`, deleting the sample data in the text box and then entering the following Kusto commands, and then clicking on each itema dn click `Run`:

        // Create a landing table for raw OPC UA telemetry
        .create table opcua_raw(payload: dynamic)

        // Create an intermediate table to unbatch our OPC UA PubSub messages into
        .create table opcua_intermediate(DataSetWriterID: string, Timestamp: datetime, Payload: dynamic)

        // Create our final OPC UA telemetry table
        .create table opcua_telemetry (DataSetWriterID: string, Timestamp: datetime, Name: string, Value: dynamic)

        // Create a landing table for raw OPC UA metadata
        .create table opcua_metadata_raw(payload: dynamic)

        // Create an OPC UA metadata landing table
        .create table opcua_metadata(DataSetWriterID: string, Timestamp: datetime, Name: string, Type: string, DisplayName:string, Workcell: string, Line: string, Area: string, Site: string, Enterprise: string, NamespaceUri: string, NodeId: string)

Then run the following Kusto commands each:

        // Create a function to do the raw OPC UA expansion
        .create-or-alter function OPCUARawExpand() { opcua_raw | mv-expand records = payload.Messages | where records != '' | project DataSetWriterID = tostring(records["DataSetWriterId"]), Timestamp = todatetime(records["Timestamp"]), Payload = todynamic(records["Payload"]) }

        // Create a function to do the OPC UA dataset expansion
        .create-or-alter function OPCUADatasetExpand() { opcua_intermediate | mv-apply Payload on (extend key = tostring(bag_keys(Payload)[0]) | extend p = Payload[key] | project Name = key, Value = todynamic(p.Value)) }

        // Create a function to do the raw OPC UA metadata expansion
        .create-or-alter function OPCUAMetaDataExpand() { opcua_metadata_raw | parse tostring(payload.MetaData.Name) with * ":" Workcell "." Line "." Area "." Site "." Enterprise ";nsu=" NamespaceUri ";" NodeId | project DataSetWriterId = tostring(payload.DataSetWriterId), Timestamp = todatetime(payload.Timestamp), Name = tostring(payload.MetaData.Name), Type = tostring(payload.MetaData.Fields[0].Description), DisplayName = tostring(payload.MetaData.Fields[0].Name), Workcell, Line, Area, Site, Enterprise, NamespaceUri, NodeId }

        // Create a materialized view for the last known value (LKV) of our metadata
        .create materialized-view opcua_metadata_lkv on table opcua_metadata { opcua_metadata | summarize arg_max(Timestamp, *) by Name, DataSetWriterID }

Then run the following Kusto commands each:

        // Create mapping from JSON ingestion to the landing table  
        .create-or-alter table opcua_raw ingestion json mapping 'opcua_mapping' '[{"column":"payload","path":"$","datatype":"dynamic"}]'
          
        // Apply the raw expansion function to the OPC UA raw table
        .alter table opcua_intermediate policy update @'[{"Source": "opcua_raw", "Query": "OPCUARawExpand()", "IsEnabled": "True"}]'

        // Apply the dataset expansion function to the intermediate table  
        .alter table opcua_telemetry policy update @'[{"Source": "opcua_intermediate", "Query": "OPCUADatasetExpand()", "IsEnabled": "True"}]'

        // Create mapping from JSON ingestion to the metadata landing table
        .create-or-alter table opcua_metadata_raw ingestion json mapping 'opcua_metadata_mapping' '[{"column":"payload","path":"$","datatype":"dynamic"}]'

        // Apply the raw metadata expansion function to the metadata landing table
        .alter table opcua_metadata policy update @'[{"Source": "opcua_metadata_raw", "Query": "OPCUAMetaDataExpand()", "IsEnabled": "True"}]'

## Create Two Fabric Eventstreams to Ingest Data from Your Production Line

1. Create an `Eventstream` by clicking `Create` -> `See all` -> `Eventstream` and give it a name (e.g. `eventstream_opcua_telemetry`). Click `Create`. This component will receive the OPC UA PubSub production line telemetry and send it to your KQL database.
1. Click `New source` and select `Custom App` and give it a name (e.g. `opcua_telemetry`). Click `Add`. In the `Information` box, click on `Connection string-primary key` and copy it. You will need it soon when configuring UA Cloud Publisher.
1. Create another `Eventstream` by clicking `Create` -> `See all` -> `Eventstream` and give it a name (e.g. `eventstream_opcua_metadata`). Click `Create`. This component will receive the OPC UA PubSub production line metadata and send it to your KQL database.
1. Click `New source` and select `Custom App` and give it a name (e.g. `opcua_metadata`). Click `Add`. In the `Information` box, click on `Connection string-primary key` and copy it. You will need it soon when configuring UA Cloud Publisher.

## Configure UA Cloud Publisher

You can either follow the steps for connecting your own production line described [here](https://github.com/digitaltwinconsortium/ManufacturingOntologies#replacing-the-production-line-simulation-with-a-real-production-line) or you can modify the configuration of the UA Cloud Publisher setup in the production line simulation provided in this repository, for example for the Munich production line. For the latter, follow these steps:
1. Log into the VM deployed with this reference solution, open an **Administrator Powershell window** and run `Get-AksEdgeNodeAddr` as well as `kubectl get services -n munich`.
1. Open a browser on the VM and enter the IP address and port retrieved for UA Cloud Publisher in the previous step in the address field (e.g. `http://192.168.0.2:30356`) to access the UA Cloud Publisher UI.
1. In the UA Cloud Publisher UI, click `Configuration` and enter the `Connection string-primary key` from the `opcua_telemetry` custom app you copied earlier into the `Broker Password` field, enter `$ConnectionString` into the `Broker Username` field, enter the `EntityPath` into the `Broker Message Topic` (the entity path is contained at the end of the connection string and starts with "es_") and the name of your custom app into the `Broker URL` field (the custom app name is contained within the connection string and starts with `eventstream-` and ends with `.servicebus.windows.net`).
1. Select the checkbox `Use Alternative Broker For OPC UA Metadata Messages` and enter the `Connection string-primary key` from the `opcua_metadata` custom app you copied earlier into the `Alternative Broker Password` field, enter `9093` in the `Alternative Broker Port` field, enter `$ConnectionString` into the `Alternative Broker Username` field, enter the `EntityPath` into the `Broker Metadata Topic` (the entity path is contained at the end of the connection string and starts with "es_") and the name of your custom app into the `Alternative Broker URL` field (the custom app name is contained within the connection string and starts with `eventstream-` and ends with `.servicebus.windows.net`).
1. Set the `Metadata Send Interval in Seconds` to `3000`.
1. Click `Apply` at the top of the configuration page. 
1. In the UA Cloud Publisher UI, click `Diagnostics` and verify that you have a connection to Microsoft Fabric (`Connected to broker(s)` is set to `True`).
1. Back in Microsoft Fabric, select your workspace, click on your `eventstream_opcua_telemetry` event stream and select `Open Eventsteam`.
1. Click `New destination` and select `KQL Database` and give it a name (e.g. `kql_db_opcua_telemetry`). Under `Workspace`, select you Fabric workspace (e.g. `My workspace`) and under `KQL Database`, select your KQL database you setup earlier. Click `Add and configure`.
1. In the `Ingest data` popup window, under `Table`, select `Existing table`, select `opcua_raw` and click `Next: Source`. Leave everything the way it is and click `Next: Schema`. Wait a few seconds for the ingested data to be made available. Under `Data format`, select `JSON`. Under `Mapping name`, select `Use existing mapping` and select `opcua_mapping`. Click `Next: Summary`. Click `Close`.
1. Select your workspace, click on your `eventstream_opcua_metadata` event stream and select `Open Eventsteam`.
1. Click `New destination` and select `KQL Database` and give it a name (e.g. `kql_db_opcua_metadata`). Under `Workspace`, select you Fabric workspace (e.g. `My workspace`) and under `KQL Database`, select your KQL database you setup earlier. Click `Add and configure`.
1. In the `Ingest data` popup window, under `Table`, select `Existing table`, select `opcua_raw_metadata` and click `Next: Source`. Leave everything the way it is and click `Next: Schema`. Wait a few seconds for the ingested data to be made available. Under `Data format`, select `JSON`. Under `Mapping name`, select `Use existing mapping` and select `opcua_metadata_mapping`. Click `Next: Summary`. Click `Close`.

## Create a Fabric Lakehouse to Share Your OPC UA Data within Your Organization

To share your OPC UA data via OneLake, create a `Lakehouse` by clicking `Create` -> `See all` -> `Lakehouse` and give it a name, e.g. `opcua_lake`. Click `Create`.
1. Click `New shortcut`, select `Microsoft OneLake`, select your KQL database, expand the `Tables` and select `opcua_telemetry`.
1. Click `New shortcut`, select `Microsoft OneLake`, select your KQL database, expand the `Tables` and select `opcua_metadata`.

## View Your OPC UA Data Flow in Fabric

Click on your workspace, select `Lineage view` to see the entire flow of OPC UA data you have just setup in Microsoft Fabric.

## Run a Sample Data Query

Click on our KQL Database and select `Open KQL Database` followed by `Explore your data`. Delete the sample queries and enter the following query in the text box:

        let _startTime = ago(1h);
        let _endTime = now();
        opcua_metadata
        | where Name contains "assembly"
        | where Name contains "munich"
        | join kind=inner (opcua_telemetry
            | where Name == "Status"
            | where Timestamp > _startTime and Timestamp < _endTime
        ) on DataSetWriterID
        | extend energy = todouble(Value)
        | project Timestamp1, energy
        | sort by Timestamp1 desc 
        | render linechart


## Useful Helper-Functions

        .create-or-alter function QuerySpecificValue(stationName: string, productionLineName: string, valueToQuery: string, desiredValue: real) {
        opcua_metadata_lkv
        | where Name contains stationName
        | where Name contains productionLineName
        | join kind = inner(opcua_telemetry
            | where Name == valueToQuery
            | where Value == desiredValue
            | where Timestamp > ago(5m)
        ) on DataSetWriterID
        | project Timestamp1
        | sort by Timestamp1 desc
        | take 1
        }

        .create-or-alter function QuerySpecificTime(stationName: string, productionLineName: string, valueToQuery: string, timeToQuery: datetime, idealCycleTime: timespan) {
        opcua_metadata_lkv
        | where Name contains stationName
        | where Name contains productionLineName
        | join kind = inner(opcua_telemetry
            | where Name == valueToQuery
            | where Timestamp > ago(5m)
        ) on DataSetWriterID
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
