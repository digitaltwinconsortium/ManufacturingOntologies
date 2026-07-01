#!/usr/bin/env bash
#
# SetupDatabricks.sh
#
# Configures the Azure Databricks workspace that the reference solution ARM template
# (Deployment/arm.json) deploys as a second analytics option next to Azure Data Explorer.
#
# This script is executed by a Microsoft.Resources/deploymentScripts resource that runs
# under the reference solution's user-assigned managed identity (granted Contributor on
# the workspace). It:
#   1. Authenticates to the workspace with the managed identity.
#   2. Imports the opcua_setup notebook and the dashboard-ontologies AI/BI dashboard.
#   3. Creates a serverless SQL warehouse and publishes the dashboard against it.
#   4. Creates and starts a continuous job that runs the notebook, so the Delta tables
#      are created and the Event Hubs ingestion/expansion streams keep running.
#
# Required environment variables (set by the deploymentScripts resource):
#   DATABRICKS_WORKSPACE_URL        - workspace host, e.g. adb-123.4.azuredatabricks.net
#   WORKSPACE_RESOURCE_ID           - ARM resource id of the Databricks workspace
#   MANAGED_IDENTITY_CLIENT_ID      - client id of the user-assigned managed identity
#   EVENTHUBS_CONNECTION_STRING     - namespace-level RootManageSharedAccessKey (no EntityPath)
#   NOTEBOOK_URL                    - raw URL of Tools/DatabricksQueries/opcua_setup.py
#   DASHBOARD_URL                   - raw URL of Tools/DatabricksQueries/dashboard-ontologies.lvdash.json
#
# Optional environment variables (defaults shown):
#   WORKSPACE_FOLDER=/Shared/ManufacturingOntologies
#   WAREHOUSE_NAME=ManufacturingOntologies
#   JOB_NAME=ManufacturingOntologies-OPCUA-Ingestion
#   DATABRICKS_RUNTIME=15.4.x-scala2.12
#   NODE_TYPE_ID=Standard_DS3_v2
#   UC_CATALOG=<workspace catalog>   (default: the SQL warehouse's current_catalog())
#   UC_SCHEMA=ontologies

set -euo pipefail

# Exported so the python3 helpers and heredocs below can read them via os.environ.
export WORKSPACE_FOLDER="${WORKSPACE_FOLDER:-/Shared/ManufacturingOntologies}"
export WAREHOUSE_NAME="${WAREHOUSE_NAME:-ManufacturingOntologies}"
export JOB_NAME="${JOB_NAME:-ManufacturingOntologies-OPCUA-Ingestion}"
# Databricks Runtime 13.3 LTS or above is required on workspaces where legacy access / legacy DBFS are
# disabled (older runtimes are rejected, and Unity Catalog volumes for checkpoints need 13.3+).
export DATABRICKS_RUNTIME="${DATABRICKS_RUNTIME:-15.4.x-scala2.12}"
export NODE_TYPE_ID="${NODE_TYPE_ID:-Standard_DS3_v2}"
# UC_CATALOG is intentionally left unset by default here. Many Unity Catalog workspaces use Default
# Storage with no metastore storage root, where the built-in `main` catalog doesn't exist and can't be
# created without a managed location. When UC_CATALOG isn't provided, we resolve it below from the SQL
# warehouse's current catalog (the workspace catalog), which already exists and is writable.
export UC_CATALOG="${UC_CATALOG:-}"
export UC_SCHEMA="${UC_SCHEMA:-ontologies}"

export NOTEBOOK_PATH="${WORKSPACE_FOLDER}/opcua_setup"
export DASHBOARD_PATH="${WORKSPACE_FOLDER}/dashboard-ontologies.lvdash.json"

# Programmatic id of the Azure Databricks login application (constant for all tenants).
DATABRICKS_LOGIN_APP_ID="2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "Logging in with the user-assigned managed identity..."
az login --identity --username "${MANAGED_IDENTITY_CLIENT_ID}" --output none

echo "Acquiring access tokens..."
# Exported so the python3-based api() helper below can read them via os.environ.
export DATABRICKS_AAD_TOKEN="$(az account get-access-token --resource "${DATABRICKS_LOGIN_APP_ID}" --query accessToken -o tsv)"
export ARM_TOKEN="$(az account get-access-token --resource https://management.core.windows.net/ --query accessToken -o tsv)"

