#!/usr/bin/env bash
#
# SetupFabric.sh
#
# Configures Microsoft Fabric as a third analytics option (next to Azure Data Explorer and
# Azure Databricks) that the reference solution ARM template (Deployment/arm.json) can deploy.
#
# This script is executed by a Microsoft.Resources/deploymentScripts resource that runs under the
# reference solution's user-assigned managed identity. It:
#   1. Creates (or reuses) a Fabric workspace and assigns it to the deployed Fabric capacity.
#   2. Creates an Eventhouse and a KQL database.
#   3. Runs the OPC UA KQL (tables, mappings, expansion functions, materialized view, OEE functions),
#      mirroring the Azure Data Explorer setup so Fabric processes the data identically.
#   4. Enables OneLake availability on the final tables.
#   5. Creates an Event Hubs connection and the data/metadata eventstreams (Eventhouse DirectIngestion).
#   6. Creates a Lakehouse with OneLake shortcuts to opcua_telemetry and opcua_metadata.
#
# Required environment variables (set by the deploymentScripts resource):
#   MANAGED_IDENTITY_CLIENT_ID   - client id of the user-assigned managed identity
#   AZURE_TENANT_ID              - Microsoft Entra tenant id
#   RESOURCES_NAME               - the solution resources name
#   FABRIC_CAPACITY_NAME         - name of the Microsoft.Fabric/capacities resource to assign the workspace to
#   FABRIC_WORKSPACE_NAME        - display name for the Fabric workspace
#   EVENTHUBS_NAMESPACE          - Event Hubs namespace name (<resourcesName>-EventHubs)
#   EVENTHUBS_CONNECTION_STRING  - namespace-level RootManageSharedAccessKey connection string
#   KQL_SCRIPT_URL               - raw URL of Tools/FabricQueries/opcua_setup.kql
#   DASHBOARD_URL                - raw URL of Tools/ADXQueries/dashboard-ontologies.json (imported as a Real-Time Dashboard)
#
# Optional environment variables (defaults shown):
#   EVENTHOUSE_NAME=opcua
#   LAKEHOUSE_NAME=opcua_lake
#   FABRIC_CONSUMER_GROUP=fabric
#
# PREREQUISITE (cannot be automated): a Fabric tenant admin must enable the tenant setting
#   "Service principals and managed identities can use Fabric APIs" and scope it to include this
#   managed identity. Without it, every Fabric REST call below returns 401/403.

set -euo pipefail

# Exported so the inline python3 heredocs below can read them via os.environ.
export EVENTHOUSE_NAME="${EVENTHOUSE_NAME:-opcua}"
export LAKEHOUSE_NAME="${LAKEHOUSE_NAME:-opcua_lake}"
export FABRIC_CONSUMER_GROUP="${FABRIC_CONSUMER_GROUP:-fabric}"
DATA_EVENTSTREAM_NAME="eventstream_opcua_data"
METADATA_EVENTSTREAM_NAME="eventstream_opcua_metadata"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "Logging in with the user-assigned managed identity..."
az login --identity --username "${MANAGED_IDENTITY_CLIENT_ID}" --output none

echo "Acquiring a Microsoft Fabric access token..."
# The Fabric REST APIs accept a token for the Power BI service audience. Both
# https://analysis.windows.net/powerbi/api and https://api.fabric.microsoft.com are
# valid App ID URIs for this audience; we use the Power BI one.
export FABRIC_TOKEN="$(az account get-access-token --resource https://analysis.windows.net/powerbi/api --query accessToken -o tsv)"

# Diagnostics: decode the (unverified) JWT claims so the deployment log shows exactly
# which identity/audience Fabric will see. This makes 401 root-causing possible without
# guessing (look for aud, appid/azp, oid, tid).
python3 - <<'PY' || true
import base64, json, os
tok = os.environ.get("FABRIC_TOKEN", "")
try:
    payload = tok.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    claims = json.loads(base64.urlsafe_b64decode(payload))
    keep = {k: claims.get(k) for k in ("aud", "appid", "azp", "oid", "tid", "idtyp", "roles") if k in claims}
    print("  Fabric token claims:", json.dumps(keep))
