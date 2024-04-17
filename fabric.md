## Microsoft Fabric

[Microsoft Fabric](https://learn.microsoft.com/en-us/fabric/get-started/microsoft-fabric-overview) is an all-in-one analytics solution that covers everything from data movement to data science, analytics, and business intelligence. It offers a comprehensive suite of services, including data lake, data engineering, and data integration, all in one place. You don't even need an Azure subscription for it, let alone deploy or manage any apps or services. As a simpler alternative to the reference solution provided in this repository, you can get started with Microsoft Fabric [here](https://learn.microsoft.com/en-us/fabric/get-started/fabric-trial).

<img src="Docs/fabric.png" alt="fabric" width="900" />

To configure Microsoft Fabric for production line data, you need at least 1 OPC UA server integrated into your produciton line that support OPC UA PubSub. Alternatively, you can use an OPC UA Client/Server to OPC UA PubSub adapter app like UA Cloud Publisher used in this reference solution. Then follow these steps:

1. Log into Microsoft Fabric [here](https://fabric.microsoft.com).
1. Create a `KQL Database` by clicking `Create` -> `See all` -> `KQL Database` and give it a name, e.g. `kql_db_opcua`. Click `Create`.
1. Under `Database details`, edit the `OneLake folder` setting and set it to `Active`. This will enable sharing your OPC UA time-series data from your production line within your organization via [OneLake](https://learn.microsoft.com/en-us/fabric/onelake/onelake-overview) in [Parquet file format](https://parquet.apache.org/docs/file-format/). Click `Done`.
1. Create the tables you need for ingesting the OPC UA PubSub production line data by clicking `Check your data`, deleting the sample data in the text box and by entering the following Kusto command, one at a time and then clicking `Run` for each line:

        .create table opcua_raw(payload: dynamic)

        .create table opcua_metadata_raw (payload: dynamic) 

        .create table opcua_raw ingestion json mapping "opcua_mapping" @'[{"column":"payload","path":"$","datatype":"dynamic"}]'

        .create table opcua_metadata_raw ingestion json mapping "opcua_metadata_mapping" @'[{"column":"payload","path":"$","datatype":"dynamic"}]'

        .create table opcua_intermediate(DataSetWriterID: string, Timestamp: datetime, Payload: dynamic)

        .create table opcua_telemetry (DataSetWriterID: string, Timestamp: datetime, Name: string, Value: dynamic)

        .create table opcua_metadata (DataSetWriterID: string, Name: string) 

1. Create the OPC UA PubSub production line data parsing functions, by entering the following function definitions, one at a time, clicking `Run` for each line:

        .create-or-alter function OPCUARawExpand() {
            opcua_raw
            |mv-expand records = payload.Messages
            | where records != ''
            |project 
              DataSetWriterID = tostring(records["DataSetWriterId"]),
              Timestamp = todatetime(records["Timestamp"]),
              Payload = todynamic(records["Payload"])
         }

         .create-or-alter function OPCUADatasetExpand() {
            opcua_intermediate
            | mv-apply Payload on (
                extend key = tostring(bag_keys(Payload)[0])
                | extend p = Payload[key]
                | project Name = key, Value = todynamic(p.Value)
            )
        }

        .create-or-alter function OPCUAMetaDataExpand() {
            opcua_metadata_raw
            | project DataSetWriterId = tostring(payload.DataSetWriterId), Name = tostring(payload.MetaData.Name)
        }

1. Apply the OPC UA PubSub parsing functions to your tables, by entering the following policy updates, one at a time, clicking `Run` for each line:
 
        .alter table opcua_intermediate policy update @'[{"Source": "opcua_raw", "Query": "OPCUARawExpand()", "IsEnabled": "True"}]'

        .alter table opcua_telemetry policy update @'[{"Source": "opcua_intermediate", "Query": "OPCUADatasetExpand()", "IsEnabled": "True"}]'

        .alter table opcua_metadata policy update @'[{"Source": "opcua_metadata_raw", "Query": "OPCUAMetaDataExpand()", "IsEnabled": "True"}]'

1. Create a "Last Known Value" OPC UA PubSub metadata table to make sure you always use the latest metadata available, by entering the following materialized view definition and clicking `Run`:

        .create materialized-view opcua_metadata_lkv on table opcua_metadata
        {
            opcua_metadata
            | extend iTime = ingestion_time()
            | summarize arg_max(iTime, *) by Name, DataSetWriterID
        }

1. Create an `Eventstream` by clicking `Create` -> `See all` -> `Eventstream` and give it a name (e.g. `eventstream_opcua_telemetry`). Click `Create`. This component will receive the OPC UA PubSub production line telemetry and send it to your KQL database.
1. Click `New source` and select `Custom App` and give it a name (e.g. `opcua_telemetry`). Click `Add`. In the `Information` box, click on `Connection string-primary key` and copy it. You will need it soon when configuring UA Cloud Publisher.
1. Create another `Eventstream` by clicking `Create` -> `See all` -> `Eventstream` and give it a name (e.g. `eventstream_opcua_metadata`). Click `Create`. This component will receive the OPC UA PubSub production line metadata and send it to your KQL database.
1. Click `New source` and select `Custom App` and give it a name (e.g. `opcua_metadata`). Click `Add`. In the `Information` box, click on `Connection string-primary key` and copy it. You will need it soon when configuring UA Cloud Publisher.
1. Now configure UA Cloud Publisher. You can either follow the steps for connecting your own production line described [here](https://github.com/digitaltwinconsortium/ManufacturingOntologies#replacing-the-production-line-simulation-with-a-real-production-line) or you can modify the configuration of the UA Cloud Publisher setup in the production line simulation provided in this repository, for example for the Munich production line. For the latter, follow these steps:
   1. Log into the VM deployed with this reference solution, open an **Administrator Powershell window** and run `Get-AksEdgeNodeAddr` as well as `kubectl get services -n munich`.
   1. Open a browser on the VM and enter the IP address and port retrieved for UA Cloud Publisher in the previous step in the address field (e.g. `http://192.168.0.2:30356`) to access the UA Cloud Publisher UI.
   1. In the UA Cloud Publisher UI, click `Configuration` and enter the `Connection string-primary key` from the `opcua_telemetry` custom app you copied earlier into the `Broker Password` field, enter `$ConnectionString` into the `Broker Username` field, enter the `EntityPath` into the `Broker Message Topic` (the entity path is contained at the end of the connection string and starts with "es_") and the name of your custom app into the `Broker URL` field (the custom app name is contained within the connection string and starts with `eventstream-` and ends with `.servicebus.windows.net`).
   1. Select the checkbox `Use Alternative Broker For OPC UA Metadata Messages` and enter the `Connection string-primary key` from the `opcua_metadata` custom app you copied earlier into the `Alternative Broker Password` field, enter `9093` in the `Alternative Broker Port` field, enter `$ConnectionString` into the `Alternative Broker Username` field, enter the `EntityPath` into the `Broker Metadata Topic` (the entity path is contained at the end of the connection string and starts with "es_") and the name of your custom app into the `Alternative Broker URL` field (the custom app name is contained within the connection string and starts with `eventstream-` and ends with `.servicebus.windows.net`).
   1. Set the `Metadata Send Interval in Seconds` to `3000`.

        <img src="Docs/publisherconfig.png" alt="publisherconfig" width="900" />

   1. Click `Apply` at the top of the configuration page. 
   1. In the UA Cloud Publisher UI, click `Diagnostics` and verify that you have a connection to Microsoft Fabric (`Connected to broker(s)` is set to `True`).
1. Back in Microsoft Fabric, select your workspace, click on your `eventstream_opcua_telemetry` event stream and select `Open Eventsteam`.
1. Click `New destination` and select `KQL Database` and give it a name (e.g. `kql_db_opcua_telemetry`). Under `Workspace`, select you Fabric workspace (e.g. `My workspace`) and under `KQL Database`, select your KQL database you setup earlier. Click `Add and configure`.
1. In the `Ingest data` popup window, under `Table`, select `Existing table`, select `opcua_raw` and click `Next: Source`. Leave everything the way it is and click `Next: Schema`. Wait a few seconds for the ingested data to be made available. Under `Data format`, select `JSON`. Under `Mapping name`, select `Use existing mapping` and select `opcua_mapping`. Click `Next: Summary`. Click `Close`.
1. Select your workspace, click on your `eventstream_opcua_metadata` event stream and select `Open Eventsteam`.
1. Click `New destination` and select `KQL Database` and give it a name (e.g. `kql_db_opcua_metadata`). Under `Workspace`, select you Fabric workspace (e.g. `My workspace`) and under `KQL Database`, select your KQL database you setup earlier. Click `Add and configure`.
1. In the `Ingest data` popup window, under `Table`, select `Existing table`, select `opcua_raw_metadata` and click `Next: Source`. Leave everything the way it is and click `Next: Schema`. Wait a few seconds for the ingested data to be made available. Under `Data format`, select `JSON`. Under `Mapping name`, select `Use existing mapping` and select `opcua_metadata_mapping`. Click `Next: Summary`. Click `Close`.
1. To share your OPC UA data via OneLake, create a `Lakehouse` by clicking `Create` -> `See all` -> `Lakehouse` and give it a name, e.g. `opcua_lake`. Click `Create`.
1. Click `New shortcut`, select `Microsoft OneLake`, select your KQL database, expand the `Tables` and select `opcua_telemetry`.
1. Click `New shortcut`, select `Microsoft OneLake`, select your KQL database, expand the `Tables` and select `opcua_metadata`.
1. Click on your workspace, select `Lineage view` to see the entire flow of OPC UA data you have just setup in Microsoft Fabric:

    <img src="Docs/fabricflow.png" alt="fabricflow" width="900" />

1. Click on our KQL Database and select `Open KQL Database` followed by `Check your data`. Delete the sample queries and enter the following query in the text box:

         let _startTime = ago(1h);
         let _endTime = now();
         opcua_metadata_lkv
         | where Name contains "assembly"
         | where Name contains "munich"
         | join kind=inner (opcua_telemetry
             | where Name == "ActualCycleTime"
             | where Timestamp > _startTime and Timestamp < _endTime
         ) on DataSetWriterID
         | extend NodeValue = todouble(Value)
         | project Timestamp, NodeValue
         | sort by Timestamp desc 
         | render linechart 