# Parse a top-level field out of a JSON document using Python (always present in the azure-cli image).
json_get() {
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1], '') if isinstance(d, dict) else '')" "$1"
}

# Call the Databricks REST API. Usage: api METHOD PATH [BODY_FILE]
# Implemented with python3 (always present in the azure-cli image) because curl
# is not included in current Microsoft.Resources/deploymentScripts images.
api() {
    local method="$1"
    local path="$2"
    local body_file="${3:-}"
    DATABRICKS_API_URL="https://${DATABRICKS_WORKSPACE_URL}${path}" \
    DATABRICKS_API_METHOD="${method}" \
    DATABRICKS_API_BODY_FILE="${body_file}" \
    python3 - <<'PY'
import os, sys, urllib.error, urllib.request

url = os.environ["DATABRICKS_API_URL"]
method = os.environ["DATABRICKS_API_METHOD"]
body_file = os.environ.get("DATABRICKS_API_BODY_FILE", "")

data = None
headers = {
    "Authorization": "Bearer " + os.environ["DATABRICKS_AAD_TOKEN"],
    "X-Databricks-Azure-SP-Management-Token": os.environ["ARM_TOKEN"],
    "X-Databricks-Azure-Workspace-Resource-Id": os.environ["WORKSPACE_RESOURCE_ID"],
}
if body_file:
    with open(body_file, "rb") as body:
        data = body.read()
    headers["Content-Type"] = "application/json"

request = urllib.request.Request(url, data=data, headers=headers, method=method)
try:
    with urllib.request.urlopen(request) as response:
        sys.stdout.buffer.write(response.read())
except urllib.error.HTTPError as error:
    # Match `curl -sS` (without -f): emit the response body and exit 0 so callers
    # that parse the payload keep working unchanged.
    sys.stdout.buffer.write(error.read())
except urllib.error.URLError:
    # Connection-level failure: exit non-zero like curl so the reachability retry
    # loop keeps polling until the workspace control plane is ready.
    sys.exit(1)
PY
}

# Download a URL to a local file using python3 (curl is not available in the image).
# Usage: download URL DEST_FILE
download() {
    DOWNLOAD_URL="$1" DOWNLOAD_DEST="$2" python3 - <<'PY'
import os, shutil, urllib.request

with urllib.request.urlopen(os.environ["DOWNLOAD_URL"]) as response, \
        open(os.environ["DOWNLOAD_DEST"], "wb") as destination:
    shutil.copyfileobj(response, destination)
PY
}

echo "Waiting for the Databricks workspace control plane to become reachable..."
for attempt in $(seq 1 30); do
    if api GET "/api/2.0/workspace/get-status?path=%2F" >/dev/null 2>&1; then
        echo "Workspace is reachable."
        break
    fi
    echo "  attempt ${attempt}/30 - not ready yet, retrying in 20s..."
    sleep 20
done

echo "Creating workspace folder ${WORKSPACE_FOLDER}..."
python3 - "${WORKSPACE_FOLDER}" >"${TMP_DIR}/mkdirs.json" <<'PY'
import json, sys
print(json.dumps({"path": sys.argv[1]}))
PY
api POST "/api/2.0/workspace/mkdirs" "${TMP_DIR}/mkdirs.json" >/dev/null

echo "Downloading and importing the opcua_setup notebook..."
download "${NOTEBOOK_URL}" "${TMP_DIR}/opcua_setup.py"
python3 - "${NOTEBOOK_PATH}" "${TMP_DIR}/opcua_setup.py" >"${TMP_DIR}/import_notebook.json" <<'PY'
import base64, json, sys
path, source = sys.argv[1], sys.argv[2]
content = base64.b64encode(open(source, "rb").read()).decode()
print(json.dumps({
    "path": path,
    "format": "SOURCE",
    "language": "PYTHON",
    "content": content,
    "overwrite": True,
}))
PY
api POST "/api/2.0/workspace/import" "${TMP_DIR}/import_notebook.json" >/dev/null

