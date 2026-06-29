# Databricks notebook source
# MAGIC %md
# MAGIC # OPC UA PubSub setup and ingestion for the Manufacturing Ontologies reference solution
# MAGIC
# MAGIC This notebook is deployed and started automatically by the reference solution ARM template
# MAGIC (`Deployment/arm.json`) when Azure Databricks is selected as a second analytics option next to
# MAGIC Azure Data Explorer. It mirrors the steps documented in
# MAGIC [databricks.md](https://github.com/digitaltwinconsortium/ManufacturingOntologies/blob/main/databricks.md):
# MAGIC
# MAGIC 1. Create the Delta Lake tables for OPC UA telemetry and metadata.
# MAGIC 2. Ingest the `data` and `metadata` event hubs with Structured Streaming.
# MAGIC 3. Expand the OPC UA PubSub JSON body into the final tables.
# MAGIC 4. Create the last-known-value (LKV) view and the OEE helper functions used by the dashboard.
# MAGIC
# MAGIC The Event Hubs namespace connection string is supplied by the deployment as the
# MAGIC `eventHubsConnectionString` widget (namespace-level `RootManageSharedAccessKey`, no `EntityPath`).
# MAGIC The `azure-event-hubs-spark` Maven library is installed on the job cluster by the deployment.

# COMMAND ----------

dbutils.widgets.text("eventHubsConnectionString", "")
dbutils.widgets.text("checkpointRoot", "dbfs:/opcua/checkpoints")

connection_string = dbutils.widgets.get("eventHubsConnectionString").strip()
checkpoint_root = dbutils.widgets.get("checkpointRoot").strip().rstrip("/")

if not connection_string:
    raise ValueError(
        "eventHubsConnectionString widget is empty. Provide the namespace-level "
        "RootManageSharedAccessKey connection string of the <resourcesName>-EventHubs namespace."
    )

# The reference solution uses the default Hive metastore database for the OPC UA tables.
spark.sql("USE CATALOG hive_metastore")
spark.sql("USE DATABASE default")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 1: Create Delta Lake tables

# COMMAND ----------

spark.sql(
    """
    CREATE TABLE IF NOT EXISTS opcua_raw (
      payload STRING
    )
    USING DELTA
    """
)

spark.sql(
    """
    CREATE TABLE IF NOT EXISTS opcua_telemetry (
      Subject STRING,
      Timestamp TIMESTAMP,
      Name STRING,
      Value STRING
    )
    USING DELTA
    """
)

spark.sql(
    """
    CREATE TABLE IF NOT EXISTS opcua_metadata_raw (
      payload STRING
    )
    USING DELTA
    """
)

spark.sql(
    """
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
    USING DELTA
    """
)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 2: Ingest data from Azure Event Hubs
# MAGIC
# MAGIC Both the `data` and `metadata` messages carry their identity and timestamp inside the JSON body,
# MAGIC so the streams only cast the raw body into the `payload` column. A dedicated `databricks` consumer
# MAGIC group (created by the deployment) lets Databricks read the same event hubs without interfering with
# MAGIC the Azure Data Explorer ingestion.

# COMMAND ----------

telemetry_connection_string = connection_string + ";EntityPath=data"
metadata_connection_string = connection_string + ";EntityPath=metadata"

eh_telemetry_conf = {
    "eventhubs.connectionString": sc._jvm.org.apache.spark.eventhubs.EventHubsUtils.encrypt(
        telemetry_connection_string
    ),
    "eventhubs.consumerGroup": "databricks",
}

eh_metadata_conf = {
    "eventhubs.connectionString": sc._jvm.org.apache.spark.eventhubs.EventHubsUtils.encrypt(
        metadata_connection_string
    ),
    "eventhubs.consumerGroup": "databricks",
}

# COMMAND ----------

# Read the telemetry stream from the "data" event hub into the raw landing table.
telemetry_stream = (
    spark.readStream.format("eventhubs")
    .options(**eh_telemetry_conf)
    .load()
    .selectExpr("CAST(body AS STRING) AS payload")
)

(
    telemetry_stream.writeStream.format("delta")
    .outputMode("append")
    .option("checkpointLocation", f"{checkpoint_root}/opcua_raw")
    .table("opcua_raw")
)

# Read the metadata stream from the "metadata" event hub into the raw landing table.
metadata_stream = (
    spark.readStream.format("eventhubs")
    .options(**eh_metadata_conf)
    .load()
    .selectExpr("CAST(body AS STRING) AS payload")
)

(
    metadata_stream.writeStream.format("delta")
    .outputMode("append")
    .option("checkpointLocation", f"{checkpoint_root}/opcua_metadata_raw")
    .table("opcua_metadata_raw")
)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 3: Process and expand OPC UA PubSub messages