except Exception as exc:
    print("  Could not decode Fabric token claims:", exc)
PY

# Derive the Event Hubs namespace fully-qualified host from the connection string.
export EVENTHUBS_FQDN="$(python3 -c "import os,re; m=re.search(r'Endpoint=sb://([^/;]+)', os.environ['EVENTHUBS_CONNECTION_STRING']); print(m.group(1) if m else '')")"

# ---------------------------------------------------------------------------
# python3 helpers (curl is not available in the azure-cli deploymentScripts image)
# ---------------------------------------------------------------------------

# Call the Fabric REST API. Usage: fabric METHOD PATH [BODY_FILE]
# Prints the (final) response body. Transparently polls long-running operations (HTTP 202).
fabric() {
	FABRIC_METHOD="$1" FABRIC_PATH="$2" FABRIC_BODY_FILE="${3:-}" python3 - <<'PY'
import json, os, sys, time, urllib.error, urllib.request

base = "https://api.fabric.microsoft.com/v1"
method = os.environ["FABRIC_METHOD"]
path = os.environ["FABRIC_PATH"]
body_file = os.environ.get("FABRIC_BODY_FILE", "")
url = path if path.startswith("http") else base + path
data = open(body_file, "rb").read() if body_file else None
headers = {
	"Authorization": "Bearer " + os.environ["FABRIC_TOKEN"],
	"Content-Type": "application/json",
}


def call(u, m, d):
	return urllib.request.urlopen(urllib.request.Request(u, data=d, headers=headers, method=m))


try:
	resp = call(url, method, data)
	payload = resp.read()
	if resp.getcode() == 202 and resp.headers.get("Location"):
		loc = resp.headers["Location"]
		delay = int(resp.headers.get("Retry-After", "5") or "5")
		for _ in range(180):
			time.sleep(delay)
			poll = call(loc, "GET", None)
			body = poll.read()
			try:
				state = (json.loads(body or b"{}") or {}).get("status", "")
			except Exception:
				state = ""
			if state in ("Succeeded", "Completed"):
				result = poll.headers.get("Location")
				payload = call(result, "GET", None).read() if result else body
				break
			if state in ("Failed", "Cancelled", "Undelivered"):
				sys.stderr.write("Fabric long-running operation failed: " + body.decode("utf-8", "replace") + "\n")
				sys.exit(1)
			delay = int(poll.headers.get("Retry-After", str(delay)) or delay)
	sys.stdout.buffer.write(payload or b"")
except urllib.error.HTTPError as error:
	sys.stderr.write("Fabric API %s %s -> HTTP %s: %s\n" % (method, url, error.code, error.read().decode("utf-8", "replace")))
	sys.exit(1)
PY
}

# Read a top-level field from a JSON document on stdin. Usage: ... | json_get FIELD
json_get() {
	python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1], '') if isinstance(d, dict) else '')" "$1"
}

# Find an item id in a Fabric '{\"value\":[...]}' list by display name. Usage: ... | find_by_name NAME
find_by_name() {
	FIND_NAME="$1" python3 -c "import json,sys,os; d=json.load(sys.stdin); print(next((i['id'] for i in d.get('value', []) if i.get('displayName','')==os.environ['FIND_NAME']), ''))"
}

