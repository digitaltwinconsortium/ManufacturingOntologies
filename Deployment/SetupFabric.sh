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
#   RESOURCE_GROUP               - resource group holding the AIO assets (used to re-trigger OPC UA metadata)
#   SUBSCRIPTION_ID              - subscription id (used to re-trigger OPC UA metadata)
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

# Fabric connection display names are unique per tenant and connections outlive the workspace, so a
# fixed name collides across redeploys ('DuplicateConnectionName'). Give each deployment's connections
# a unique suffix so creation never conflicts; the eventstream references the freshly created id.
CONN_SUFFIX="$(python3 -c "import secrets; print(secrets.token_hex(4))" 2>/dev/null || date +%s)"

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

# List the ids of all Fabric connections whose display name starts with PREFIX, paging through ALL
# connections (the tenant-wide list is paginated). Used to clean up connections left by earlier
# deployments so they don't accumulate. Prints one id per line.
list_connection_ids_by_prefix() {
	local prefix="$1"
	local path="/connections"
	while [ -n "${path}" ]; do
		fabric GET "${path}" >"${TMP_DIR}/connections_page.json"
		FIND_PREFIX="${prefix}" python3 -c "import json,os; d=json.load(open('${TMP_DIR}/connections_page.json')); [print(i['id']) for i in d.get('value', []) if i.get('displayName','').startswith(os.environ['FIND_PREFIX'])]"
		path="$(python3 -c "import json; d=json.load(open('${TMP_DIR}/connections_page.json')); print(d.get('continuationUri','') or '')")"
	done
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
	fabric POST "/workspaces/${WORKSPACE_ID}/eventhouses" "${TMP_DIR}/eventhouse.json" >/dev/null || { echo "ERROR: Failed to create the Eventhouse '${EVENTHOUSE_NAME}'. See the Fabric API error above." >&2; exit 1; }
	# Always re-fetch by name to get the authoritative item id (don't trust the create/LRO response id,
	# which the eventstream destination's itemId depends on to resolve the Eventhouse and KQL database).
	EVENTHOUSE_ID="$(fabric GET "/workspaces/${WORKSPACE_ID}/eventhouses" | find_by_name "${EVENTHOUSE_NAME}")"
fi
if [ -z "${EVENTHOUSE_ID}" ]; then
	echo "ERROR: Could not resolve the Eventhouse '${EVENTHOUSE_NAME}' item id after creation." >&2
	exit 1
fi
echo "  eventhouse id: ${EVENTHOUSE_ID}"

# The eventhouse auto-creates a default KQL database, but its query endpoint and database id are
# populated asynchronously - they are often empty right after creation. Poll until both are present,
# otherwise the KQL setup below would POST to an empty query URI and silently create nothing (which
# leaves the tables empty and the eventstream destination unable to resolve the KQL database).
echo "Waiting for the eventhouse query endpoint and KQL database to become available..."
QUERY_URI=""
KQL_DATABASE_ID=""
for _ in $(seq 1 60); do
	EVENTHOUSE_DETAILS="$(fabric GET "/workspaces/${WORKSPACE_ID}/eventhouses/${EVENTHOUSE_ID}")"
	QUERY_URI="$(echo "${EVENTHOUSE_DETAILS}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('properties',{}).get('queryServiceUri',''))")"
	KQL_DATABASE_ID="$(echo "${EVENTHOUSE_DETAILS}" | python3 -c "import json,sys; d=json.load(sys.stdin); ids=d.get('properties',{}).get('databasesItemIds',[]); print(ids[0] if ids else '')")"
	if [ -n "${QUERY_URI}" ] && [ -n "${KQL_DATABASE_ID}" ]; then
		break
	fi
	sleep 5
done
if [ -z "${QUERY_URI}" ] || [ -z "${KQL_DATABASE_ID}" ]; then
	echo "ERROR: The eventhouse '${EVENTHOUSE_NAME}' did not expose a query endpoint / KQL database in time." >&2
	echo "       queryServiceUri='${QUERY_URI}' databasesItemIds[0]='${KQL_DATABASE_ID}'. Cannot create tables or ingest." >&2
	exit 1
fi
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
import json, os, sys, urllib.error, urllib.request

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
try:
	with urllib.request.urlopen(req) as response:
		response.read()
