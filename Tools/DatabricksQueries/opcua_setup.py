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
# MAGIC Ingestion uses the built-in Spark Kafka connector against the Event Hubs Kafka endpoint, so no
# MAGIC extra Maven library is required and it also runs on Unity Catalog clusters and Databricks
# MAGIC Runtime 13.3 LTS and later.

# COMMAND ----------

dbutils.widgets.text("eventHubsConnectionString", "")
dbutils.widgets.text("checkpointRoot", "")
dbutils.widgets.text("catalog", "")
dbutils.widgets.text("schema", "ontologies")

connection_string = dbutils.widgets.get("eventHubsConnectionString").strip()
checkpoint_root = dbutils.widgets.get("checkpointRoot").strip().rstrip("/")
catalog = dbutils.widgets.get("catalog").strip()
schema = dbutils.widgets.get("schema").strip() or "ontologies"

if not connection_string:
    raise ValueError(
        "eventHubsConnectionString widget is empty. Provide the namespace-level "
        "RootManageSharedAccessKey connection string of the <resourcesName>-EventHubs namespace."
    )

# Store the OPC UA tables in Unity Catalog. The legacy hive_metastore catalog is disabled on
# UC-only workspaces, so create the target schema (if needed) and make it the session default.
# Every object below is also created and referenced with its fully-qualified `{catalog}`.`{schema}`
# name so it never depends on the session default (notebook %sql / `.table()` contexts can differ).
#
# Resolve the catalog. The built-in `main` catalog doesn't exist (and can't be created) on Unity
# Catalog workspaces that use Default Storage with no metastore storage root, so when no catalog is
# provided fall back to the cluster's current catalog (the workspace catalog), which already exists
# and is writable. The deployment passes the same resolved catalog, so the notebook, the warehouse-
# side objects and the dashboard all use the same namespace.
if not catalog:
    catalog = spark.sql("SELECT current_catalog()").collect()[0][0]

spark.sql(f"CREATE SCHEMA IF NOT EXISTS `{catalog}`.`{schema}`")
spark.sql(f"USE CATALOG `{catalog}`")
spark.sql(f"USE SCHEMA `{schema}`")

# Structured Streaming checkpoints must live in governed storage. The legacy DBFS root (dbfs:/...) is
# disabled on modern workspaces, so default the checkpoints to a Unity Catalog volume under the target
# schema. Volumes require Databricks Runtime 13.3 LTS or above.
spark.sql(f"CREATE VOLUME IF NOT EXISTS `{catalog}`.`{schema}`.checkpoints")
if not checkpoint_root:
    checkpoint_root = f"/Volumes/{catalog}/{schema}/checkpoints"

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 1: Create Delta Lake tables

# COMMAND ----------

spark.sql(
    f"""
    CREATE TABLE IF NOT EXISTS `{catalog}`.`{schema}`.opcua_raw (
      payload STRING
    )
    USING DELTA
    """
)

spark.sql(
    f"""
    CREATE TABLE IF NOT EXISTS `{catalog}`.`{schema}`.opcua_telemetry (
      Subject STRING,
      Timestamp TIMESTAMP,
      Name STRING,
      Value STRING
    )
    USING DELTA
    """
)

spark.sql(
    f"""
    CREATE TABLE IF NOT EXISTS `{catalog}`.`{schema}`.opcua_metadata_raw (
      payload STRING
    )
    USING DELTA
    """
)