# ---------------------------------------------------------------------------
# Preflight: verify the managed identity is allowed to call the Fabric APIs
# ---------------------------------------------------------------------------
# A valid Entra token still gets rejected with 401/403 unless a Fabric tenant
# admin has enabled "Service principals can use Fabric APIs" and scoped it to
# include this managed identity. Check that up front so the failure is a single
# clear message instead of a cascade of downstream errors.
echo "Verifying the managed identity can call the Fabric APIs..."
if ! fabric GET "/workspaces" >/dev/null 2>"${TMP_DIR}/preflight.err"; then
	echo "ERROR: The managed identity is not authorized to call the Microsoft Fabric APIs." >&2
	echo "       A Fabric tenant admin must enable the tenant setting" >&2
	echo "       'Service principals can use Fabric APIs' (Fabric admin portal -> Tenant settings ->" >&2
	echo "       Developer settings) and scope it to the whole organization or to a security group" >&2
	echo "       that contains this managed identity ('${RESOURCES_NAME}-Identity')." >&2
	echo "       Allow a few minutes for the setting to propagate, then redeploy the Fabric template" >&2
	echo "       (it is idempotent). See fabric.md for details." >&2
	echo "       Underlying Fabric API response:" >&2
	sed 's/^/         /' "${TMP_DIR}/preflight.err" >&2 || true
	exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Workspace + capacity assignment
# ---------------------------------------------------------------------------

echo "Resolving the Fabric capacity '${FABRIC_CAPACITY_NAME}'..."
CAPACITY_ID="$(fabric GET "/capacities" | FIND_NAME="${FABRIC_CAPACITY_NAME}" python3 -c "import json,sys,os; d=json.load(sys.stdin); print(next((c['id'] for c in d.get('value', []) if c.get('displayName','').lower()==os.environ['FIND_NAME'].lower()), ''))")"
if [ -z "${CAPACITY_ID}" ]; then
	echo "ERROR: Fabric capacity '${FABRIC_CAPACITY_NAME}' was not found via the Fabric API." >&2
	echo "       Ensure the managed identity is a capacity admin and that the tenant setting" >&2
	echo "       'Service principals and managed identities can use Fabric APIs' is enabled for it." >&2
	exit 1
fi
echo "  capacity id: ${CAPACITY_ID}"

echo "Creating or reusing the Fabric workspace '${FABRIC_WORKSPACE_NAME}'..."
WORKSPACE_ID="$(fabric GET "/workspaces" | find_by_name "${FABRIC_WORKSPACE_NAME}")"
if [ -z "${WORKSPACE_ID}" ]; then
	python3 - >"${TMP_DIR}/workspace.json" <<'PY'
import json, os
print(json.dumps({"displayName": os.environ["FABRIC_WORKSPACE_NAME"]}))
PY
	# Creating a workspace requires the separate "Service principals can create
	# workspaces, connections, and deployment pipelines" tenant setting (disabled by
	# default), which is distinct from "Service principals can use Fabric APIs". If only
	# the latter is on, read calls above succeed but this POST returns 401.
	if ! fabric POST "/workspaces" "${TMP_DIR}/workspace.json" >"${TMP_DIR}/workspace_resp.json" 2>"${TMP_DIR}/workspace.err"; then
		echo "ERROR: Creating the Fabric workspace failed." >&2
		echo "       The managed identity can call the Fabric APIs (the reads above succeeded) but is" >&2
		echo "       not allowed to CREATE a workspace. A Fabric tenant admin must also enable the" >&2
		echo "       tenant setting 'Service principals can create workspaces, connections, and" >&2
		echo "       deployment pipelines' (Fabric admin portal -> Tenant settings -> Developer" >&2
		echo "       settings; disabled by default) and scope it to include '${RESOURCES_NAME}-Identity'." >&2
		echo "       Allow a few minutes to propagate, then redeploy the Fabric template (idempotent)." >&2
		echo "       Underlying Fabric API response:" >&2
		sed 's/^/         /' "${TMP_DIR}/workspace.err" >&2 || true
		exit 1
	fi
	WORKSPACE_ID="$(json_get id <"${TMP_DIR}/workspace_resp.json")"
fi
echo "  workspace id: ${WORKSPACE_ID}"