echo "Creating or reusing the '${WAREHOUSE_NAME}' SQL warehouse..."
WAREHOUSE_ID="$(api GET "/api/2.0/sql/warehouses" | python3 -c "import json,sys,os; d=json.load(sys.stdin); print(next((w['id'] for w in d.get('warehouses', []) if w.get('name')==os.environ['WAREHOUSE_NAME']), ''))")"
if [ -z "${WAREHOUSE_ID}" ]; then
    python3 - "${WAREHOUSE_NAME}" >"${TMP_DIR}/warehouse.json" <<'PY'
import json, sys
print(json.dumps({
    "name": sys.argv[1],
    "cluster_size": "2X-Small",
    "min_num_clusters": 1,
    "max_num_clusters": 1,
    "auto_stop_mins": 10,
    "enable_serverless_compute": True,
    "warehouse_type": "PRO",
}))
PY
    WAREHOUSE_ID="$(api POST "/api/2.0/sql/warehouses" "${TMP_DIR}/warehouse.json" | json_get id)"
fi
echo "  warehouse id: ${WAREHOUSE_ID}"

# Runs a single SQL statement on the warehouse and waits for it to finish. Echoes the first column of
# the first result row (empty for DDL). Usage: result="$(run_sql "<SQL>")"
run_sql() {
    local statement="$1"
    python3 - "${WAREHOUSE_ID}" "${statement}" >"${TMP_DIR}/sql_request.json" <<'PY'
import json, sys
print(json.dumps({"warehouse_id": sys.argv[1], "statement": sys.argv[2], "wait_timeout": "50s"}))
PY
    local response state statement_id
    response="$(api POST "/api/2.0/sql/statements" "${TMP_DIR}/sql_request.json")"
    state="$(printf '%s' "${response}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',{}).get('state',''))")"
    statement_id="$(printf '%s' "${response}" | json_get statement_id)"

    # Poll while the statement is still running (statements that exceed wait_timeout return PENDING/RUNNING).
    while [ "${state}" = "PENDING" ] || [ "${state}" = "RUNNING" ]; do
        sleep 5
        response="$(api GET "/api/2.0/sql/statements/${statement_id}")"
        state="$(printf '%s' "${response}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',{}).get('state',''))")"
    done

    if [ "${state}" != "SUCCEEDED" ]; then
        local message
        message="$(printf '%s' "${response}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',{}).get('error',{}).get('message',''))")"
        echo "ERROR: warehouse SQL statement failed (state=${state}): ${message}" >&2
        echo "       Statement: ${statement}" >&2
        echo "       Ensure the deployment identity can CREATE on catalog '${UC_CATALOG}' and schema '${UC_SCHEMA}', or set UC_CATALOG to a catalog you own." >&2
        exit 1
    fi

    # Return the first cell of the first row, if any (used to read current_catalog()).
    printf '%s' "${response}" | python3 -c "import json,sys; d=json.load(sys.stdin); r=(d.get('result') or {}).get('data_array') or []; print(r[0][0] if r and r[0] else '')"
}

# Resolve the target Unity Catalog catalog. If the caller didn't set UC_CATALOG, use the warehouse's
# current catalog (the workspace catalog), which exists and is writable. This avoids the built-in
# `main` catalog, which doesn't exist (and can't be created) on Default Storage metastores.
if [ -z "${UC_CATALOG}" ]; then
    UC_CATALOG="$(run_sql "SELECT current_catalog()")"
    if [ -z "${UC_CATALOG}" ] || [ "${UC_CATALOG}" = "spark_catalog" ]; then
        echo "ERROR: could not resolve a usable Unity Catalog catalog from the warehouse (got '${UC_CATALOG}'). Set UC_CATALOG to a catalog you own." >&2
        exit 1
    fi
    export UC_CATALOG
fi
echo "Using Unity Catalog catalog '${UC_CATALOG}', schema '${UC_SCHEMA}'."