except urllib.error.HTTPError as error:
	sys.stderr.write("Kusto management call failed HTTP %s: %s\n" % (error.code, error.read().decode("utf-8", "replace")))
	sys.exit(1)
PY

# Verify the raw ingestion tables actually exist before wiring the eventstreams. If they are missing
# the DirectIngestion destination has no target and goes into a 'Warning' state with empty tables.
echo "Verifying the OPC UA ingestion tables exist in the KQL database..."
KUSTO_DB="${KQL_DATABASE_NAME}" KUSTO_URI="${QUERY_URI}" python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request
csl = ".show tables | project TableName | where TableName in ('opcua_raw', 'opcua_metadata_raw')"
body = json.dumps({"db": os.environ["KUSTO_DB"], "csl": csl}).encode("utf-8")
req = urllib.request.Request(
	os.environ["KUSTO_URI"].rstrip("/") + "/v1/rest/query",
	data=body,
	headers={"Authorization": "Bearer " + os.environ["KUSTO_TOKEN"], "Content-Type": "application/json", "Accept": "application/json"},
	method="POST",
)
try:
	with urllib.request.urlopen(req) as response:
		result = json.loads(response.read() or b"{}")
except urllib.error.HTTPError as error:
	sys.stderr.write("Could not query the KQL database for tables HTTP %s: %s\n" % (error.code, error.read().decode("utf-8", "replace")))
	sys.exit(1)
found = set()
for table in result.get("Tables", []):
	for row in table.get("Rows", []):
		if row:
			found.add(row[0])
missing = {"opcua_raw", "opcua_metadata_raw"} - found
if missing:
	sys.stderr.write("ERROR: KQL setup did not create expected tables: %s. The DirectIngestion destination would stay empty.\n" % ", ".join(sorted(missing)))
	sys.exit(1)
print("  ingestion tables present: opcua_raw, opcua_metadata_raw")
PY

# Enable OneLake availability on the final tables so the Lakehouse shortcuts can read them as Parquet.
# TargetLatencyInMinutes=5 (the documented minimum) keeps low-volume tables (e.g. metadata) fresh;
# without it the adaptive batcher can delay writes up to ~3 hours while it waits for larger files.
for TABLE in opcua_telemetry opcua_metadata; do
	KUSTO_DB="${KQL_DATABASE_NAME}" KUSTO_URI="${QUERY_URI}" KUSTO_TABLE="${TABLE}" python3 - <<'PY' || echo "  warning: could not enable OneLake availability on ${TABLE} (enable it manually if needed)."
import json, os, urllib.request

csl = ".alter-merge table " + os.environ["KUSTO_TABLE"] + " policy mirroring dataformat=parquet with (IsEnabled=true, TargetLatencyInMinutes=5)"
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
# part of the Fabric API, and they are what actually pump data into the Eventhouse. If either
# call fails the script now stops with the underlying Fabric API error, because a deployment that
# "succeeds" while leaving these out produces an Eventhouse whose tables are silently empty.
# ---------------------------------------------------------------------------

# Discover the exact Fabric connection metadata for Azure Event Hubs. The connection "type",
# the creation-method "name", and the parameter names are connector-specific and evolve over
# time, so we read them from the live API instead of hardcoding (hardcoded values previously
# failed with 'Kind: AzureEventHubs is not supported'; the connector is actually named 'EventHub').
echo "Discovering the Azure Event Hubs connection type from the Fabric API..."
fabric GET "/connections/supportedConnectionTypes?showAllCreationMethods=true" >"${TMP_DIR}/supported_conn_types.json"
SUPPORTED_TYPES_FILE="${TMP_DIR}/supported_conn_types.json" python3 - >"${TMP_DIR}/eh_conn_meta.json" <<'PY'
import json, os
data = json.load(open(os.environ["SUPPORTED_TYPES_FILE"]))
types = data.get("value", [])
def score(t):
	n = (t.get("type", "") or "").lower()
	if "iothub" in n:
		return -1
	if n == "eventhub":
		return 3
	if n == "eventhubs":
		return 2
	if "eventhub" in n:
		return 1
	return -1
best = None
best_score = 0
for t in types:
	s = score(t)
	if s > best_score:
		best, best_score = t, s