echo "Assigning the workspace to the capacity..."
python3 - "${CAPACITY_ID}" >"${TMP_DIR}/assign.json" <<'PY'
import json, sys
print(json.dumps({"capacityId": sys.argv[1]}))
PY
fabric POST "/workspaces/${WORKSPACE_ID}/assignToCapacity" "${TMP_DIR}/assign.json" >/dev/null

# ---------------------------------------------------------------------------
# Step 2: Eventhouse + KQL database
# ---------------------------------------------------------------------------

echo "Creating or reusing the Eventhouse '${EVENTHOUSE_NAME}'..."
EVENTHOUSE_ID="$(fabric GET "/workspaces/${WORKSPACE_ID}/eventhouses" | find_by_name "${EVENTHOUSE_NAME}")"
if [ -z "${EVENTHOUSE_ID}" ]; then
	python3 - >"${TMP_DIR}/eventhouse.json" <<'PY'
import json, os
print(json.dumps({"displayName": os.environ["EVENTHOUSE_NAME"]}))
PY
	EVENTHOUSE_ID="$(fabric POST "/workspaces/${WORKSPACE_ID}/eventhouses" "${TMP_DIR}/eventhouse.json" | json_get id)"
fi
echo "  eventhouse id: ${EVENTHOUSE_ID}"

# The eventhouse auto-creates a default KQL database with the same name. Read its query endpoint and id.
EVENTHOUSE_DETAILS="$(fabric GET "/workspaces/${WORKSPACE_ID}/eventhouses/${EVENTHOUSE_ID}")"
QUERY_URI="$(echo "${EVENTHOUSE_DETAILS}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('properties',{}).get('queryServiceUri',''))")"
KQL_DATABASE_ID="$(echo "${EVENTHOUSE_DETAILS}" | python3 -c "import json,sys; d=json.load(sys.stdin); ids=d.get('properties',{}).get('databasesItemIds',[]); print(ids[0] if ids else '')")"
KQL_DATABASE_NAME="$(fabric GET "/workspaces/${WORKSPACE_ID}/kqlDatabases/${KQL_DATABASE_ID}" | json_get displayName)"
echo "  KQL database: ${KQL_DATABASE_NAME} (${KQL_DATABASE_ID})"
echo "  query endpoint: ${QUERY_URI}"

# ---------------------------------------------------------------------------
# Step 3: Run the OPC UA KQL against the eventhouse
# ---------------------------------------------------------------------------

echo "Acquiring a Kusto access token for the eventhouse..."
export KUSTO_TOKEN="$(az account get-access-token --resource "${QUERY_URI}" --query accessToken -o tsv)"

echo "Downloading and running the OPC UA KQL setup..."
python3 - "${KQL_SCRIPT_URL}" "${TMP_DIR}/opcua_setup.kql" <<'PY'
import sys, urllib.request, shutil
with urllib.request.urlopen(sys.argv[1]) as response, open(sys.argv[2], "wb") as out:
	shutil.copyfileobj(response, out)
PY

# Submit the whole file as one database script via the Kusto management API.
KUSTO_DB="${KQL_DATABASE_NAME}" KUSTO_URI="${QUERY_URI}" python3 - "${TMP_DIR}/opcua_setup.kql" <<'PY'
import json, os, sys, urllib.request

with open(sys.argv[1], "r", encoding="utf-8") as f:
	kql = f.read()
csl = ".execute database script <|\n" + kql
body = json.dumps({"db": os.environ["KUSTO_DB"], "csl": csl}).encode("utf-8")
req = urllib.request.Request(
	os.environ["KUSTO_URI"].rstrip("/") + "/v1/rest/mgmt",
	data=body,
	headers={"Authorization": "Bearer " + os.environ["KUSTO_TOKEN"], "Content-Type": "application/json", "Accept": "application/json"},
	method="POST",
)
with urllib.request.urlopen(req) as response:
	response.read()
PY