echo "Downloading and importing the AI/BI dashboard..."
download "${DASHBOARD_URL}" "${TMP_DIR}/dashboard.lvdash.json"
# Repoint the dashboard's Unity Catalog namespace to match the notebook job (the file ships with
# the `main`.`ontologies` default; this applies any UC_CATALOG/UC_SCHEMA override).
python3 - "${TMP_DIR}/dashboard.lvdash.json" <<'PY'
import os, sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
content = content.replace(
    "`main`.`ontologies`",
    "`{0}`.`{1}`".format(os.environ["UC_CATALOG"], os.environ["UC_SCHEMA"]),
)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
PY
python3 - "${DASHBOARD_PATH}" "${TMP_DIR}/dashboard.lvdash.json" >"${TMP_DIR}/import_dashboard.json" <<'PY'
import base64, json, sys
path, source = sys.argv[1], sys.argv[2]
content = base64.b64encode(open(source, "rb").read()).decode()
print(json.dumps({
    "path": path,
    "format": "AUTO",
    "content": content,
    "overwrite": True,
}))
PY
api POST "/api/2.0/workspace/import" "${TMP_DIR}/import_dashboard.json" >/dev/null

echo "Retrieving the dashboard resource id..."
ENCODED_DASHBOARD_PATH="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${DASHBOARD_PATH}")"
DASHBOARD_RESOURCE_ID="$(api GET "/api/2.0/workspace/get-status?path=${ENCODED_DASHBOARD_PATH}" | json_get resource_id)"
echo "  dashboard resource id: ${DASHBOARD_RESOURCE_ID}"

# Create the schema objects the dashboard depends on (schema, tables, last-known-value view and the
# OEE functions) synchronously through the SQL warehouse - the same compute and identity the published
# dashboard uses. The continuous notebook job also creates these (idempotent CREATE OR REPLACE), but
# doing it here guarantees they exist before the dashboard is published and surfaces any permission
# problem during deployment instead of failing silently with [UNRESOLVED_ROUTINE] later. The catalog
# itself was resolved (and is known to exist) above, so it is not created here.
echo "Creating the '${UC_CATALOG}.${UC_SCHEMA}' schema objects and OEE functions on the warehouse..."
run_sql "CREATE SCHEMA IF NOT EXISTS \`${UC_CATALOG}\`.\`${UC_SCHEMA}\`" >/dev/null
run_sql "CREATE VOLUME IF NOT EXISTS \`${UC_CATALOG}\`.\`${UC_SCHEMA}\`.checkpoints" >/dev/null
run_sql "CREATE TABLE IF NOT EXISTS \`${UC_CATALOG}\`.\`${UC_SCHEMA}\`.opcua_telemetry (Subject STRING, Timestamp TIMESTAMP, Name STRING, Value STRING) USING DELTA" >/dev/null
run_sql "CREATE TABLE IF NOT EXISTS \`${UC_CATALOG}\`.\`${UC_SCHEMA}\`.opcua_metadata (Subject STRING, Timestamp TIMESTAMP, DataSetName STRING, MajorVersion BIGINT, MinorVersion BIGINT, Name STRING, BuiltInType INT, DataType STRING, ValueRank INT, Type STRING, DisplayName STRING, Workcell STRING, Line STRING, Area STRING, Site STRING, Enterprise STRING, NamespaceUri STRING, NodeId STRING) USING DELTA" >/dev/null
run_sql "CREATE OR REPLACE VIEW \`${UC_CATALOG}\`.\`${UC_SCHEMA}\`.opcua_metadata_lkv AS SELECT m.* FROM \`${UC_CATALOG}\`.\`${UC_SCHEMA}\`.opcua_metadata m INNER JOIN (SELECT Subject, Name, MAX(Timestamp) AS MaxTimestamp FROM \`${UC_CATALOG}\`.\`${UC_SCHEMA}\`.opcua_metadata GROUP BY Subject, Name) latest ON m.Subject = latest.Subject AND m.Name = latest.Name AND m.Timestamp = latest.MaxTimestamp" >/dev/null
run_sql "CREATE OR REPLACE FUNCTION \`${UC_CATALOG}\`.\`${UC_SCHEMA}\`.CalculateOEEForStation(stationName STRING, location STRING, idealCycleTime INT, shiftStartTime TIMESTAMP, shiftEndTime TIMESTAMP) RETURNS DOUBLE RETURN SELECT CASE WHEN idealRunningTime > 0 THEN CAST(idealRunningTime - faultyTimeShift AS DOUBLE) / idealRunningTime ELSE 0 END * CASE WHEN (idealRunningTime - faultyTimeShift) > 0 THEN CAST(idealCycleTime AS DOUBLE) * (numProdShift + numScrapShift) / (idealRunningTime - faultyTimeShift) ELSE 0 END * CASE WHEN (numProdShift + numScrapShift) > 0 THEN CAST(numProdShift AS DOUBLE) / (numProdShift + numScrapShift) ELSE 0 END FROM (SELECT unix_millis(shiftEndTime) - unix_millis(shiftStartTime) AS idealRunningTime, COALESCE(prod.numProdShift, 0) AS numProdShift, COALESCE(prod.numScrapShift, 0) AS numScrapShift, COALESCE(prod.faultyTimeShift, 0) AS faultyTimeShift FROM (SELECT MAX(CASE WHEN t.Name = 'NumberOfManufacturedProducts' THEN CAST(t.Value AS INT) END) - MIN(CASE WHEN t.Name = 'NumberOfManufacturedProducts' THEN CAST(t.Value AS INT) END) AS numProdShift, MAX(CASE WHEN t.Name = 'NumberOfDiscardedProducts' THEN CAST(t.Value AS INT) END) - MIN(CASE WHEN t.Name = 'NumberOfDiscardedProducts' THEN CAST(t.Value AS INT) END) AS numScrapShift, SUM(CASE WHEN t.Name = 'FaultyTime' THEN CAST(t.Value AS INT) END) AS faultyTimeShift FROM \`${UC_CATALOG}\`.\`${UC_SCHEMA}\`.opcua_metadata_lkv m INNER JOIN \`${UC_CATALOG}\`.\`${UC_SCHEMA}\`.opcua_telemetry t ON m.Subject = t.Subject WHERE m.DataSetName LIKE CONCAT('%', stationName, '%') AND m.DataSetName LIKE CONCAT('%', location, '%') AND t.Timestamp > shiftStartTime AND t.Timestamp < shiftEndTime) prod)" >/dev/null
run_sql "CREATE OR REPLACE FUNCTION \`${UC_CATALOG}\`.\`${UC_SCHEMA}\`.CalculateOEEForLine(location STRING, idealCycleTime INT, shiftStartTime TIMESTAMP, shiftEndTime TIMESTAMP) RETURNS DOUBLE RETURN SELECT MIN(\`${UC_CATALOG}\`.\`${UC_SCHEMA}\`.CalculateOEEForStation(station, location, idealCycleTime, shiftStartTime, shiftEndTime)) FROM (SELECT DISTINCT Workcell AS station FROM \`${UC_CATALOG}\`.\`${UC_SCHEMA}\`.opcua_metadata_lkv WHERE Site = location AND Workcell <> 'publisher')" >/dev/null
echo "  schema objects and OEE functions created."