print(json.dumps(best or {}))
PY
EH_CONN_TYPE="$(json_get type <"${TMP_DIR}/eh_conn_meta.json")"
if [ -z "${EH_CONN_TYPE}" ]; then
	echo "ERROR: Could not find an Azure Event Hubs connector in the Fabric supported connection types." >&2
	echo "       Without a valid connection the eventstreams cannot be created and the Eventhouse" >&2
	echo "       tables stay empty. Supported connection types returned by the API:" >&2
	python3 -c "import json,sys; print('\n'.join(sorted(c.get('type','') for c in json.load(open(sys.argv[1])).get('value', []))))" "${TMP_DIR}/supported_conn_types.json" | sed 's/^/         /' >&2 || true
	exit 1
fi
echo "  using Event Hubs connector type '${EH_CONN_TYPE}'."

# Best-effort: make sure the '${FABRIC_CONSUMER_GROUP}' consumer group exists on the Event Hubs the
# eventstreams bind to. The main deployment (arm.json) already creates these, so this is only a safety
# net for environments where it doesn't. It is non-fatal: if the managed identity lacks Event Hubs
# management rights the create is skipped with a warning (the group is expected to already exist).
ensure_consumer_group() {
	local hub="$1"
	if az eventhubs eventhub consumer-group show --resource-group "${RESOURCES_NAME}" --namespace-name "${EVENTHUBS_NAMESPACE}" --eventhub-name "${hub}" --name "${FABRIC_CONSUMER_GROUP}" >/dev/null 2>&1; then
		echo "  consumer group '${FABRIC_CONSUMER_GROUP}' already exists on event hub '${hub}'."
		return 0
	fi
	echo "  creating consumer group '${FABRIC_CONSUMER_GROUP}' on event hub '${hub}'..."
	az eventhubs eventhub consumer-group create --resource-group "${RESOURCES_NAME}" --namespace-name "${EVENTHUBS_NAMESPACE}" --eventhub-name "${hub}" --name "${FABRIC_CONSUMER_GROUP}" >/dev/null 2>&1 \
		|| echo "  warning: could not create/verify consumer group '${FABRIC_CONSUMER_GROUP}' on event hub '${hub}' (it is expected to already exist from the main deployment; continuing)."
}
echo "Ensuring the '${FABRIC_CONSUMER_GROUP}' consumer group exists on the Event Hubs..."
ensure_consumer_group "data"
ensure_consumer_group "metadata"

