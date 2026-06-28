# Connect Azure Databricks to the Reference Solution

## Introduction

Most Azure users looking to store and analyze OPC UA PubSub telemetry data sent from industrial sites via a cloud broker have a powerful cloud store and analytics platform in **Azure Databricks**. Databricks provides a unified analytics platform built on Apache Spark, with native support for Delta Lake, structured streaming, and scalable data engineering — making it an excellent fit for industrial IoT workloads.

This guide uses the same body-based message format as the Azure Data Explorer (ADX) and Microsoft Fabric guides, so a **single publisher configuration drives all three databases**. Every telemetry and metadata message carries its identity (`DataSetWriterId`), timestamp and payload **inside the JSON body**. The same `data` and `metadata` event hubs therefore feed ADX, Fabric, and Databricks identically, and the Databricks expansion below mirrors the ADX/Fabric expansion functions.

This article walks you through:

1. Setting up Delta Lake tables for OPC UA PubSub telemetry and metadata
2. Ingesting data from Azure Event Hubs using Structured Streaming
3. Processing and expanding OPC UA PubSub messages with PySpark
4. Creating a last-known-value (LKV) view for OPC UA metadata
5. Importing OPC UA Information Models from the [UA Cloud Library](https://uacloudlibrary.opcfoundation.org)

## Prerequisites

- An **Azure Databricks workspace** in your Azure subscription
- The **Azure Event Hubs namespace** deployed by the reference solution, named `<resourcesName>-EventHubs` (where `<resourcesName>` is the name you chose during deployment). It already receives your OPC UA PubSub data on two event hubs: `data` (telemetry) and `metadata` (metadata).
- A login to the **UA Cloud Library**, hosted by the OPC Foundation — register for free at: [https://uacloudlibrary.opcfoundation.org/Identity/Account/Register](https://uacloudlibrary.opcfoundation.org/Identity/Account/Register)

## Step 1: Create Delta Lake Tables

First, create the Delta Lake tables that will hold your OPC UA data. Run the following SQL commands in a Databricks notebook:

```sql
-- Create a landing table for the raw OPC UA telemetry JSON body
CREATE TABLE IF NOT EXISTS opcua_raw (
  payload STRING
)
USING DELTA;

-- Create the final OPC UA telemetry table (one row per field, keyed by Subject + Name)
CREATE TABLE IF NOT EXISTS opcua_telemetry (
  Subject STRING,
  Timestamp TIMESTAMP,
  Name STRING,
  Value STRING
)
USING DELTA;

-- Create a landing table for the raw OPC UA metadata JSON body
CREATE TABLE IF NOT EXISTS opcua_metadata_raw (
  payload STRING
)
USING DELTA;

-- Create the OPC UA metadata table (one row per field; DataSetName is parsed into the ISA-95 hierarchy)
CREATE TABLE IF NOT EXISTS opcua_metadata (
  Subject STRING,
  Timestamp TIMESTAMP,
  DataSetName STRING,
  MajorVersion BIGINT,
  MinorVersion BIGINT,
  Name STRING,
  BuiltInType INT,
  DataType STRING,
  ValueRank INT,
  Type STRING,
  DisplayName STRING,
  Workcell STRING,
  Line STRING,
  Area STRING,
  Site STRING,
  Enterprise STRING,
  NamespaceUri STRING,
  NodeId STRING
)
USING DELTA;
```

## Step 2: Ingest Data from Azure Event Hubs

Use Databricks **Structured Streaming** to continuously ingest OPC UA PubSub messages from Azure Event Hubs into the raw landing tables.

The reference solution deploys an Azure Event Hubs namespace named `<resourcesName>-EventHubs` (where `<resourcesName>` is the name you chose during deployment) with two event hubs:

| Event hub  | Contents                | Delta landing table  |
| ---------- | ----------------------- | -------------------- |
| `data`     | OPC UA PubSub telemetry | `opcua_raw`          |
| `metadata` | OPC UA PubSub metadata  | `opcua_metadata_raw` |

Both the `data` and the `metadata` messages carry their identity and time **inside the JSON body**, so the streams below only have to cast the raw body into the `payload` column - there are no message properties to read. The expansion code in Step 3 reads the `DataSetWriterId`, `Timestamp` and `MetaData` straight out of `payload`, exactly like the ADX and Fabric expansion functions. This is what lets a single publisher configuration feed all three databases:

- **Azure IoT Operations (AIO)** emits its CloudEvents identity (`subject`, `time`, etc.) as `ce-`-prefixed transport headers ([binary content mode](https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/bindings/http-protocol-binding.md#31-binary-content-mode)) rather than inside the body - see the `cloudEventAttributes` setting on the [Kafka / Event Hubs](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-configure-kafka-endpoint#advanced-settings) and [MQTT](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-configure-mqtt-endpoint#advanced-settings) data flow endpoints. Add an AIO data flow [`map` transform](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-dataflow-graphs-map) (see also [Create data flows -> Transformation](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-create-dataflow#transformation)) that copies the dataset identity and timestamp into the body in the same wrapper shape the expansion expects (`DataSetWriterId`, `Timestamp`, and a `Payload`/`MetaData` object). The same body then flows through the identical logic on ADX, Fabric, and Databricks.

> **Databricks-only option:** Unlike the ADX Event Hubs data connection (which can ingest only the body), the Spark Kafka source can also surface those `ce-` headers. If you read through the Kafka endpoint with `.option("includeHeaders", "true")`, the stream gains a `headers` column (`array<struct<key: string, value: binary>>`) from which you can read the AIO `ce-subject`/`ce-time` attributes directly (cast the binary value to a string). Keeping AIO's identity in the body as above is still recommended so the *same* configuration serves ADX and Fabric too.

The Azure Data Explorer cluster deployed by the template already consumes these event hubs through a dedicated `adx` consumer group. To let Databricks read the same data without interfering with ADX, create a separate `databricks` consumer group on each event hub.
Each Event Hubs connection string below is the namespace-level `RootManageSharedAccessKey` connection string (Azure portal -> your `<resourcesName>-EventHubs` namespace -> `Shared access policies` -> `RootManageSharedAccessKey` -> `Connection string-primary key`) with the target event hub appended via `;EntityPath=...`.

> **Note:** The snippets below use the [`azure-event-hubs-spark`](https://github.com/Azure/azure-event-hubs-spark) connector. Install the `com.microsoft.azure:azure-event-hubs-spark_2.12:<version>` Maven library on your cluster. On Unity Catalog clusters or Databricks Runtime 13.3 LTS and later, use the built-in Kafka connector instead (see [Alternative: read via the Event Hubs Kafka endpoint](#alternative-read-via-the-event-hubs-kafka-endpoint)).

### Telemetry Ingestion

```python
# OPC UA telemetry is published to the "data" event hub of the
# "<resourcesName>-EventHubs" namespace deployed by the reference solution.
telemetry_connection_string = (
    "Endpoint=sb://<resourcesName>-EventHubs.servicebus.windows.net/;"
    "SharedAccessKeyName=RootManageSharedAccessKey;"
    "SharedAccessKey=<YOUR_PRIMARY_KEY>;"
    "EntityPath=data"
)

# Event Hub connection configuration for telemetry
eh_telemetry_conf = {
    "eventhubs.connectionString": sc._jvm.org.apache.spark.eventhubs
        .EventHubsUtils.encrypt(telemetry_connection_string),
    "eventhubs.consumerGroup": "databricks"
}

# Read the telemetry stream from Event Hub
telemetry_stream = (
    spark.readStream
    .format("eventhubs")
    .options(**eh_telemetry_conf)
    .load()
    .selectExpr("CAST(body AS STRING) AS payload")
)

# Write to the raw telemetry Delta table
(
    telemetry_stream.writeStream
    .format("delta")
    .outputMode("append")
    .option("checkpointLocation", "/mnt/checkpoints/opcua_raw")
    .table("opcua_raw")
)
```

### Metadata Ingestion

```python
# OPC UA metadata is published to the "metadata" event hub of the
# "<resourcesName>-EventHubs" namespace deployed by the reference solution.
metadata_connection_string = (
    "Endpoint=sb://<resourcesName>-EventHubs.servicebus.windows.net/;"
    "SharedAccessKeyName=RootManageSharedAccessKey;"
    "SharedAccessKey=<YOUR_PRIMARY_KEY>;"
    "EntityPath=metadata"
)

# Event Hub connection configuration for metadata
eh_metadata_conf = {
    "eventhubs.connectionString": sc._jvm.org.apache.spark.eventhubs
        .EventHubsUtils.encrypt(metadata_connection_string),
    "eventhubs.consumerGroup": "databricks"
}

# Read the metadata stream from Event Hub
metadata_stream = (
    spark.readStream
    .format("eventhubs")
    .options(**eh_metadata_conf)
    .load()
    .selectExpr("CAST(body AS STRING) AS payload")
)

# Write to the raw metadata Delta table
(
    metadata_stream.writeStream
    .format("delta")
    .outputMode("append")
    .option("checkpointLocation", "/mnt/checkpoints/opcua_metadata_raw")
    .table("opcua_metadata_raw")
)
```

### Alternative: read via the Event Hubs Kafka endpoint

On Unity Catalog clusters or Databricks Runtime 13.3 LTS and later, the `azure-event-hubs-spark` connector is not supported. Instead, read the same `data` and `metadata` event hubs through the built-in Kafka connector — no extra library required:

```python
EH_NAMESPACE = "<resourcesName>-EventHubs"
# Namespace-level RootManageSharedAccessKey connection string (no EntityPath here):
EH_CONNECTION_STRING = (
    "Endpoint=sb://<resourcesName>-EventHubs.servicebus.windows.net/;"
    "SharedAccessKeyName=RootManageSharedAccessKey;"
    "SharedAccessKey=<YOUR_PRIMARY_KEY>"
)
eh_sasl = (
    "kafkashaded.org.apache.kafka.common.security.plain.PlainLoginModule required "
    f'username="$ConnectionString" password="{EH_CONNECTION_STRING}";'
)

def read_eventhub(topic: str):
    return (
        spark.readStream
        .format("kafka")
        .option("kafka.bootstrap.servers", f"{EH_NAMESPACE}.servicebus.windows.net:9093")
        .option("kafka.security.protocol", "SASL_SSL")
        .option("kafka.sasl.mechanism", "PLAIN")
        .option("kafka.sasl.jaas.config", eh_sasl)
        .option("subscribe", topic)            # "data" or "metadata"
        .option("startingOffsets", "earliest")
        .load()
        .selectExpr("CAST(value AS STRING) AS payload")
    )

# Telemetry -> opcua_raw, metadata -> opcua_metadata_raw
(
    read_eventhub("data").writeStream
    .format("delta")
    .outputMode("append")
    .option("checkpointLocation", "/mnt/checkpoints/opcua_raw")
    .table("opcua_raw")
)

(
    read_eventhub("metadata").writeStream
    .format("delta")
    .outputMode("append")
    .option("checkpointLocation", "/mnt/checkpoints/opcua_metadata_raw")
    .table("opcua_metadata_raw")
)
```

Both connectors land the raw event payloads in the same `opcua_raw` and `opcua_metadata_raw` tables, so the rest of this guide works unchanged.

## Step 3: Process and Expand OPC UA PubSub Messages

Once raw data is landing in your Delta tables, use PySpark to expand the OPC UA PubSub JSON body into the final tables. Everything (identity, timestamp and values) lives in the JSON body, so the expansion just branches on the body shape: an **array** of DataSet messages (publishers usually batch several writers into one message) or a **single** DataSet message (one writer per message). Both carry the `DataSetWriterId` and `Timestamp` inside the body, exactly like the ADX/Fabric expansion functions.

### 3a. Telemetry Expansion

This step reads the raw body, normalizes both shapes into a single array of DataSet messages, and pivots the key-value `Payload` into individual telemetry rows — writing straight to `opcua_telemetry` (no intermediate table needed):

```python
from pyspark.sql.functions import from_json, explode, col, to_timestamp, coalesce, array

# A single OPC UA DataSet message: the writer id, its timestamp, and a map of field name -> { Value }
dataset_schema = "struct<DataSetWriterId:string,Timestamp:string,Payload:map<string,struct<Value:string>>>"

# Read new rows from the raw table
raw_df = spark.readStream.format("delta").table("opcua_raw")

# Parse the body as either an array of DataSet messages or a single
# DataSet message, then coalesce into a uniform array so one code path handles both shapes.
normalized_df = raw_df.withColumn(
    "messages",
    coalesce(
        from_json(col("payload"), f"array<{dataset_schema}>"),
        array(from_json(col("payload"), dataset_schema))
    )
)

# Explode the messages, then explode each Payload map into one row per field
telemetry_df = (
    normalized_df
    .select(explode(col("messages")).alias("msg"))
    .select(
        col("msg.DataSetWriterId").alias("Subject"),
        to_timestamp(col("msg.Timestamp")).alias("Timestamp"),
        explode(col("msg.Payload")).alias("Name", "val_struct")
    )
    .select(
        col("Subject"),
        col("Timestamp"),
        col("Name"),
        col("val_struct.Value").alias("Value")
    )
)

# Write to the final telemetry Delta table
(
    telemetry_df.writeStream
    .format("delta")
    .outputMode("append")
    .option("checkpointLocation", "/mnt/checkpoints/opcua_telemetry")
    .table("opcua_telemetry")
)
```

### 3c. Metadata Expansion

The metadata body is the `DataSetMetaData` wrapped with its `DataSetWriterId` and `Timestamp`. Its `Name` (the `DataSetName`) encodes the ISA-95 hierarchy using the pattern:
`<prefix>:<Workcell>.<Line>.<Area>.<Site>.<Enterprise>;nsu=<NamespaceUri>;<NodeId>`

This step expands the `Fields` array into one row per field (keyed by `Subject` + `Name`, like the ADX/Fabric materialized view) and parses the `DataSetName` into the hierarchy columns:

```python
from pyspark.sql.functions import from_json, explode, col, regexp_extract, to_timestamp

# Read from metadata raw table
metadata_raw_stream = spark.readStream.format("delta").table("opcua_metadata_raw")

# Parse the JSON body: the writer id/timestamp wrapper plus the DataSetMetaData (name, version and fields)
metadata_parsed = metadata_raw_stream.withColumn(
    "p", from_json(col("payload"),
        "struct<DataSetWriterId:string,Timestamp:string,"
        "MetaData:struct<Name:string,"
        "ConfigurationVersion:struct<MajorVersion:long,MinorVersion:long>,"
        "Fields:array<struct<Name:string,Description:string,BuiltInType:int,DataType:string,ValueRank:int>>>>"
    )
)

# Expand one row per field, and parse the DataSetName (MetaData.Name) into the ISA-95 hierarchy
metadata_df = (
    metadata_parsed
    .select(
        col("p.DataSetWriterId").alias("Subject"),
        to_timestamp(col("p.Timestamp")).alias("Timestamp"),
        col("p.MetaData.Name").alias("DataSetName"),
        col("p.MetaData.ConfigurationVersion.MajorVersion").alias("MajorVersion"),
        col("p.MetaData.ConfigurationVersion.MinorVersion").alias("MinorVersion"),
        explode(col("p.MetaData.Fields")).alias("Field")
    )
    .select(
        col("Subject"),
        col("Timestamp"),
        col("DataSetName"),
        col("MajorVersion"),
        col("MinorVersion"),
        col("Field.Name").alias("Name"),
        col("Field.BuiltInType").alias("BuiltInType"),
        col("Field.DataType").alias("DataType"),
        col("Field.ValueRank").alias("ValueRank"),
        col("Field.Description").alias("Type"),
        col("Field.Name").alias("DisplayName"),
        regexp_extract(col("DataSetName"), r":([^.]+)\.", 1).alias("Workcell"),
        regexp_extract(col("DataSetName"), r":(?:[^.]+)\.([^.]+)\.", 1).alias("Line"),
        regexp_extract(col("DataSetName"), r":(?:[^.]+)\.(?:[^.]+)\.([^.]+)\.", 1).alias("Area"),
        regexp_extract(col("DataSetName"), r":(?:[^.]+)\.(?:[^.]+)\.(?:[^.]+)\.([^.]+)\.", 1).alias("Site"),
        regexp_extract(col("DataSetName"), r":(?:[^.]+)\.(?:[^.]+)\.(?:[^.]+)\.(?:[^.]+)\.([^;]+);", 1).alias("Enterprise"),
        regexp_extract(col("DataSetName"), r";nsu=([^;]+);", 1).alias("NamespaceUri"),
        regexp_extract(col("DataSetName"), r";nsu=[^;]+;(.+)$", 1).alias("NodeId"),
    )
)

# Write to the metadata Delta table
(
    metadata_df.writeStream
    .format("delta")
    .outputMode("append")
    .option("checkpointLocation", "/mnt/checkpoints/opcua_metadata")
    .table("opcua_metadata")
)
```

## Step 4: Create a Last-Known-Value (LKV) View for Metadata

In Azure Data Explorer, this was accomplished with a **materialized view** using `arg_max`. In Databricks, you can achieve the same result with a SQL view or a scheduled merge.

### Option A: SQL View (Simple)

```sql
CREATE OR REPLACE VIEW opcua_metadata_lkv AS
SELECT m.*
FROM opcua_metadata m
INNER JOIN (
    SELECT Subject, Name, MAX(Timestamp) AS MaxTimestamp
    FROM opcua_metadata
    GROUP BY Subject, Name
) latest
ON m.Subject = latest.Subject
AND m.Name = latest.Name
AND m.Timestamp = latest.MaxTimestamp;
```

### Option B: Delta Live Tables (Production)

If you are using [Delta Live Tables](https://docs.databricks.com/en/delta-live-tables/index.html), you can define a streaming live table that maintains the LKV automatically:

```python
import dlt
from pyspark.sql.functions import col, row_number
from pyspark.sql.window import Window

@dlt.table(comment="Last known value for OPC UA metadata")
def opcua_metadata_lkv():
    w = Window.partitionBy("Subject", "Name").orderBy(col("Timestamp").desc())
    return (
        dlt.read("opcua_metadata")
        .withColumn("rn", row_number().over(w))
        .filter(col("rn") == 1)
        .drop("rn")
    )
```

## Step 5: Query Your OPC UA Data

With your data flowing into Delta Lake, you can query it using SQL or PySpark. Here is an example query that joins metadata and telemetry — equivalent to the ADX/Fabric queries. Because the telemetry `Subject` is the numeric `DataSetWriterId`, the station and production line are matched on the metadata `DataSetName` (built from the OPC UA server's ApplicationUri and NodeId) and then joined to the telemetry on `Subject`. (With Azure IoT Operations, the station and line usually aren't encoded in `DataSetName`, so point these filters at whatever your asset or dataset naming carries instead.)

```sql
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

## Summary

Azure Databricks offers a flexible, scalable, and unified analytics platform for OPC UA data. With Delta Lake, Structured Streaming, and the rich PySpark/SQL ecosystem, you get all the capabilities needed to ingest, process, contextualize, and analyze your industrial data — from the shop floor to the cloud.