# Enable OneLake availability on the final tables so the Lakehouse shortcuts can read them as Parquet.
for TABLE in opcua_telemetry opcua_metadata; do
	KUSTO_DB="${KQL_DATABASE_NAME}" KUSTO_URI="${QUERY_URI}" KUSTO_TABLE="${TABLE}" python3 - <<'PY' || echo "  warning: could not enable OneLake availability on ${TABLE} (enable it manually if needed)."
import json, os, urllib.request

csl = ".alter table " + os.environ["KUSTO_TABLE"] + " policy mirroring dataformat=parquet with (IsEnabled=true)"
body = json.dumps({"db": os.environ["KUSTO_DB"], "csl": csl}).encode("utf-8")
req = urllib.request.Request(
	os.environ["KUSTO_URI"].rstrip("/") + "/v1/rest/mgmt",
	data=body,
	headers={"Authorization": "Bearer " + os.environ["KUSTO_TOKEN"], "Content-Type": "application/json"},
	method="POST",
)
with urllib.request.urlopen(req) as response:
	response.read()
PY
done

# ---------------------------------------------------------------------------
# Step 4: Event Hubs connection + eventstreams (Eventhouse DirectIngestion)
#
# NOTE: The Fabric connection and eventstream-topology payloads are the most version-sensitive
# part of the Fabric API. They are attempted best-effort: if the live API rejects a payload, the
# script logs guidance and continues, leaving the Eventhouse/KQL/Lakehouse in place so the two
# eventstreams can be completed manually following fabric.md.
# ---------------------------------------------------------------------------

create_eventstream() {
	local stream_name="$1" event_hub="$2" raw_table="$3" mapping="$4"
	echo "  creating eventstream '${stream_name}' (${event_hub} -> ${raw_table})..."

	# A Fabric connection for the Azure Event Hubs source (namespace + event hub + SAS key).
	ES_NAME="${stream_name}" EH="${event_hub}" python3 - >"${TMP_DIR}/connection.json" <<'PY'
import json, os
print(json.dumps({
	"connectivityType": "ShareableCloud",
	"displayName": os.environ["ES_NAME"] + "-source",
	"connectionDetails": {
		"type": "AzureEventHubs",
		"creationMethod": "AzureEventHubs.Contents",
		"parameters": [
			{"dataType": "Text", "name": "namespace", "value": os.environ["EVENTHUBS_FQDN"]},
			{"dataType": "Text", "name": "eventHubName", "value": os.environ["EH"]},
		],
	},
	"credentialDetails": {
		"singleSignOnType": "None",
		"connectionEncryption": "NotEncrypted",
		"skipTestConnection": False,
		"credentials": {
			"credentialType": "SharedAccessSignature",
			"sasKeyName": "RootManageSharedAccessKey",
			"sasKey": os.environ["EVENTHUBS_CONNECTION_STRING"],
		},
	},
}))
PY
	local connection_id
	connection_id="$(fabric POST "/connections" "${TMP_DIR}/connection.json" | json_get id)" || { echo "    warning: could not create the Event Hubs connection for ${stream_name}; create the eventstream manually (see fabric.md)."; return 0; }

	# The eventstream topology: Azure Event Hub source -> Eventhouse DirectIngestion destination.
	ES_NAME="${stream_name}" CONNECTION_ID="${connection_id}" CONSUMER_GROUP="${FABRIC_CONSUMER_GROUP}" \
	WORKSPACE_ID="${WORKSPACE_ID}" EVENTHOUSE_ID="${EVENTHOUSE_ID}" RAW_TABLE="${raw_table}" MAPPING="${mapping}" \
	python3 - >"${TMP_DIR}/eventstream.json" <<'PY'
import base64, json, os

source_node = os.environ["ES_NAME"] + "-source"
topology = {
	"sources": [
		{
			"name": source_node,
			"type": "AzureEventHub",
			"properties": {
				"dataConnectionId": os.environ["CONNECTION_ID"],
				"consumerGroupName": os.environ["CONSUMER_GROUP"],
				"inputSerialization": {"type": "Json", "properties": {"encoding": "UTF8"}},
			},
		}
	],
	"destinations": [
		{
			"name": os.environ["ES_NAME"] + "-eventhouse",
			"type": "Eventhouse",
			"properties": {
				"dataIngestionMode": "DirectIngestion",
				"workspaceId": os.environ["WORKSPACE_ID"],
				"itemId": os.environ["EVENTHOUSE_ID"],
				"tableName": os.environ["RAW_TABLE"],
				"connectionName": os.environ["ES_NAME"] + "-ingest",
				"mappingRuleName": os.environ["MAPPING"],
			},
			"inputNodes": [{"name": source_node}],
		}
	],
	"operators": [],
	"compatibilityLevel": "1.0",
}
definition = base64.b64encode(json.dumps(topology).encode("utf-8")).decode()
platform = base64.b64encode(json.dumps({
	"$schema": "https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json",
	"metadata": {"type": "Eventstream", "displayName": os.environ["ES_NAME"]},
	"config": {"version": "2.0", "logicalId": "00000000-0000-0000-0000-000000000000"},
}).encode("utf-8")).decode()
print(json.dumps({
	"displayName": os.environ["ES_NAME"],
	"type": "Eventstream",
	"definition": {
		"parts": [
			{"path": "eventstream.json", "payload": definition, "payloadType": "InlineBase64"},
			{"path": ".platform", "payload": platform, "payloadType": "InlineBase64"},
		]
	},
}))
PY
	fabric POST "/workspaces/${WORKSPACE_ID}/items" "${TMP_DIR}/eventstream.json" >/dev/null || echo "    warning: could not create eventstream ${stream_name}; create it manually (see fabric.md)."
}