# COMMAND ----------

from pyspark.sql.functions import (
    from_json,
    explode,
    col,
    to_timestamp,
    coalesce,
    array,
    regexp_extract,
)

# 3a. Telemetry expansion: normalize the array/single DataSet shapes, then pivot the key-value
# Payload map into one telemetry row per field.
dataset_schema = (
    "struct<DataSetWriterId:string,Timestamp:string,"
    "Payload:map<string,struct<Value:string>>>"
)

raw_df = spark.readStream.format("delta").table("opcua_raw")

normalized_df = raw_df.withColumn(
    "messages",
    coalesce(
        from_json(col("payload"), f"array<{dataset_schema}>"),
        array(from_json(col("payload"), dataset_schema)),
    ),
)

telemetry_df = (
    normalized_df.select(explode(col("messages")).alias("msg"))
    .select(
        col("msg.DataSetWriterId").alias("Subject"),
        to_timestamp(col("msg.Timestamp")).alias("Timestamp"),
        explode(col("msg.Payload")).alias("Name", "val_struct"),
    )
    .select(
        col("Subject"),
        col("Timestamp"),
        col("Name"),
        col("val_struct.Value").alias("Value"),
    )
)

(
    telemetry_df.writeStream.format("delta")
    .outputMode("append")
    .option("checkpointLocation", f"{checkpoint_root}/opcua_telemetry")
    .table("opcua_telemetry")
)

# COMMAND ----------

# 3b. Metadata expansion: expand the Fields array into one row per field and parse the DataSetName
# into the ISA-95 hierarchy columns.
metadata_raw_stream = spark.readStream.format("delta").table("opcua_metadata_raw")

metadata_parsed = metadata_raw_stream.withColumn(
    "p",
    from_json(
        col("payload"),
        "struct<DataSetWriterId:string,Timestamp:string,"
        "MetaData:struct<Name:string,"
        "ConfigurationVersion:struct<MajorVersion:long,MinorVersion:long>,"
        "Fields:array<struct<Name:string,Description:string,BuiltInType:int,DataType:string,ValueRank:int>>>>",
    ),
)

metadata_df = (
    metadata_parsed.select(
        col("p.DataSetWriterId").alias("Subject"),
        to_timestamp(col("p.Timestamp")).alias("Timestamp"),
        col("p.MetaData.Name").alias("DataSetName"),
        col("p.MetaData.ConfigurationVersion.MajorVersion").alias("MajorVersion"),
        col("p.MetaData.ConfigurationVersion.MinorVersion").alias("MinorVersion"),
        explode(col("p.MetaData.Fields")).alias("Field"),
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
        regexp_extract(
            col("DataSetName"), r":(?:[^.]+)\.(?:[^.]+)\.(?:[^.]+)\.([^.]+)\.", 1
        ).alias("Site"),
        regexp_extract(
            col("DataSetName"),
            r":(?:[^.]+)\.(?:[^.]+)\.(?:[^.]+)\.(?:[^.]+)\.([^;]+);",
            1,
        ).alias("Enterprise"),
        regexp_extract(col("DataSetName"), r";nsu=([^;]+);", 1).alias("NamespaceUri"),
        regexp_extract(col("DataSetName"), r";nsu=[^;]+;(.+)$", 1).alias("NodeId"),
    )
)

(
    metadata_df.writeStream.format("delta")
    .outputMode("append")
    .option("checkpointLocation", f"{checkpoint_root}/opcua_metadata")
    .table("opcua_metadata")
)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 4: Last-known-value (LKV) view and OEE helper functions
# MAGIC
# MAGIC The LKV view is the Databricks equivalent of the Azure Data Explorer `opcua_metadata_lkv`
# MAGIC materialized view. The two OEE functions reproduce `CalculateOEEForStation` and
# MAGIC `CalculateOEEForLine` and are consumed by `dashboard-ontologies.lvdash.json`.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE VIEW opcua_metadata_lkv AS
# MAGIC SELECT m.*
# MAGIC FROM opcua_metadata m
# MAGIC INNER JOIN (
# MAGIC     SELECT Subject, Name, MAX(Timestamp) AS MaxTimestamp
# MAGIC     FROM opcua_metadata
# MAGIC     GROUP BY Subject, Name
# MAGIC ) latest
# MAGIC ON m.Subject = latest.Subject
# MAGIC AND m.Name = latest.Name
# MAGIC AND m.Timestamp = latest.MaxTimestamp;

# COMMAND ----------