# Grant read/execute access so users and the dashboard's viewers can query the objects. The schema and
# its objects are owned by the deployment's managed identity, so without these grants other principals
# hit [INSUFFICIENT_PERMISSIONS] (USE SCHEMA) and the dashboard tiles return 0. Schema-level grants
# inherit to all current and future tables, views and functions. Override the grantee with UC_GRANTEE
# (default `account users`, the built-in group covering every workspace user).
UC_GRANTEE="${UC_GRANTEE:-account users}"
echo "Granting read/execute on '${UC_CATALOG}.${UC_SCHEMA}' to '${UC_GRANTEE}'..."
run_sql "GRANT USE CATALOG ON CATALOG \`${UC_CATALOG}\` TO \`${UC_GRANTEE}\`" >/dev/null
run_sql "GRANT USE SCHEMA ON SCHEMA \`${UC_CATALOG}\`.\`${UC_SCHEMA}\` TO \`${UC_GRANTEE}\`" >/dev/null
run_sql "GRANT SELECT ON SCHEMA \`${UC_CATALOG}\`.\`${UC_SCHEMA}\` TO \`${UC_GRANTEE}\`" >/dev/null
run_sql "GRANT EXECUTE ON SCHEMA \`${UC_CATALOG}\`.\`${UC_SCHEMA}\` TO \`${UC_GRANTEE}\`" >/dev/null
echo "  read/execute granted."

if [ -n "${DASHBOARD_RESOURCE_ID}" ] && [ -n "${WAREHOUSE_ID}" ]; then
    echo "Publishing the dashboard against the warehouse..."
    python3 - "${WAREHOUSE_ID}" >"${TMP_DIR}/publish.json" <<'PY'