create_eventstream() {
	local stream_name="$1" event_hub="$2" raw_table="$3" mapping="$4"
	echo "  creating eventstream '${stream_name}' (${event_hub} -> ${raw_table})..."

	# Idempotency: the deployment script re-runs on every deployment. Delete an existing eventstream
	# first (so nothing references its connection), then recreate the source connection and the
	# eventstream from scratch, so the current topology always wins and the eventstream can never
	# reference a stale/removed connection.
	local existing_es
	existing_es="$(fabric GET "/workspaces/${WORKSPACE_ID}/eventstreams" | find_by_name "${stream_name}")"
	if [ -n "${existing_es}" ]; then
		echo "    deleting existing eventstream '${stream_name}' (${existing_es}) so it can be recreated cleanly..."
		fabric DELETE "/workspaces/${WORKSPACE_ID}/eventstreams/${existing_es}" >/dev/null || { echo "    error: could not delete the existing eventstream ${stream_name}. See the Fabric API error above." >&2; exit 1; }
	fi

	# A Fabric connection for the Azure Event Hubs source. The connector's exact creation method
	# and parameter names were discovered above (eh_conn_meta.json); build the parameters from
	# that schema, mapping our namespace / event hub name onto whatever names the connector uses.
	# The display name is made unique per deployment (CONN_SUFFIX) because Fabric connection names are
	# tenant-unique and connections outlive the workspace, so a fixed name collides across redeploys
	# ('DuplicateConnectionName'). Best-effort delete older connections with the same prefix first so
	# they don't accumulate; then create a fresh, uniquely named connection and use its id.
	local conn_display="${stream_name}-source-${CONN_SUFFIX}"
	# Best-effort: delete connections left by earlier deployments that share the '<stream>-source'
	# prefix (both the old fixed name and previous unique-suffixed ones) so they don't accumulate.
	local old_id
	list_connection_ids_by_prefix "${stream_name}-source" | while read -r old_id; do
		[ -n "${old_id}" ] || continue
		echo "    deleting older Event Hubs connection ${old_id} (prefix '${stream_name}-source')..."
		fabric DELETE "/connections/${old_id}" >/dev/null 2>&1 || echo "    warning: could not delete older connection ${old_id} (leaving it as an orphan)."
	done
	local connection_id
	DISPLAY_NAME="${conn_display}" EH="${event_hub}" \
	EH_META_FILE="${TMP_DIR}/eh_conn_meta.json" \
	python3 - >"${TMP_DIR}/connection.json" <<'PY'
import json, os, sys

meta = json.load(open(os.environ["EH_META_FILE"]))
namespace_fqdn = os.environ["EVENTHUBS_FQDN"]
event_hub_name = os.environ["EH"]
conn_str = os.environ["EVENTHUBS_CONNECTION_STRING"]

# Known aliases the Event Hubs connector might use for its parameters, mapped to our values.
NAMESPACE_ALIASES = {"server", "servername", "namespace", "host", "hostname",
					 "fullyqualifiednamespace", "endpoint", "eventhubnamespace"}
EVENTHUB_ALIASES = {"eventhubname", "entitypath", "eventhub", "path", "eventhubentitypath", "hub"}
# Some connectors take a single connection string (with the entity path embedded) instead.
CONNSTR_ALIASES = {"connectionstring", "eventhubconnectionstring", "sharedaccesssignature"}

methods = meta.get("creationMethods") or []
chosen_method, chosen_params, missing = None, None, None
for method in methods:
	params = method.get("parameters") or []
	built, unmapped = [], []
	for p in params:
		name = p.get("name", "")
		low = name.lower()
		required = p.get("required", False)
		if low in NAMESPACE_ALIASES:
			built.append({"dataType": "Text", "name": name, "value": namespace_fqdn})
		elif low in EVENTHUB_ALIASES:
			built.append({"dataType": "Text", "name": name, "value": event_hub_name})
		elif low in CONNSTR_ALIASES:
			# Ensure the entity path is present for a namespace-level connection string.
			v = conn_str if "entitypath=" in conn_str.lower() else conn_str.rstrip(";") + ";EntityPath=" + event_hub_name
			built.append({"dataType": "Text", "name": name, "value": v})
		elif required:
			unmapped.append(name)
	if not unmapped:
		chosen_method, chosen_params = method, built
		break
	if missing is None:
		missing = unmapped

if chosen_method is None:
	sys.stderr.write("ERROR: The Event Hubs connector ('%s') requires parameters this script could not map.\n" % meta.get("type", ""))
	sys.stderr.write("       Unmapped required parameters: %s\n" % ", ".join(missing or []))
	sys.stderr.write("       Full connector creation-method schema:\n")
	sys.stderr.write(json.dumps(methods, indent=2))
	sys.stderr.write("\n")
	sys.exit(2)

# Generate an Event Hubs SAS token from the namespace connection string. Fabric's
# SharedAccessSignature credential expects an actual SAS token string (not a connection string);
# passing the connection string fails with IncorrectCredentials/AccessUnauthorized.
import base64, hashlib, hmac, time, urllib.parse

def parse_conn_str(cs):
	parts = {}
	for seg in cs.split(";"):
		if "=" in seg:
			k, v = seg.split("=", 1)
			parts[k.strip().lower()] = v.strip()
	return parts

cs_parts = parse_conn_str(conn_str)
key_name = cs_parts.get("sharedaccesskeyname", "")
key_value = cs_parts.get("sharedaccesskey", "")
if not key_name or not key_value:
	sys.stderr.write("ERROR: EVENTHUBS_CONNECTION_STRING is missing SharedAccessKeyName/SharedAccessKey; cannot build a SAS token.\n")
	sys.exit(4)

# Scope the token to the specific event hub: https://<namespace>/<eventHubName>
resource_uri = "https://%s/%s" % (namespace_fqdn, event_hub_name)
encoded_uri = urllib.parse.quote_plus(resource_uri)
expiry = str(int(time.time()) + 365 * 24 * 60 * 60)  # 1 year
string_to_sign = (encoded_uri + "\n" + expiry).encode("utf-8")
signature = base64.b64encode(hmac.new(key_value.encode("utf-8"), string_to_sign, hashlib.sha256).digest())
sas_token = "SharedAccessSignature sr=%s&sig=%s&se=%s&skn=%s" % (
	encoded_uri, urllib.parse.quote(signature), expiry, key_name)

# Build the credential using whatever type the connector supports (prefer SAS, then Key, then Basic).
supported_creds = [c.lower() for c in (meta.get("supportedCredentialTypes") or [])]
if not supported_creds or "sharedaccesssignature" in supported_creds:
	credentials = {"credentialType": "SharedAccessSignature", "token": sas_token}
elif "key" in supported_creds:
	credentials = {"credentialType": "Key", "key": key_value}
elif "basic" in supported_creds:
	credentials = {"credentialType": "Basic", "username": key_name, "password": key_value}
else:
	sys.stderr.write("ERROR: The Event Hubs connector ('%s') does not support a credential type this script can supply.\n" % meta.get("type", ""))
	sys.stderr.write("       Supported credential types: %s\n" % ", ".join(meta.get("supportedCredentialTypes") or []))
	sys.exit(3)

print(json.dumps({
	"connectivityType": "ShareableCloud",
	"displayName": os.environ["DISPLAY_NAME"],
	"connectionDetails": {
		"type": meta["type"],
		"creationMethod": chosen_method.get("name", ""),
		"parameters": chosen_params,
	},
	"credentialDetails": {
		"singleSignOnType": "None",
		"connectionEncryption": "NotEncrypted",
		# The deployment-script container generally can't perform the live data-source test
		# against Event Hubs, so skip it when the connector allows (ingestion is validated later
		# by the eventstream). Otherwise the create fails with DM_GWPipeline_Gateway_DataSourceAccessError.
		"skipTestConnection": bool(meta.get("supportsSkipTestConnection", False)),
		"credentials": credentials,
	},
}))
PY
	connection_id="$(fabric POST "/connections" "${TMP_DIR}/connection.json" | json_get id)" || { echo "    error: could not create the Event Hubs connection for ${stream_name}. Without it the Eventhouse tables stay empty. See the Fabric API error above." >&2; exit 1; }
	if [ -z "${connection_id}" ]; then
		echo "    error: creating the Event Hubs connection for ${stream_name} returned no id." >&2
		exit 1
	fi
	echo "    created Event Hubs connection '${stream_name}-source' (${connection_id})."

	# The eventstream topology: Azure Event Hub source -> Eventhouse DirectIngestion destination.
	ES_NAME="${stream_name}" CONNECTION_ID="${connection_id}" CONSUMER_GROUP="${FABRIC_CONSUMER_GROUP}" \
	WORKSPACE_ID="${WORKSPACE_ID}" EVENTHOUSE_ID="${EVENTHOUSE_ID}" KQL_DATABASE_ID="${KQL_DATABASE_ID}" \
	RAW_TABLE="${raw_table}" MAPPING="${mapping}" \
	CREATE_FILE="${TMP_DIR}/eventstream_create.json" \
	python3 - <<'PY'
import base64, json, os

source_node = os.environ["ES_NAME"] + "-source"
stream_node = os.environ["ES_NAME"] + "-stream"
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
	"streams": [
		{
			"name": stream_node,
			"type": "DefaultStream",
			"properties": {},
			"inputNodes": [{"name": source_node}],
		}
	],
	"destinations": [
		{
			"name": os.environ["ES_NAME"] + "-eventhouse",
			"type": "Eventhouse",
			"properties": {
				# itemId is the KQL DATABASE item id. Although the API docs describe it as the
				# "Eventhouse item id", in practice the DirectIngestion destination resolves the
				# Eventhouse/KQL database (and ingests) only when itemId points at the KQL database.
				"dataIngestionMode": "DirectIngestion",
				"workspaceId": os.environ["WORKSPACE_ID"],
				"itemId": os.environ["KQL_DATABASE_ID"],
				"tableName": os.environ["RAW_TABLE"],
				"connectionName": os.environ["ES_NAME"] + "-ingest",
				"mappingRuleName": os.environ["MAPPING"],
			},
			"inputNodes": [{"name": stream_node}],
		}
	],
	"operators": [],
	"compatibilityLevel": "1.1",
}
definition = base64.b64encode(json.dumps(topology).encode("utf-8")).decode()
platform = base64.b64encode(json.dumps({
	"$schema": "https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json",
	"metadata": {"type": "Eventstream", "displayName": os.environ["ES_NAME"]},
	"config": {"version": "2.0", "logicalId": "00000000-0000-0000-0000-000000000000"},
}).encode("utf-8")).decode()
parts = [
	{"path": "eventstream.json", "payload": definition, "payloadType": "InlineBase64"},
	{"path": ".platform", "payload": platform, "payloadType": "InlineBase64"},
]
open(os.environ["CREATE_FILE"], "w").write(json.dumps({
	"displayName": os.environ["ES_NAME"],
	"type": "Eventstream",
	"definition": {"parts": parts},
}))
PY
	fabric POST "/workspaces/${WORKSPACE_ID}/items" "${TMP_DIR}/eventstream_create.json" >/dev/null || { echo "    error: could not create eventstream ${stream_name}. Without it the Eventhouse tables stay empty. See the Fabric API error above." >&2; exit 1; }

	# Diagnostic: print the destination itemId + status + any error the eventstream stored, so a
	# 'Warning'/'Failed' destination (which surfaces as empty tables / 'Item not found' in the portal)
	# reveals its underlying cause in the deployment log.
	local new_es
	new_es="$(fabric GET "/workspaces/${WORKSPACE_ID}/eventstreams" | find_by_name "${stream_name}")"
	if [ -n "${new_es}" ]; then
		echo "    verifying eventstream '${stream_name}' destination (expected KQL database itemId=${KQL_DATABASE_ID}):"
		fabric GET "/workspaces/${WORKSPACE_ID}/eventstreams/${new_es}/topology" \
			| python3 -c "import json,sys; d=json.load(sys.stdin); [print('      destination', x.get('name'), 'itemId=', x.get('properties',{}).get('itemId'), 'status=', x.get('status'), 'error=', json.dumps(x.get('error'))) for x in d.get('destinations', [])]" || true
	fi
}

