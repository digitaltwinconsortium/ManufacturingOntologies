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
#   DATABRICKS_RUNTIME=12.2.x-scala2.12
#   NODE_TYPE_ID=Standard_DS3_v2
#   UC_CATALOG=main
#   UC_SCHEMA=ontologies

set -euo pipefail

# Exported so the python3 helpers and heredocs below can read them via os.environ.
export WORKSPACE_FOLDER="${WORKSPACE_FOLDER:-/Shared/ManufacturingOntologies}"
export WAREHOUSE_NAME="${WAREHOUSE_NAME:-ManufacturingOntologies}"
export JOB_NAME="${JOB_NAME:-ManufacturingOntologies-OPCUA-Ingestion}"
export DATABRICKS_RUNTIME="${DATABRICKS_RUNTIME:-12.2.x-scala2.12}"
export NODE_TYPE_ID="${NODE_TYPE_ID:-Standard_DS3_v2}"
export UC_CATALOG="${UC_CATALOG:-main}"
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
                    "checkpointRoot": "dbfs:/opcua/checkpoints",
                    "catalog": os.environ["UC_CATALOG"],
                    "schema": os.environ["UC_SCHEMA"],
                },
            },
            "new_cluster": {
                "spark_version": os.environ["DATABRICKS_RUNTIME"],
                "node_type_id": os.environ["NODE_TYPE_ID"],
                "num_workers": 0,
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