# MAGIC %sql
# MAGIC -- Overall Equipment Effectiveness for a single station, see https://www.oee.com/calculating-oee/
# MAGIC CREATE OR REPLACE FUNCTION CalculateOEEForStation(
# MAGIC     stationName STRING,
# MAGIC     location STRING,
# MAGIC     idealCycleTime INT,
# MAGIC     shiftStartTime TIMESTAMP,
# MAGIC     shiftEndTime TIMESTAMP
# MAGIC )
# MAGIC RETURNS DOUBLE
# MAGIC RETURN
# MAGIC   SELECT
# MAGIC     CASE WHEN idealRunningTime > 0 THEN CAST(idealRunningTime - faultyTimeShift AS DOUBLE) / idealRunningTime ELSE 0 END
# MAGIC     * CASE WHEN (idealRunningTime - faultyTimeShift) > 0 THEN CAST(idealCycleTime AS DOUBLE) * (numProdShift + numScrapShift) / (idealRunningTime - faultyTimeShift) ELSE 0 END
# MAGIC     * CASE WHEN (numProdShift + numScrapShift) > 0 THEN CAST(numProdShift AS DOUBLE) / (numProdShift + numScrapShift) ELSE 0 END
# MAGIC   FROM (
# MAGIC     SELECT
# MAGIC       unix_millis(shiftEndTime) - unix_millis(shiftStartTime) AS idealRunningTime,
# MAGIC       (
# MAGIC         SELECT COALESCE(MAX(CAST(t.Value AS INT)), 0) - COALESCE(MIN(CAST(t.Value AS INT)), 0)
# MAGIC         FROM opcua_metadata_lkv m
# MAGIC         INNER JOIN opcua_telemetry t ON m.Subject = t.Subject
# MAGIC         WHERE m.DataSetName LIKE CONCAT('%', stationName, '%')
# MAGIC           AND m.DataSetName LIKE CONCAT('%', location, '%')
# MAGIC           AND t.Name = 'NumberOfManufacturedProducts'
# MAGIC           AND t.Timestamp > shiftStartTime AND t.Timestamp < shiftEndTime
# MAGIC       ) AS numProdShift,
# MAGIC       (
# MAGIC         SELECT COALESCE(MAX(CAST(t.Value AS INT)), 0) - COALESCE(MIN(CAST(t.Value AS INT)), 0)
# MAGIC         FROM opcua_metadata_lkv m
# MAGIC         INNER JOIN opcua_telemetry t ON m.Subject = t.Subject
# MAGIC         WHERE m.DataSetName LIKE CONCAT('%', stationName, '%')
# MAGIC           AND m.DataSetName LIKE CONCAT('%', location, '%')
# MAGIC           AND t.Name = 'NumberOfDiscardedProducts'
# MAGIC           AND t.Timestamp > shiftStartTime AND t.Timestamp < shiftEndTime
# MAGIC       ) AS numScrapShift,
# MAGIC       (
# MAGIC         SELECT COALESCE(SUM(CAST(t.Value AS INT)), 0)
# MAGIC         FROM opcua_metadata_lkv m
# MAGIC         INNER JOIN opcua_telemetry t ON m.Subject = t.Subject
# MAGIC         WHERE m.DataSetName LIKE CONCAT('%', stationName, '%')
# MAGIC           AND m.DataSetName LIKE CONCAT('%', location, '%')
# MAGIC           AND t.Name = 'FaultyTime'
# MAGIC           AND t.Timestamp > shiftStartTime AND t.Timestamp < shiftEndTime
# MAGIC       ) AS faultyTimeShift
# MAGIC   );

# COMMAND ----------

# MAGIC %sql
# MAGIC -- OEE for an entire production line is the minimum OEE across its stations.
# MAGIC CREATE OR REPLACE FUNCTION CalculateOEEForLine(
# MAGIC     location STRING,
# MAGIC     idealCycleTime INT,
# MAGIC     shiftStartTime TIMESTAMP,
# MAGIC     shiftEndTime TIMESTAMP
# MAGIC )
# MAGIC RETURNS DOUBLE
# MAGIC RETURN
# MAGIC   SELECT MIN(CalculateOEEForStation(station, location, idealCycleTime, shiftStartTime, shiftEndTime))
# MAGIC   FROM (
# MAGIC     SELECT DISTINCT Workcell AS station
# MAGIC     FROM opcua_metadata_lkv
# MAGIC     WHERE Site = location AND Workcell <> 'publisher'
# MAGIC   );

# COMMAND ----------

# MAGIC %md
# MAGIC ## Keep the streaming job running
# MAGIC
# MAGIC The deployment runs this notebook as a continuous job so the four ingestion/expansion streams stay
# MAGIC active. `awaitAnyTermination` blocks the notebook (and therefore the job run) until a stream stops.

# COMMAND ----------

spark.streams.awaitAnyTermination()