spark.sql(
    f"""
    CREATE TABLE IF NOT EXISTS `{catalog}`.`{schema}`.opcua_metadata (
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
# MAGIC ## Step 2: Last-known-value (LKV) view and OEE helper functions
# MAGIC
# MAGIC The LKV view is the Databricks equivalent of the Azure Data Explorer `opcua_metadata_lkv`
# MAGIC materialized view. The two OEE functions reproduce `CalculateOEEForStation` and
# MAGIC `CalculateOEEForLine` and are consumed by `dashboard-ontologies.lvdash.json`.
# MAGIC
# MAGIC These objects only depend on the tables existing (not on any data), so they are created here -
# MAGIC before the ingestion streams start - so the dashboard can always resolve them even if a stream
# MAGIC is still warming up or temporarily fails. They are `CREATE OR REPLACE`, so re-running the
# MAGIC continuous job keeps them in sync.

# COMMAND ----------

spark.sql(
    f"""
    CREATE OR REPLACE VIEW `{catalog}`.`{schema}`.opcua_metadata_lkv AS
    SELECT m.*
    FROM `{catalog}`.`{schema}`.opcua_metadata m
    INNER JOIN (
      SELECT Subject, Name, MAX(Timestamp) AS Timestamp
      FROM `{catalog}`.`{schema}`.opcua_metadata
      GROUP BY Subject, Name
    ) latest ON m.Subject = latest.Subject AND m.Name = latest.Name AND m.Timestamp = latest.Timestamp
    """
)

# COMMAND ----------

# Overall Equipment Effectiveness for a single station, see https://www.oee.com/calculating-oee/
spark.sql(
    f"""
    CREATE OR REPLACE FUNCTION `{catalog}`.`{schema}`.CalculateOEEForStation(
        stationName STRING,
        location STRING,
        idealCycleTime INT,
        shiftStartTime TIMESTAMP,
        shiftEndTime TIMESTAMP
    )
    RETURNS DOUBLE
    RETURN
      SELECT
        CASE WHEN idealRunningTime > 0 THEN CAST(idealRunningTime - faultyTimeShift AS DOUBLE) / idealRunningTime ELSE 0 END
        * CASE WHEN (idealRunningTime - faultyTimeShift) > 0 THEN CAST(idealCycleTime AS DOUBLE) * (numProdShift + numScrapShift) / (idealRunningTime - faultyTimeShift) ELSE 0 END
        * CASE WHEN (numProdShift + numScrapShift) > 0 THEN CAST(numProdShift AS DOUBLE) / (numProdShift + numScrapShift) ELSE 0 END
      FROM (
        SELECT
          unix_millis(shiftEndTime) - unix_millis(shiftStartTime) AS idealRunningTime,
          (
            SELECT COALESCE(MAX(CAST(t.Value AS INT)), 0) - COALESCE(MIN(CAST(t.Value AS INT)), 0)
            FROM `{catalog}`.`{schema}`.opcua_metadata_lkv m
            INNER JOIN `{catalog}`.`{schema}`.opcua_telemetry t ON m.Subject = t.Subject
            WHERE m.DataSetName LIKE CONCAT('%', stationName, '%')
              AND m.DataSetName LIKE CONCAT('%', location, '%')
              AND t.Name = 'NumberOfManufacturedProducts'
              AND t.Timestamp > shiftStartTime AND t.Timestamp < shiftEndTime
          ) AS numProdShift,
          (
            SELECT COALESCE(MAX(CAST(t.Value AS INT)), 0) - COALESCE(MIN(CAST(t.Value AS INT)), 0)
            FROM `{catalog}`.`{schema}`.opcua_metadata_lkv m
            INNER JOIN `{catalog}`.`{schema}`.opcua_telemetry t ON m.Subject = t.Subject
            WHERE m.DataSetName LIKE CONCAT('%', stationName, '%')
              AND m.DataSetName LIKE CONCAT('%', location, '%')
              AND t.Name = 'NumberOfDiscardedProducts'
              AND t.Timestamp > shiftStartTime AND t.Timestamp < shiftEndTime
          ) AS numScrapShift,
          (
            SELECT COALESCE(SUM(CAST(t.Value AS INT)), 0)
            FROM `{catalog}`.`{schema}`.opcua_metadata_lkv m
            INNER JOIN `{catalog}`.`{schema}`.opcua_telemetry t ON m.Subject = t.Subject
            WHERE m.DataSetName LIKE CONCAT('%', stationName, '%')
              AND m.DataSetName LIKE CONCAT('%', location, '%')
              AND t.Name = 'FaultyTime'
              AND t.Timestamp > shiftStartTime AND t.Timestamp < shiftEndTime
          ) AS faultyTimeShift
      )
    """
)

# COMMAND ----------

# OEE for an entire production line is the minimum OEE across its stations.
spark.sql(
    f"""
    CREATE OR REPLACE FUNCTION `{catalog}`.`{schema}`.CalculateOEEForLine(
        location STRING,
        idealCycleTime INT,
        shiftStartTime TIMESTAMP,
        shiftEndTime TIMESTAMP
    )
    RETURNS DOUBLE
    RETURN
      SELECT MIN(`{catalog}`.`{schema}`.CalculateOEEForStation(station, location, idealCycleTime, shiftStartTime, shiftEndTime))
      FROM (
        SELECT DISTINCT Workcell AS station
        FROM `{catalog}`.`{schema}`.opcua_metadata_lkv
        WHERE Site = location AND Workcell <> 'publisher'
      )
    """
)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 3: Ingest data from Azure Event Hubs
# MAGIC
# MAGIC Ingestion uses the built-in Spark **Kafka** connector against the Event Hubs Kafka endpoint
# MAGIC (`<namespace>.servicebus.windows.net:9093`), so it requires no extra library and runs on Unity
# MAGIC Catalog clusters and Databricks Runtime 13.3 LTS and later. Both the `data` and `metadata`
# MAGIC messages carry their identity and timestamp inside the JSON body, so the streams only cast the
# MAGIC Kafka `value` into the `payload` column. A dedicated `databricks` consumer group (created by the
# MAGIC deployment) lets Databricks read the same event hubs without interfering with the Azure Data
# MAGIC Explorer ingestion.

# COMMAND ----------

import re

# The deployment supplies the namespace-level connection string (no EntityPath). The Event Hubs
# Kafka endpoint reuses it as the SASL password; the event hub name becomes the Kafka topic.
endpoint_match = re.search(r"Endpoint=sb://([^/;]+)", connection_string)
if not endpoint_match:
    raise ValueError(
        "Could not parse the Event Hubs namespace host from eventHubsConnectionString. Expected a "
        "connection string containing 'Endpoint=sb://<namespace>.servicebus.windows.net/'."
    )
bootstrap_servers = f"{endpoint_match.group(1)}:9093"

eh_sasl = (
    "kafkashaded.org.apache.kafka.common.security.plain.PlainLoginModule required "
    f'username="$ConnectionString" password="{connection_string}";'
)

kafka_options = {
    "kafka.bootstrap.servers": bootstrap_servers,
    "kafka.security.protocol": "SASL_SSL",
    "kafka.sasl.mechanism": "PLAIN",
    "kafka.sasl.jaas.config": eh_sasl,
    # Reuse the dedicated "databricks" consumer group created by the deployment so this ingestion
    # does not interfere with the Azure Data Explorer "adx" consumer group on the same event hubs.
    "kafka.group.id": "databricks",
    "startingOffsets": "earliest",
    "failOnDataLoss": "false",
}

# COMMAND ----------

# Read the telemetry stream from the "data" event hub (Kafka topic) into the raw landing table.
telemetry_stream = (
    spark.readStream.format("kafka")
    .option("subscribe", "data")
    .options(**kafka_options)
    .load()
    .selectExpr("CAST(value AS STRING) AS payload")
)

(
    telemetry_stream.writeStream.format("delta")
    .outputMode("append")
    .option("checkpointLocation", f"{checkpoint_root}/opcua_raw")
    .table(f"`{catalog}`.`{schema}`.opcua_raw")
)

# Read the metadata stream from the "metadata" event hub (Kafka topic) into the raw landing table.
metadata_stream = (
    spark.readStream.format("kafka")
    .option("subscribe", "metadata")
    .options(**kafka_options)
    .load()
    .selectExpr("CAST(value AS STRING) AS payload")
)

(
    metadata_stream.writeStream.format("delta")
    .outputMode("append")
    .option("checkpointLocation", f"{checkpoint_root}/opcua_metadata_raw")
    .table(f"`{catalog}`.`{schema}`.opcua_metadata_raw")
)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Step 4: Process and expand OPC UA PubSub messages

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

raw_df = spark.readStream.format("delta").table(f"`{catalog}`.`{schema}`.opcua_raw")

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
    .table(f"`{catalog}`.`{schema}`.opcua_telemetry")
)

# COMMAND ----------

# 3b. Metadata expansion: expand the Fields array into one row per field and parse the DataSetName
# into the ISA-95 hierarchy columns.
metadata_raw_stream = spark.readStream.format("delta").table(f"`{catalog}`.`{schema}`.opcua_metadata_raw")

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
    .table(f"`{catalog}`.`{schema}`.opcua_metadata")
)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Keep the streaming job running
# MAGIC
# MAGIC The deployment runs this notebook as a continuous job so the four ingestion/expansion streams stay
# MAGIC active. `awaitAnyTermination` blocks the notebook (and therefore the job run) until a stream stops.

# COMMAND ----------

spark.streams.awaitAnyTermination()