echo "Creating the OPC UA eventstreams..."
create_eventstream "${DATA_EVENTSTREAM_NAME}" "data" "opcua_raw" "opcua_mapping"
create_eventstream "${METADATA_EVENTSTREAM_NAME}" "metadata" "opcua_metadata_raw" "opcua_metadata_mapping"

# ---------------------------------------------------------------------------
# Step 5: Lakehouse + OneLake shortcuts
# ---------------------------------------------------------------------------

echo "Creating or reusing the Lakehouse '${LAKEHOUSE_NAME}'..."
LAKEHOUSE_ID="$(fabric GET "/workspaces/${WORKSPACE_ID}/lakehouses" | find_by_name "${LAKEHOUSE_NAME}")"
if [ -z "${LAKEHOUSE_ID}" ]; then
	python3 - >"${TMP_DIR}/lakehouse.json" <<'PY'
import json, os
print(json.dumps({"displayName": os.environ["LAKEHOUSE_NAME"]}))
PY
	LAKEHOUSE_ID="$(fabric POST "/workspaces/${WORKSPACE_ID}/lakehouses" "${TMP_DIR}/lakehouse.json" | json_get id)"
fi
echo "  lakehouse id: ${LAKEHOUSE_ID}"

# OneLake shortcuts from the Lakehouse Tables area to the KQL database tables.
for TABLE in opcua_telemetry opcua_metadata; do
	echo "  creating OneLake shortcut to ${TABLE}..."
	WORKSPACE_ID="${WORKSPACE_ID}" KQL_DATABASE_ID="${KQL_DATABASE_ID}" SHORTCUT_TABLE="${TABLE}" python3 - >"${TMP_DIR}/shortcut.json" <<'PY'
import json, os
print(json.dumps({
	"path": "Tables",
	"name": os.environ["SHORTCUT_TABLE"],
	"target": {
		"oneLake": {
			"workspaceId": os.environ["WORKSPACE_ID"],
			"itemId": os.environ["KQL_DATABASE_ID"],
			"path": "Tables/" + os.environ["SHORTCUT_TABLE"],
		}
	},
}))
PY
	fabric POST "/workspaces/${WORKSPACE_ID}/items/${LAKEHOUSE_ID}/shortcuts" "${TMP_DIR}/shortcut.json" >/dev/null || echo "    warning: could not create the shortcut to ${TABLE}; create it manually (see fabric.md)."