echo "Creating the OPC UA eventstreams..."
create_eventstream "${DATA_EVENTSTREAM_NAME}" "data" "opcua_raw" "opcua_mapping"
create_eventstream "${METADATA_EVENTSTREAM_NAME}" "metadata" "opcua_metadata_raw" "opcua_metadata_mapping"

# The Eventhouse DirectIngestion connection provisions asynchronously and is briefly reported as
# 'Warning' right after the eventstream is created; ingestion into opcua_raw starts once it becomes
# healthy (usually within a couple of minutes). Poll opcua_raw for rows so the deployment confirms
# data is actually flowing rather than leaving it ambiguous. This is best-effort (non-fatal): if no
# rows appear in the window it may just need a little longer, or the source may not be producing yet.
echo "Waiting for data to start flowing into 'opcua_raw' (DirectIngestion connection initializes asynchronously)..."
OPCUA_ROWS="0"
for _ in $(seq 1 24); do
	sleep 15
	OPCUA_ROWS="$(KUSTO_DB="${KQL_DATABASE_NAME}" KUSTO_URI="${QUERY_URI}" python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request
body = json.dumps({"db": os.environ["KUSTO_DB"], "csl": "opcua_raw | count"}).encode("utf-8")
req = urllib.request.Request(
	os.environ["KUSTO_URI"].rstrip("/") + "/v1/rest/query",
	data=body,
	headers={"Authorization": "Bearer " + os.environ["KUSTO_TOKEN"], "Content-Type": "application/json", "Accept": "application/json"},
	method="POST",
)
try:
	with urllib.request.urlopen(req) as response:
		result = json.loads(response.read() or b"{}")
	count = 0
	for table in result.get("Tables", []):
		for row in table.get("Rows", []):
			if row:
				count = row[0]
	print(count)
