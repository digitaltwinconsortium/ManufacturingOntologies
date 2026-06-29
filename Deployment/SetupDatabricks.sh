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
#   EVENTHUBS_SPARK_VERSION=2.3.22

set -euo pipefail

WORKSPACE_FOLDER="${WORKSPACE_FOLDER:-/Shared/ManufacturingOntologies}"
WAREHOUSE_NAME="${WAREHOUSE_NAME:-ManufacturingOntologies}"
JOB_NAME="${JOB_NAME:-ManufacturingOntologies-OPCUA-Ingestion}"
DATABRICKS_RUNTIME="${DATABRICKS_RUNTIME:-12.2.x-scala2.12}"
NODE_TYPE_ID="${NODE_TYPE_ID:-Standard_DS3_v2}"
EVENTHUBS_SPARK_VERSION="${EVENTHUBS_SPARK_VERSION:-2.3.22}"

NOTEBOOK_PATH="${WORKSPACE_FOLDER}/opcua_setup"
DASHBOARD_PATH="${WORKSPACE_FOLDER}/dashboard-ontologies.lvdash.json"

# Programmatic id of the Azure Databricks login application (constant for all tenants).
DATABRICKS_LOGIN_APP_ID="2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "Logging in with the user-assigned managed identity..."
az login --identity --username "${MANAGED_IDENTITY_CLIENT_ID}" --output none

echo "Acquiring access tokens..."
DATABRICKS_AAD_TOKEN="$(az account get-access-token --resource "${DATABRICKS_LOGIN_APP_ID}" --query accessToken -o tsv)"
ARM_TOKEN="$(az account get-access-token --resource https://management.core.windows.net/ --query accessToken -o tsv)"

# Parse a top-level field out of a JSON document using Python (always present in the azure-cli image).
json_get() {
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1], '') if isinstance(d, dict) else '')" "$1"
}

# Call the Databricks REST API. Usage: api METHOD PATH [BODY_FILE]
api() {
    local method="$1"
    local path="$2"
    local body_file="${3:-}"
    local url="https://${DATABRICKS_WORKSPACE_URL}${path}"
    if [ -n "${body_file}" ]; then
        curl -sS -X "${method}" "${url}" \
            -H "Authorization: Bearer ${DATABRICKS_AAD_TOKEN}" \
            -H "X-Databricks-Azure-SP-Management-Token: ${ARM_TOKEN}" \
            -H "X-Databricks-Azure-Workspace-Resource-Id: ${WORKSPACE_RESOURCE_ID}" \
            -H "Content-Type: application/json" \
            --data "@${body_file}"
    else
        curl -sS -X "${method}" "${url}" \
            -H "Authorization: Bearer ${DATABRICKS_AAD_TOKEN}" \
            -H "X-Databricks-Azure-SP-Management-Token: ${ARM_TOKEN}" \
            -H "X-Databricks-Azure-Workspace-Resource-Id: ${WORKSPACE_RESOURCE_ID}"
    fi
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
curl -sSL "${NOTEBOOK_URL}" -o "${TMP_DIR}/opcua_setup.py"
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
curl -sSL "${DASHBOARD_URL}" -o "${TMP_DIR}/dashboard.lvdash.json"
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
            "libraries": [
                {
                    "maven": {
                        "coordinates": "com.microsoft.azure:azure-event-hubs-spark_2.12:"
                        + os.environ["EVENTHUBS_SPARK_VERSION"]
                    }
                }
            ],
        }
    ],
}
print(json.dumps(settings))
PY

export JOB_NAME NOTEBOOK_PATH EVENTHUBS_CONNECTION_STRING DATABRICKS_RUNTIME NODE_TYPE_ID EVENTHUBS_SPARK_VERSION

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