import json, sys
print(json.dumps({"embed_credentials": True, "warehouse_id": sys.argv[1]}))
PY
    api POST "/api/2.0/lakeview/dashboards/${DASHBOARD_RESOURCE_ID}/published" "${TMP_DIR}/publish.json" >/dev/null || \
        echo "  dashboard publish skipped (it can be published manually from the workspace)."
fi

echo "Creating or updating the continuous ingestion job..."
EXISTING_JOB_ID="$(api GET "/api/2.1/jobs/list?limit=100" | python3 -c "import json,sys,os; d=json.load(sys.stdin); print(next((str(j['job_id']) for j in d.get('jobs', []) if j.get('settings',{}).get('name')==os.environ['JOB_NAME']), ''))")"

python3 - >"${TMP_DIR}/job_settings.json" <<'PY'
import json, os
settings = {
    "name": os.environ["JOB_NAME"],
    "max_concurrent_runs": 1,
    "continuous": {"pause_status": "UNPAUSED"},
    "tasks": [
        {
            "task_key": "opcua_ingestion",
            "notebook_task": {
                "notebook_path": os.environ["NOTEBOOK_PATH"],
                "base_parameters": {
                    "eventHubsConnectionString": os.environ["EVENTHUBS_CONNECTION_STRING"],
                    "checkpointRoot": "/Volumes/{0}/{1}/checkpoints".format(os.environ["UC_CATALOG"], os.environ["UC_SCHEMA"]),
                    "catalog": os.environ["UC_CATALOG"],
                    "schema": os.environ["UC_SCHEMA"],
                },
            },
            "new_cluster": {
                "spark_version": os.environ["DATABRICKS_RUNTIME"],
                "node_type_id": os.environ["NODE_TYPE_ID"],
                "num_workers": 0,
                # Unity Catalog is only accessible from clusters with a UC-compatible access mode.
                # A cluster with no data_security_mode defaults to the legacy no-isolation mode, where
                # `USE CATALOG <workspace-catalog>` fails with CATALOG_NOT_FOUND. Streaming workloads
                # require single-user (dedicated) access mode specifically, so use SINGLE_USER and run
                # the cluster as the deployment's managed identity (the job's run-as principal).
                "data_security_mode": "SINGLE_USER",
                "single_user_name": os.environ["MANAGED_IDENTITY_CLIENT_ID"],
                "spark_conf": {
                    "spark.databricks.cluster.profile": "singleNode",
                    "spark.master": "local[*]",
                },
                "custom_tags": {"ResourceClass": "SingleNode"},
            },
        }
    ],
}
print(json.dumps(settings))
PY

if [ -n "${EXISTING_JOB_ID}" ]; then
    echo "  resetting existing job ${EXISTING_JOB_ID}..."
    python3 - "${EXISTING_JOB_ID}" "${TMP_DIR}/job_settings.json" >"${TMP_DIR}/job_reset.json" <<'PY'
import json, sys
job_id, settings_file = sys.argv[1], sys.argv[2]
print(json.dumps({"job_id": int(job_id), "new_settings": json.load(open(settings_file))}))
PY
    api POST "/api/2.1/jobs/reset" "${TMP_DIR}/job_reset.json" >/dev/null
    JOB_ID="${EXISTING_JOB_ID}"
else
    echo "  creating a new job..."
    JOB_ID="$(api POST "/api/2.1/jobs/create" "${TMP_DIR}/job_settings.json" | json_get job_id)"
fi
echo "  job id: ${JOB_ID}"

echo "Databricks setup complete. The continuous job '${JOB_NAME}' ingests the OPC UA data,"
echo "and the '${WAREHOUSE_NAME}' warehouse serves the published dashboard."

if [ -n "${AZ_SCRIPTS_OUTPUT_PATH:-}" ]; then
    python3 - "${JOB_ID}" "${WAREHOUSE_ID}" "${DASHBOARD_RESOURCE_ID}" >"${AZ_SCRIPTS_OUTPUT_PATH}" <<'PY'
import json, sys
print(json.dumps({"jobId": sys.argv[1], "warehouseId": sys.argv[2], "dashboardResourceId": sys.argv[3]}))
PY
fi