except Exception:
	print(0)
PY
)"
	if [ "${OPCUA_ROWS}" != "0" ] && [ -n "${OPCUA_ROWS}" ]; then
		break
	fi
done
if [ "${OPCUA_ROWS}" != "0" ] && [ -n "${OPCUA_ROWS}" ]; then
	echo "  ingestion confirmed: 'opcua_raw' now has ${OPCUA_ROWS} rows."
else
	echo "  note: no rows in 'opcua_raw' yet. The DirectIngestion connection may still be initializing;"
	echo "        wait a few minutes and check 'opcua_raw | count'. Also confirm the edge/simulation is"
	echo "        publishing to the '${EVENTHUBS_NAMESPACE}' event hubs."
fi

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

# ---------------------------------------------------------------------------
# Step 7: Re-trigger the OPC UA metadata from Azure IoT Operations
#
# AIO's connector for OPC UA emits the OPC UA PubSub *MetaData* message only when an asset/dataset
# definition CHANGES (or the connector restarts) - it is not sent on a schedule. Because Fabric is
# deployed AFTER AIO, the metadata eventstream created above starts reading from 'latest' and never
# sees the one-time metadata AIO already published. Without it 'opcua_metadata' stays empty and every
# query/dashboard that joins telemetry to metadata (station/line names, OEE, the UNS graph) returns
# nothing. So we "touch" each AIO OPC UA asset (a no-op control-plane update) to make the connector
# re-emit its metadata, which the freshly created eventstream now captures.
#
# The AIO assets are Microsoft.DeviceRegistry ARM resources named '<host>-asset' (see
# SetupAzureIoTOperations.sh), so this works from this script's managed identity via the Azure
# control plane - no cluster/kubectl access is required. This is best-effort: on any failure the
# script logs guidance (touch the datasets manually) and still completes.
# ---------------------------------------------------------------------------