done

# ---------------------------------------------------------------------------
# Step 6: Real-Time Dashboard (import the ADX dashboard, repointed at the eventhouse)
#
# Fabric Real-Time Dashboards share the Azure Data Explorer dashboard schema, and the eventhouse
# has the same tables/functions as ADX, so the ADX dashboard works once its data source points at
# the eventhouse. This is best-effort: on failure the script logs guidance and continues.
# ---------------------------------------------------------------------------

if [ -n "${DASHBOARD_URL:-}" ]; then
	echo "Importing the ADX dashboard as a Fabric Real-Time Dashboard..."
	python3 - "${DASHBOARD_URL}" "${TMP_DIR}/dashboard.json" <<'PY'
import shutil, sys, urllib.request
with urllib.request.urlopen(sys.argv[1]) as response, open(sys.argv[2], "wb") as out:
	shutil.copyfileobj(response, out)
PY
	QUERY_URI="${QUERY_URI}" KQL_DATABASE_NAME="${KQL_DATABASE_NAME}" DASHBOARD_DISPLAY_NAME="Ontologies" \
	python3 - "${TMP_DIR}/dashboard.json" >"${TMP_DIR}/dashboard_item.json" <<'PY'
import base64, json, os, sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
	dashboard = json.load(f)
# Repoint every Kusto data source at the eventhouse query endpoint and KQL database. The tiles
# reference data sources by id, so the queries keep working unchanged.
for ds in dashboard.get("dataSources", []):
	if "clusterUri" in ds or str(ds.get("kind", "")).endswith("kusto"):
		ds["clusterUri"] = os.environ["QUERY_URI"]
		ds["database"] = os.environ["KQL_DATABASE_NAME"]
definition = base64.b64encode(json.dumps(dashboard).encode("utf-8")).decode()
platform = base64.b64encode(json.dumps({
	"$schema": "https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json",
	"metadata": {"type": "KQLDashboard", "displayName": os.environ["DASHBOARD_DISPLAY_NAME"]},
	"config": {"version": "2.0", "logicalId": "00000000-0000-0000-0000-000000000000"},
}).encode("utf-8")).decode()
print(json.dumps({
	"displayName": os.environ["DASHBOARD_DISPLAY_NAME"],
	"type": "KQLDashboard",
	"definition": {
		"parts": [
			{"path": "RealTimeDashboard.json", "payload": definition, "payloadType": "InlineBase64"},
			{"path": ".platform", "payload": platform, "payloadType": "InlineBase64"},
		]
	},
}))
PY
	fabric POST "/workspaces/${WORKSPACE_ID}/items" "${TMP_DIR}/dashboard_item.json" >/dev/null || echo "  warning: could not import the Real-Time Dashboard; import Tools/ADXQueries/dashboard-ontologies.json manually and point its data source at the eventhouse (see fabric.md)."
fi

echo "Fabric setup complete. Workspace '${FABRIC_WORKSPACE_NAME}' contains the '${EVENTHOUSE_NAME}' eventhouse"
echo "(OPC UA tables, expansion functions, materialized view and OEE functions) and the '${LAKEHOUSE_NAME}' lakehouse."

if [ -n "${AZ_SCRIPTS_OUTPUT_PATH:-}" ]; then
	python3 - "${WORKSPACE_ID}" "${EVENTHOUSE_ID}" "${KQL_DATABASE_ID}" "${LAKEHOUSE_ID}" "${QUERY_URI}" "${KQL_DATABASE_NAME}" >"${AZ_SCRIPTS_OUTPUT_PATH}" <<'PY'
import json, sys
print(json.dumps({"workspaceId": sys.argv[1], "eventhouseId": sys.argv[2], "kqlDatabaseId": sys.argv[3], "lakehouseId": sys.argv[4], "queryServiceUri": sys.argv[5], "kqlDatabaseName": sys.argv[6]}))
PY
fi