if [ -n "${RESOURCE_GROUP:-}" ]; then
	echo "Re-triggering OPC UA metadata: touching the Azure IoT Operations OPC UA assets so AIO resends it..."
	TOUCHED=0
	# List all DeviceRegistry assets in the resource group; touch the OPC UA telemetry assets only.
	ASSET_IDS="$(az resource list \
		--resource-group "${RESOURCE_GROUP}" \
		${SUBSCRIPTION_ID:+--subscription "${SUBSCRIPTION_ID}"} \
		--resource-type "Microsoft.DeviceRegistry/assets" \
		--query "[?ends_with(name, '-asset')].id" -o tsv 2>/dev/null || true)"
	if [ -z "${ASSET_IDS}" ]; then
		echo "  note: no Microsoft.DeviceRegistry/assets found in '${RESOURCE_GROUP}'. If AIO was deployed to a"
		echo "        different resource group, touch the datasets manually (see fabric.md) so metadata is resent."
	else
		TOUCH_STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		while IFS= read -r ASSET_ID; do
			[ -z "${ASSET_ID}" ] && continue
			# A tag update is a no-op change on the asset resource that still bumps its version, which is
			# enough to make the connector for OPC UA re-publish the asset's metadata message.
			if az resource tag \
				--ids "${ASSET_ID}" \
				--operation merge \
				--tags "fabricMetadataRefresh=${TOUCH_STAMP}" \
				--output none 2>/dev/null; then
				echo "  touched: ${ASSET_ID##*/}"
				TOUCHED=$((TOUCHED + 1))
			else
				echo "  warning: could not touch ${ASSET_ID##*/}; touch it manually (see fabric.md)."
			fi
		done <<-EOF
		${ASSET_IDS}
		EOF
		echo "  re-triggered metadata for ${TOUCHED} OPC UA asset(s)."
		echo "  it can take a minute or two for 'opcua_metadata' to populate in the eventhouse."
	fi
else
	echo "note: RESOURCE_GROUP not set; skipping the OPC UA metadata re-trigger. After deployment, touch the"
	echo "      Azure IoT Operations datasets manually so AIO resends OPC UA metadata (see fabric.md)."
fi

echo "Fabric setup complete. Workspace '${FABRIC_WORKSPACE_NAME}' contains the '${EVENTHOUSE_NAME}' eventhouse"
echo "(OPC UA tables, expansion functions, materialized view and OEE functions) and the '${LAKEHOUSE_NAME}' lakehouse."

if [ -n "${AZ_SCRIPTS_OUTPUT_PATH:-}" ]; then
	python3 - "${WORKSPACE_ID}" "${EVENTHOUSE_ID}" "${KQL_DATABASE_ID}" "${LAKEHOUSE_ID}" "${QUERY_URI}" "${KQL_DATABASE_NAME}" >"${AZ_SCRIPTS_OUTPUT_PATH}" <<'PY'
import json, sys
print(json.dumps({"workspaceId": sys.argv[1], "eventhouseId": sys.argv[2], "kqlDatabaseId": sys.argv[3], "lakehouseId": sys.argv[4], "queryServiceUri": sys.argv[5], "kqlDatabaseName": sys.argv[6]}))
PY
fi
