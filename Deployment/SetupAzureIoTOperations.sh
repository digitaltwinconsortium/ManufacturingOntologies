#!/usr/bin/env bash
# SetupAzureIoTOperations.sh - Arc-enable the simulation VM's K3s cluster and install
# Azure IoT Operations (AIO), then connect AIO's OPC UA connector to the factory
# simulation OPC UA servers (both production lines) and forward their data to the same
# Event Hubs namespace via a Kafka data flow.
#
# This script is invoked by Bootstrap.sh after the production line simulation has started.
# It is idempotent/best-effort: individual steps log warnings but do not abort the whole
# run, so a partially-provisioned cluster can be re-run.
#
# Arguments (all required, passed positionally by Bootstrap.sh):
#   $1  RESOURCE_GROUP            Azure resource group name
#   $2  LOCATION                  Azure region (e.g. eastus)
#   $3  RESOURCES_NAME            Base name used for all resources (parameters('resourcesName'))
#   $4  MANAGED_IDENTITY_CLIENT_ID  Client ID of the shared user-assigned managed identity
#   $5  SUBSCRIPTION_ID           Azure subscription ID
#   $6  CUSTOM_LOCATIONS_OID      Object ID of the 'custom-locations' Entra app (pre-computed by a user)
#   $7  EVENTHUBS_HOST            Event Hubs namespace host, e.g. <namespace>.servicebus.windows.net
#
# The Event Hubs connection string is intentionally NOT passed here: the AIO data flow
# authenticates to Event Hubs with the managed identity (granted 'Azure Event Hubs Data
# Sender'), so no secret is handled by this script.

set -u
set -o pipefail

RESOURCE_GROUP="${1:-}"
LOCATION="${2:-}"
RESOURCES_NAME="${3:-}"
MANAGED_IDENTITY_CLIENT_ID="${4:-}"
SUBSCRIPTION_ID="${5:-}"
CUSTOM_LOCATIONS_OID="${6:-}"
EVENTHUBS_HOST="${7:-}"

KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
export KUBECONFIG="${KUBECONFIG_PATH}"

# Derived Azure resource names (must match Deployment/arm.json).
CLUSTER_NAME="${RESOURCES_NAME}-Arc"
# The AIO instance name must be lowercase (^[a-z0-9][a-z0-9-]*[a-z0-9]$).
AIO_INSTANCE_NAME="$(printf '%s-aio' "${RESOURCES_NAME}" | tr '[:upper:]' '[:lower:]')"
# Schema registry name must be lowercase (^[a-z0-9][a-z0-9-]*[a-z0-9]$), matching arm.json's
# toLower(concat(resourcesName, '-schemaregistry')).
SCHEMA_REGISTRY_NAME="$(printf '%s-schemaregistry' "${RESOURCES_NAME}" | tr '[:upper:]' '[:lower:]')"
# Azure IoT Operations requires a Device Registry namespace (one per instance) passed to
# 'az iot ops create --ns-resource-id'. Name must be lowercase.
AIO_NAMESPACE_NAME="$(printf '%s-aions' "${RESOURCES_NAME}" | tr '[:upper:]' '[:lower:]')"
# The AIO data flows write to the SAME event hubs that Azure Data Explorer, Microsoft Fabric
# and Azure Databricks already consume, so the existing OPC UA PubSub expansion policies
# (OPCUATelemetryExpand / OPCUAMetaDataExpand) parse the AIO output unchanged.
TELEMETRY_EVENTHUB_NAME="data"
METADATA_EVENTHUB_NAME="metadata"
DATAFLOW_ENDPOINT_NAME="eventhubs"
TELEMETRY_DATAFLOW_NAME="opcua-telemetry-to-eventhubs"
METADATA_DATAFLOW_NAME="opcua-metadata-to-eventhubs"
# Working directory for the generated data flow / asset configuration files.
AIO_CONFIG_DIR="$(mktemp -d)"

# The persistency.json files are the source of truth for which OPC UA nodes
# are published. AIO reads the SAME files so it samples exactly the same node set. The repo is
# downloaded to /opt/ManufacturingOntologies-main by Bootstrap.sh; the per-line publisher
# configuration lives under Tools/FactorySimulation/PublisherConfig/<line>/persistency.json.
REPO_DIR="${REPO_DIR:-/opt/ManufacturingOntologies-main}"
PUBLISHER_CONFIG_DIR="${REPO_DIR}/Tools/FactorySimulation/PublisherConfig"
# Production lines to onboard (one PublisherConfig/<line>/persistency.json each).
LINES=("Munich" "Seattle")
# Default OPC UA port for endpoints whose persistency.json EndpointUrl omits it.
OPC_UA_PORT="4840"
# Stations (first dotted label of the OPC UA host) that must NOT be onboarded as AIO OPC UA
# devices/assets: 'commander' is the UA Cloud Commander command/response server and 'mes' is the
# MES server - neither is a telemetry source for the connector for OPC UA.
EXCLUDED_STATIONS="commander mes"
# AIO's connector for OPC UA stores its application instance certificate (managed by
# cert-manager) in this Kubernetes secret after 'az iot ops create'.
AIO_OPCUA_CERT_SECRET="aio-opc-opcuabroker-default-application-cert"
AIO_NAMESPACE="azure-iot-operations"

echo "=== Azure IoT Operations setup started: $(date -Is) ==="

# --------------------------
# Validate inputs
# --------------------------
missing=""
for pair in "RESOURCE_GROUP=${RESOURCE_GROUP}" "LOCATION=${LOCATION}" "RESOURCES_NAME=${RESOURCES_NAME}" \
			"MANAGED_IDENTITY_CLIENT_ID=${MANAGED_IDENTITY_CLIENT_ID}" "SUBSCRIPTION_ID=${SUBSCRIPTION_ID}" \
			"EVENTHUBS_HOST=${EVENTHUBS_HOST}"; do
  name="${pair%%=*}"
  val="${pair#*=}"
  if [ -z "${val}" ]; then
	missing="${missing} ${name}"
  fi
done
if [ -n "${missing}" ]; then
  echo "!!! ERROR: missing required argument(s):${missing}. Aborting AIO setup."
  exit 1
fi

if [ -z "${CUSTOM_LOCATIONS_OID}" ]; then
  echo "!!! ERROR: CUSTOM_LOCATIONS_OID is empty. Enabling Arc custom locations requires the"
  echo "    object ID of the 'custom-locations' Microsoft Entra application, which must be"
  echo "    computed with a user account and passed in via the customLocationsOid template"
  echo "    parameter. Aborting AIO setup (the simulation is unaffected)."
  exit 1
fi

# RUN_LAST_RC holds the exit code of the most recent `run` invocation. run() always
# returns 0 (best-effort: warn but continue) so the script keeps going on failure;
# callers that must branch on the real outcome inspect RUN_LAST_RC instead.
RUN_LAST_RC=0
# Helper: log a command, run it, warn (but continue) on failure.
run() {
  echo
  echo ">>> $*"
  "$@"
  local rc=$?
  RUN_LAST_RC=${rc}
  if [ "${rc}" -ne 0 ]; then
	echo "!!! WARNING: command failed (rc=${rc}): $*"
  fi
  return 0
}

# --------------------------
# 1. Authenticate to Azure with the VM's user-assigned managed identity
# --------------------------
echo
echo "=== Logging in to Azure with the managed identity ==="
# Newer Azure CLI removed '--username' for managed-identity login; use '--client-id' for a
# user-assigned managed identity.
if ! az login --identity --client-id "${MANAGED_IDENTITY_CLIENT_ID}" --allow-no-subscriptions >/dev/null; then
  echo "!!! ERROR: az login --identity failed. Aborting AIO setup."
  exit 1
fi
run az account set --subscription "${SUBSCRIPTION_ID}"
# Tenant ID is required by the Event Hubs (Kafka) dataflow endpoint's managed-identity auth.
TENANT_ID="$(az account show --query tenantId -o tsv 2>/dev/null)"

# --------------------------
# 2. Install/refresh the required Azure CLI extensions
# --------------------------
echo
echo "=== Installing Azure CLI extensions (connectedk8s, azure-iot-ops) ==="
run az extension add --upgrade --yes --name connectedk8s
run az extension add --upgrade --yes --name azure-iot-ops

# jq is used to parse persistency.json into AIO asset data points.
if ! command -v jq >/dev/null 2>&1; then
  echo ">>> Installing jq"
  run sudo apt-get update
  run sudo apt-get install -y jq
fi

# --------------------------
# 3. Verify the resource providers AIO/Arc need are registered
# --------------------------
# NOTE: Registering a resource provider is a SUBSCRIPTION-scope action
# (Microsoft.Features/.../register/action) that the deployment's user-assigned managed identity
# (granted only resource-group-scope rights) cannot perform - the calls always fail with
# AuthorizationFailed. Registration is a documented prerequisite performed once by a subscription
# Owner/Contributor (see the Prerequisites section of the repository README), so we do not attempt
# it here (it would only add noise to the log). 'az iot ops init' REQUIRES these providers, so we
# verify the state below and, if any are still not registered, warn with the exact command to run.
echo
echo "=== Verifying required resource providers are registered ==="
AIO_PROVIDERS="Microsoft.ExtendedLocation Microsoft.Kubernetes Microsoft.KubernetesConfiguration Microsoft.IoTOperations Microsoft.DeviceRegistry Microsoft.SecretSyncController"

# Verify registration state; collect any that are not registered.
unregistered=""
for rp in ${AIO_PROVIDERS}; do
  state="$(az provider show -n "${rp}" --query registrationState -o tsv 2>/dev/null)"
  if [ "${state}" != "Registered" ]; then
	unregistered="${unregistered} ${rp}"
  fi
done
if [ -n "${unregistered}" ]; then
  echo "!!! WARNING: the following resource providers are NOT registered on subscription ${SUBSCRIPTION_ID}:${unregistered}"
  echo "    'az iot ops init' will fail until they are registered. This is a subscription-scope"
  echo "    prerequisite (see the Prerequisites section of the repository README); a subscription"
  echo "    Owner/Contributor must run this once (the deployment managed identity cannot):"
  for rp in ${unregistered}; do
	echo "      az provider register --namespace ${rp} --subscription ${SUBSCRIPTION_ID}"
  done
fi

# --------------------------
# 4. Prepare the cluster host (watch/instance and file-descriptor limits)
# --------------------------
echo
echo "=== Preparing K3s host limits for AIO ==="
if ! grep -q "fs.inotify.max_user_instances=8192" /etc/sysctl.conf 2>/dev/null; then
  echo "fs.inotify.max_user_instances=8192" | sudo tee -a /etc/sysctl.conf >/dev/null
fi
if ! grep -q "fs.inotify.max_user_watches=524288" /etc/sysctl.conf 2>/dev/null; then
  echo "fs.inotify.max_user_watches=524288" | sudo tee -a /etc/sysctl.conf >/dev/null
fi
if ! grep -q "fs.file-max=100000" /etc/sysctl.conf 2>/dev/null; then
  echo "fs.file-max=100000" | sudo tee -a /etc/sysctl.conf >/dev/null
fi
run sudo sysctl -p

# --------------------------
# 5. Arc-enable the K3s cluster (with OIDC issuer + workload identity for AIO)
# --------------------------
echo
echo "=== Connecting the cluster to Azure Arc ==="
run az connectedk8s connect \
  --name "${CLUSTER_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --disable-auto-upgrade

# Configure K3s with the OIDC issuer URL that AIO's workload identity requires.
ISSUER_URL="$(az connectedk8s show --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" \
  --query oidcIssuerProfile.issuerUrl -o tsv 2>/dev/null)"
if [ -n "${ISSUER_URL}" ]; then
  echo "OIDC issuer URL: ${ISSUER_URL}"
  sudo mkdir -p /etc/rancher/k3s
  sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<EOF
kube-apiserver-arg:
  - service-account-issuer=${ISSUER_URL}
  - service-account-max-token-expiration=24h
EOF
  run sudo systemctl restart k3s
  # Give the API server a moment to come back up.
  sleep 20
  run sudo kubectl get nodes
else
  echo "!!! WARNING: could not read the OIDC issuer URL; workload identity may not function."
fi

# --------------------------
# 6. Enable the cluster-connect and custom-locations features
# --------------------------
echo
echo "=== Enabling Arc features (cluster-connect, custom-locations) ==="
run az connectedk8s enable-features \
  --name "${CLUSTER_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --custom-locations-oid "${CUSTOM_LOCATIONS_OID}" \
  --features cluster-connect custom-locations

# --------------------------
# 7. Install Azure IoT Operations
# --------------------------
echo
echo "=== Initializing Azure IoT Operations foundation ==="
# 'az iot ops init' and 'az iot ops create' hard-fail unless the Arc-connected cluster
# reports connectivityStatus='Connected'. The k3s restart above (to apply the OIDC issuer
# config) bounces the Arc agent pods and resets that heartbeat, so 'az connectedk8s connect'
# returning is not enough - wait for connectivity to re-establish before installing AIO.
arc_connected=false
arc_wait_seconds=0
while [ "${arc_wait_seconds}" -lt 600 ]; do
  arc_status="$(az connectedk8s show --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" --query connectivityStatus -o tsv 2>/dev/null)"
  if [ "${arc_status}" = "Connected" ]; then
    arc_connected=true
    echo ">>> Arc cluster '${CLUSTER_NAME}' is Connected after ${arc_wait_seconds}s"
    break
  fi
  echo ">>> Waiting for Arc connectivity (status='${arc_status:-unknown}', ${arc_wait_seconds}s elapsed)..."
  sleep 15
  arc_wait_seconds=$((arc_wait_seconds + 15))
done
if [ "${arc_connected}" != "true" ]; then
  echo "!!! WARNING: Arc cluster '${CLUSTER_NAME}' did not reach 'Connected' within 600s; 'az iot ops init' may fail."
fi
run az iot ops init \
  --resource-group "${RESOURCE_GROUP}" \
  --cluster "${CLUSTER_NAME}"

SCHEMA_REGISTRY_ID="$(az iot ops schema registry show \
  --name "${SCHEMA_REGISTRY_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query id -o tsv 2>/dev/null)"
if [ -z "${SCHEMA_REGISTRY_ID}" ]; then
  # Fall back to the generic resource lookup if the iot ops sub-command is unavailable.
  SCHEMA_REGISTRY_ID="$(az resource show \
	--resource-group "${RESOURCE_GROUP}" \
	--name "${SCHEMA_REGISTRY_NAME}" \
	--resource-type Microsoft.DeviceRegistry/schemaRegistries \
	--query id -o tsv 2>/dev/null)"
fi

# 'az iot ops create' requires a Device Registry namespace (--ns-resource-id). Create it
# (idempotent: reuse if it already exists) and capture its resource id.
echo
echo "=== Creating the Device Registry namespace for Azure IoT Operations ==="
run az iot ops ns create \
  --name "${AIO_NAMESPACE_NAME}" \
  --resource-group "${RESOURCE_GROUP}"
NAMESPACE_ID="$(az iot ops ns show \
  --name "${AIO_NAMESPACE_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query id -o tsv 2>/dev/null)"
if [ -z "${NAMESPACE_ID}" ]; then
  NAMESPACE_ID="$(az resource show \
	--resource-group "${RESOURCE_GROUP}" \
	--name "${AIO_NAMESPACE_NAME}" \
	--resource-type Microsoft.DeviceRegistry/namespaces \
	--query id -o tsv 2>/dev/null)"
fi

echo
echo "=== Creating the Azure IoT Operations instance ==="
run az iot ops create \
  --resource-group "${RESOURCE_GROUP}" \
  --cluster "${CLUSTER_NAME}" \
  --name "${AIO_INSTANCE_NAME}" \
  --sr-resource-id "${SCHEMA_REGISTRY_ID}" \
  --ns-resource-id "${NAMESPACE_ID}"
# NOTE: 'az iot ops create' may warn that the IoT Operations Arc extension service principal needs
# the 'Azure Device Registry Administrator' role on the schema registry. The deployment's managed
# identity cannot create that role assignment (it requires Microsoft.Authorization/roleAssignments
# /write, a subscription-scope right the MI lacks). The instance is still created; if schema
# operations later fail, a subscription Owner should grant that role on the schema registry.

# --------------------------
# 7b. Create an Azure Arc site (site manager) scoped to the resource group
# --------------------------
# A site groups Arc resources for OT users. Sites have a 1:1 relationship with a resource group, so
# scoping the site to this resource group automatically collects the AIO instance (no explicit
# assignment needed). The site is named after the resource group, as requested. The site name must
# match ^[a-zA-Z0-9][a-zA-Z0-9-_]{2,22}[a-zA-Z0-9]$.
echo
echo "=== Creating an Azure Arc site named '${RESOURCE_GROUP}' (scoped to the resource group) ==="
run az extension add --upgrade --yes --name site
run az site create \
  --name "${RESOURCE_GROUP}" \
  --resource-group "${RESOURCE_GROUP}" \
  --subscription "${SUBSCRIPTION_ID}" \
  --display-name "${RESOURCE_GROUP}"

# --------------------------
# 8. Enable managed-identity secret/identity access for the AIO instance
# --------------------------
echo
echo "=== Assigning the user-assigned managed identity to the AIO instance (for cloud auth) ==="
MANAGED_IDENTITY_RESOURCE_ID="$(az identity show \
  --name "${RESOURCES_NAME}-Identity" \
  --resource-group "${RESOURCE_GROUP}" \
  --query id -o tsv 2>/dev/null)"
if [ -n "${MANAGED_IDENTITY_RESOURCE_ID}" ]; then
  run az iot ops identity assign \
	--resource-group "${RESOURCE_GROUP}" \
	--name "${AIO_INSTANCE_NAME}" \
	--mi-user-assigned "${MANAGED_IDENTITY_RESOURCE_ID}"
else
  echo "!!! WARNING: could not resolve the managed identity resource ID; skipping identity assignment."
fi

# --------------------------
# 9. Create the Event Hubs (Kafka) data flow endpoint
# --------------------------
# The endpoint is created from a config file so it can set cloudEventAttributes=Propagate,
# which keeps the OPC UA connector's CloudEvent attributes (subject, time) available to the
# data flow map as message metadata. Authentication uses the VM's user-assigned managed
# identity (granted 'Azure Event Hubs Data Sender' by the ARM template), so no secret is used.
echo
echo "=== Creating the Event Hubs Kafka data flow endpoint ==="
ENDPOINT_CONFIG="${AIO_CONFIG_DIR}/endpoint-eventhubs.json"
cat > "${ENDPOINT_CONFIG}" <<EOF
{
  "endpointType": "Kafka",
  "kafkaSettings": {
	"host": "${EVENTHUBS_HOST}:9093",
	"tls": {
	  "mode": "Enabled"
	},
	"authentication": {
	  "method": "UserAssignedManagedIdentity",
	  "userAssignedManagedIdentitySettings": {
		"clientId": "${MANAGED_IDENTITY_CLIENT_ID}",
		"tenantId": "${TENANT_ID}",
		"scope": "https://${EVENTHUBS_HOST}/.default"
	  }
	},
	"cloudEventAttributes": "Propagate"
  }
}
EOF
run az iot ops dataflow endpoint apply \
  --resource-group "${RESOURCE_GROUP}" \
  --instance "${AIO_INSTANCE_NAME}" \
  --name "${DATAFLOW_ENDPOINT_NAME}" \
  --config-file "${ENDPOINT_CONFIG}"

# The built-in local MQTT broker endpoint ('default') must also propagate CloudEvent
# attributes so 'subject'/'time' reach the map transform. Patch it via a config file too.
echo
echo "=== Ensuring the local MQTT broker endpoint propagates CloudEvent attributes ==="
MQTT_ENDPOINT_CONFIG="${AIO_CONFIG_DIR}/endpoint-mqtt.json"
cat > "${MQTT_ENDPOINT_CONFIG}" <<EOF
{
  "endpointType": "Mqtt",
  "mqttSettings": {
	"host": "aio-broker:18883",
	"tls": {
	  "mode": "Enabled"
	},
	"authentication": {
	  "method": "ServiceAccountToken",
	  "serviceAccountTokenSettings": {
		"audience": "aio-internal"
	  }
	},
	"cloudEventAttributes": "Propagate"
  }
}
EOF
run az iot ops dataflow endpoint apply \
  --resource-group "${RESOURCE_GROUP}" \
  --instance "${AIO_INSTANCE_NAME}" \
  --name "default" \
  --config-file "${MQTT_ENDPOINT_CONFIG}"

# --------------------------
# 10. Register the simulation OPC UA servers as AIO devices/assets (both lines)
# --------------------------
# The set of published OPC UA nodes is taken directly from persistency.json
# files, so AIO samples exactly the same nodes. persistency.json is an array of
# { EndpointUrl, OpcNodes[{ Id, OpcSamplingInterval, OpcPublishingInterval, ... }], ... }.
# For each EndpointUrl we create an AIO device + OPC UA inbound endpoint, then an asset whose
# data points map one-to-one to OpcNodes (dataSource = the OPC UA NodeId, samplingInterval =
# OpcSamplingInterval). This is the AIO equivalent of persistency.json's OpcNodes.
echo
echo "=== Registering OPC UA devices/assets from persistency.json (both production lines) ==="

# Build a NodeId-identifier -> OPC UA browse name map from the station information model
# (Station.NodeSet2.xml) so telemetry data points can be named by their real browse name
# (e.g. EnergyConsumption) instead of a generic node-<index>. The browse name becomes the
# telemetry Payload key and therefore opcua_telemetry.Name in ADX/Fabric/Databricks, which the
# dashboards and OEE functions filter on. Each UAVariable line looks like:
#   <UAVariable NodeId="ns=1;i=406" BrowseName="1:EnergyConsumption" ...>
# Extract "<identifier> <BrowseName>" pairs (dropping the "<namespaceIndex>:" browse-name prefix)
# and fold them into a JSON object with jq. If the NodeSet is missing, the map stays empty and the
# import falls back to node-<index>.
STATION_NODESET="${REPO_DIR}/Tools/FactorySimulation/Station/Station.NodeSet2.xml"
NODE_NAME_MAP="{}"
if [ -f "${STATION_NODESET}" ]; then
  NODE_NAME_MAP="$(grep -oE '<UAVariable [^>]*>' "${STATION_NODESET}" \
    | sed -nE 's/.*NodeId="[^"]*;i=([0-9]+)"[^>]*BrowseName="([^"]*:)?([^"]+)".*/\1 \3/p' \
    | jq -Rn 'reduce (inputs | split(" ")) as $p ({}; .[$p[0]] = $p[1])')"
  [ -n "${NODE_NAME_MAP}" ] || NODE_NAME_MAP="{}"
fi

for line in "${LINES[@]}"; do
  persistency="${PUBLISHER_CONFIG_DIR}/${line}/persistency.json"
  if [ ! -f "${persistency}" ]; then
	echo "!!! WARNING: ${persistency} not found; skipping line ${line}."
	continue
  fi
  echo
  echo "=== Line ${line} (${persistency}) ==="

  # Number of endpoint entries in this persistency.json.
  endpoint_count="$(jq 'length' "${persistency}" 2>/dev/null)"
  if [ -z "${endpoint_count}" ] || [ "${endpoint_count}" = "0" ]; then
	echo "!!! WARNING: no endpoints found in ${persistency}; skipping."
	continue
  fi

  idx=0
  while [ "${idx}" -lt "${endpoint_count}" ]; do
	endpoint_url="$(jq -r ".[${idx}].EndpointUrl" "${persistency}")"
	# Host portion of opc.tcp://<host>[:port]/  ->  <host>
	host="$(printf '%s' "${endpoint_url}" | sed -E 's#^opc\.tcp://##; s#/.*$##; s#:[0-9]+$##')"
	# Station is the first dotted label of the host (e.g. 'commander.munich' -> 'commander').
	station="$(printf '%s' "${host}" | cut -d. -f1 | tr '[:upper:]' '[:lower:]')"
	# Skip non-telemetry servers: 'commander' is the UA Cloud Commander command/response server
	# and 'mes' is the MES server; neither is onboarded as an AIO OPC UA device/asset.
	case " ${EXCLUDED_STATIONS} " in
	  *" ${station} "*)
		echo
		echo "--- skipping ${host} (station '${station}' excluded) ---"
		idx=$((idx + 1))
		continue
		;;
	esac
	# Ensure the endpoint address carries an explicit port for the AIO connector.
	if printf '%s' "${endpoint_url}" | grep -Eq '://[^/:]+:[0-9]+'; then
	  endpoint_address="${endpoint_url%/}"
	else
	  endpoint_address="opc.tcp://${host}:${OPC_UA_PORT}"
	fi
	# Names must be DNS-friendly: <host> like 'assembly.munich' -> 'assembly-munich'.
	safe_name="$(printf '%s' "${host}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')"
	auth_mode="$(jq -r ".[${idx}].OpcAuthenticationMode // \"Anonymous\"" "${persistency}")"

	echo
	echo "--- ${safe_name} (${endpoint_address}, auth=${auth_mode}) ---"

	# Device + OPC UA inbound endpoint pointing at the OPC UA server. The simulation servers
	# accept anonymous sessions (OpcAuthenticationMode=Anonymous in persistency.json).
	run az iot ops ns device create \
	  --resource-group "${RESOURCE_GROUP}" \
	  --instance "${AIO_INSTANCE_NAME}" \
	  --name "${safe_name}"

	# AIO does NOT auto-accept untrusted server certificates. Instead, AIO is made to trust each
	# station's own OPC UA server certificate explicitly by adding it to AIO's connector trust list
	# (via Key Vault secret sync) in section 12c below.
	run az iot ops ns device endpoint inbound add opcua \
	  --resource-group "${RESOURCE_GROUP}" \
	  --instance "${AIO_INSTANCE_NAME}" \
	  --device "${safe_name}" \
	  --name "${safe_name}-ep" \
	  --endpoint-address "${endpoint_address}"

	# Create the asset, then add a dataset (destination = the local MQTT topic that the
	# telemetry data flow subscribes to) and import all OpcNodes as data points in one batch. The
	# current CLI uses 'ns asset opcua create' + 'dataset add' + 'datapoint import --input-file'.
	# The NodeId is passed verbatim as the data point dataSource; sampling interval comes from
	# OpcSamplingInterval in persistency.json.
	node_count="$(jq -r ".[${idx}].OpcNodes | length" "${persistency}")"
	echo ">>> ${safe_name}: ${node_count} data point(s) from persistency.json"

	run az iot ops ns asset opcua create \
	  --resource-group "${RESOURCE_GROUP}" \
	  --instance "${AIO_INSTANCE_NAME}" \
	  --device "${safe_name}" \
	  --endpoint "${safe_name}-ep" \
	  --name "${safe_name}-asset"

	# Dataset whose destination is the MQTT topic consumed by the telemetry data flow.
	run az iot ops ns asset opcua dataset add \
	  --resource-group "${RESOURCE_GROUP}" \
	  --instance "${AIO_INSTANCE_NAME}" \
	  --asset "${safe_name}-asset" \
	  --name "telemetry" \
	  --dest topic="azure-iot-operations/data/${safe_name}" qos=Qos1 retain=Never ttl=3600

	# Add ALL OPC UA nodes in a single batch import instead of one slow ARM call per node
	# (per-node 'datapoint add' made the run exceed the CustomScript extension timeout). The
	# import file is a JSON array of { name, dataSource=NodeId, dataPointConfiguration }.
	datapoints_file="${AIO_CONFIG_DIR}/datapoints-${line}-${safe_name}.json"
	# Name each data point by its real OPC UA browse name (e.g. EnergyConsumption) rather than a
	# generic 'node-<index>', using the NodeId-identifier -> browse name map derived from
	# Station.NodeSet2.xml above. The name becomes the telemetry Payload key and therefore
	# opcua_telemetry.Name in ADX/Fabric/Databricks, which the dashboards and OEE functions filter on
	# (e.g. Name == "EnergyConsumption"). Fall back to node-<index> for any id not in the map.
	jq --argjson idx "${idx}" --argjson names "${NODE_NAME_MAP}" '
	  ( .[$idx].OpcNodes // [] )
	  | to_entries
	  | map({
		  name: ( ($names[ (.value.Id | capture(";i=(?<n>[0-9]+)$").n) ]) // ("node-" + (.key|tostring)) ),
		  dataSource: .value.Id,
		  dataPointConfiguration: ( { samplingInterval: (.value.OpcSamplingInterval // 1000) } | tojson )
		})
	' "${persistency}" > "${datapoints_file}"

	run az iot ops ns asset opcua datapoint import \
	  --resource-group "${RESOURCE_GROUP}" \
	  --instance "${AIO_INSTANCE_NAME}" \
	  --asset "${safe_name}-asset" \
	  --dataset "telemetry" \
	  --input-file "${datapoints_file}" \
	  --replace true

	idx=$((idx + 1))
  done
done

# --------------------------
# 11. Create the data flows: OPC UA (MQTT) -> Event Hubs (Kafka), reshaped to OPC UA PubSub
# --------------------------
# The reference solution's ADX/Fabric/Databricks expansion policies (OPCUATelemetryExpand /
# OPCUAMetaDataExpand) read the dataset identity and timestamp FROM THE MESSAGE BODY and
# expect an OPC UA PubSub DataSet message: { DataSetWriterId, Timestamp, Payload|MetaData }.
# Azure IoT Operations instead carries the identity in CloudEvent attributes (subject, time).
# A BuiltInTransformation map wraps the values under Payload/MetaData and copies the
# CloudEvent subject/time into DataSetWriterId/Timestamp so the existing policies work
# unchanged. See the "Azure IoT Operations configuration for OPC UA PubSub" section of the
# repository README. Two flows are created: telemetry -> 'data' hub, metadata -> 'metadata' hub.
echo
echo "=== Creating the OPC UA PubSub data flows (telemetry + metadata) ==="

# Telemetry flow: wrap fields under Payload, map identity/timestamp, send to the 'data' hub.
TELEMETRY_DATAFLOW_CONFIG="${AIO_CONFIG_DIR}/dataflow-telemetry.json"
cat > "${TELEMETRY_DATAFLOW_CONFIG}" <<EOF
{
  "mode": "Enabled",
  "operations": [
	{
	  "operationType": "Source",
	  "sourceSettings": {
		"endpointRef": "default",
		"dataSources": ["azure-iot-operations/data/#"]
	  }
	},
	{
	  "operationType": "BuiltInTransformation",
	  "builtInTransformationSettings": {
		"map": [
		  {
			"inputs": ["*"],
			"output": "Payload.*",
			"description": "Wrap all dataset value fields under Payload"
		  },
		  {
			"inputs": ["\$metadata.user_property.subject"],
			"output": "DataSetWriterId",
			"description": "CloudEvent subject -> dataset identity"
		  },
		  {
			"inputs": ["\$metadata.user_property.time"],
			"output": "Timestamp",
			"description": "CloudEvent time -> Timestamp"
		  }
		]
	  }
	},
	{
	  "operationType": "Destination",
	  "destinationSettings": {
		"endpointRef": "${DATAFLOW_ENDPOINT_NAME}",
		"dataDestination": "${TELEMETRY_EVENTHUB_NAME}"
	  }
	}
  ]
}
EOF
run az iot ops dataflow apply \
  --resource-group "${RESOURCE_GROUP}" \
  --instance "${AIO_INSTANCE_NAME}" \
  --profile default \
  --name "${TELEMETRY_DATAFLOW_NAME}" \
  --config-file "${TELEMETRY_DATAFLOW_CONFIG}"

# Metadata flow: wrap fields under MetaData, map identity/timestamp, send to the 'metadata' hub.
METADATA_DATAFLOW_CONFIG="${AIO_CONFIG_DIR}/dataflow-metadata.json"
cat > "${METADATA_DATAFLOW_CONFIG}" <<EOF
{
  "mode": "Enabled",
  "operations": [
	{
	  "operationType": "Source",
	  "sourceSettings": {
		"endpointRef": "default",
		"dataSources": ["azure-iot-operations/metadata/#"]
	  }
	},
	{
	  "operationType": "BuiltInTransformation",
	  "builtInTransformationSettings": {
		"map": [
		  {
			"inputs": ["*"],
			"output": "MetaData.*",
			"description": "Wrap all metadata fields under MetaData"
		  },
		  {
			"inputs": ["\$metadata.user_property.subject"],
			"output": "DataSetWriterId",
			"description": "CloudEvent subject -> dataset identity"
		  },
		  {
			"inputs": ["\$metadata.user_property.time"],
			"output": "Timestamp",
			"description": "CloudEvent time -> Timestamp"
		  }
		]
	  }
	},
	{
	  "operationType": "Destination",
	  "destinationSettings": {
		"endpointRef": "${DATAFLOW_ENDPOINT_NAME}",
		"dataDestination": "${METADATA_EVENTHUB_NAME}"
	  }
	}
  ]
}
EOF
run az iot ops dataflow apply \
  --resource-group "${RESOURCE_GROUP}" \
  --instance "${AIO_INSTANCE_NAME}" \
  --profile default \
  --name "${METADATA_DATAFLOW_NAME}" \
  --config-file "${METADATA_DATAFLOW_CONFIG}"

# --------------------------
# 12. Establish OPC UA application-authentication mutual trust with the stations
# --------------------------
# AIO's connector for OPC UA presents a cert-manager-managed, self-signed application instance
# certificate (secret aio-opc-opcuabroker-default-application-cert) when it connects to a station.
# The stations accept anonymous/untrusted OPC UA sessions ONLY while their pki/issuer/certs store is
# empty ("provisioning mode"); once populated, each station accepts a peer certificate only if it is
# in pki/trusted/certs or is signed by an issuer in pki/issuer/certs (see Station/Program.cs
# CertificateValidationCallback). Two-way trust is established here:
#  - Stations trust AIO (12a/12b): copy AIO's certificate into each station's host-mounted
#    pki/trusted/certs (/mnt/c/K3s/<Station>/<Line>/PKI). The validator re-reads that directory on
#    each validation, so no station restart is required.
#  - AIO trusts the stations (12c): add each station's own OPC UA server certificate to AIO's
#    connector trust list via Key Vault secret sync, so AIO validates (does not auto-accept) the
#    server certificate each station presents.
#  - Stations trust the UA Cloud Commander and the MES (12d): both are OPC UA clients that connect to
#    the stations (the commander to issue commands, the MES to drive the assembly line). With GDS
#    Server Push disabled their certificates are no longer distributed automatically, so copy each
#    client's own OPC UA client certificate (exposed on the host at
#    /mnt/c/K3s/<Component>/<Line>/PKI/own/certs) into each station's trusted/certs.
echo
echo "=== Establishing OPC UA mutual trust between AIO and the stations ==="

AIO_CERT_CRT="${AIO_CONFIG_DIR}/opcuabroker.crt"
AIO_CERT_DER="${AIO_CONFIG_DIR}/opcuabroker.der"

# 12a. Retrieve AIO's connector application instance certificate (public key) from the secret.
if kubectl -n "${AIO_NAMESPACE}" get secret "${AIO_OPCUA_CERT_SECRET}" >/dev/null 2>&1; then
  kubectl -n "${AIO_NAMESPACE}" get secret "${AIO_OPCUA_CERT_SECRET}" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > "${AIO_CERT_CRT}" 2>/dev/null

  if [ -s "${AIO_CERT_CRT}" ]; then
    # The stations (OPC UA .NET stack) expect DER-encoded certs in the PKI folders.
    if command -v openssl >/dev/null 2>&1; then
      run openssl x509 -outform der -in "${AIO_CERT_CRT}" -out "${AIO_CERT_DER}"
    fi
    aio_cert_to_copy="${AIO_CERT_DER}"
    [ -s "${AIO_CERT_DER}" ] || aio_cert_to_copy="${AIO_CERT_CRT}"

    # 12b. Copy AIO's certificate into each telemetry station's host-mounted trusted store so the
    # stations trust AIO's client certificate. Each station's /app/pki is host-mounted at
    # /mnt/c/K3s/<Station>/<Line>/PKI (see Deployment/<Line>/ProductionLine.yaml), so writing on the
    # host persists across pod restarts and the OPC UA .NET validator re-reads trusted/certs on each
    # validation (no station restart required). Only Assembly/Test/Packaging are onboarded to AIO.
    cert_basename="aio-opcuabroker.${aio_cert_to_copy##*.}"
    for line in "${LINES[@]}"; do
      for station in Assembly Test Packaging; do
        dest_dir="/mnt/c/K3s/${station}/${line}/PKI/trusted/certs"
        run mkdir -p "${dest_dir}"
        run cp "${aio_cert_to_copy}" "${dest_dir}/${cert_basename}"
        echo ">>> ${station}/${line}: AIO certificate installed into ${dest_dir}"
      done
    done
  else
    echo "!!! WARNING: AIO connector certificate was empty; stations will not trust AIO."
  fi
else
  echo "!!! WARNING: secret ${AIO_OPCUA_CERT_SECRET} not found in ${AIO_NAMESPACE};"
  echo "    cannot distribute AIO's certificate to the stations. AIO connections may be refused."
fi

# 12c. Make AIO trust the stations. Each simulation station presents its own self-signed OPC UA
# application instance (server) certificate. Its /app/pki is host-mounted at
# /mnt/c/K3s/<Station>/<Line>/PKI, so the public certs live under .../PKI/own/certs. Add each
# station's certificate to AIO's connector trust list so AIO validates (does not auto-accept) the
# server certificate the station presents.
#
# 'az iot ops connector opcua trust add' stores the trust list as a synced secret, so AIO secret
# sync must be enabled first. We reuse the solution's existing Key Vault (<resourcesName>-KV) and
# the shared user-assigned managed identity. The identity is pre-granted 'Key Vault Secrets User'
# and 'Key Vault Reader' by the ARM template, so we pass --skip-ra (the identity cannot create the
# Key Vault role assignments itself - that needs Microsoft.Authorization/roleAssignments/write).
echo
echo "=== Enabling AIO secret sync (reusing ${RESOURCES_NAME}-KV) ==="
KEY_VAULT_NAME="${RESOURCES_NAME}-KV"
KEY_VAULT_ID="$(az keyvault show --name "${KEY_VAULT_NAME}" --resource-group "${RESOURCE_GROUP}" --query id -o tsv 2>/dev/null)"
# Whether secret sync is enabled gates the OPC UA trust-list step below. Key off the
# result of 'secretsync enable' (RUN_LAST_RC) rather than probing 'connector opcua trust
# show': on a freshly enabled instance no trust list secret exists yet, so 'trust show'
# returns non-zero and would wrongly report secret sync as disabled, skipping the trust add.
secret_sync_enabled=false
if [ -n "${KEY_VAULT_ID}" ] && [ -n "${MANAGED_IDENTITY_RESOURCE_ID}" ]; then
  run az iot ops secretsync enable \
    --instance "${AIO_INSTANCE_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --mi-user-assigned "${MANAGED_IDENTITY_RESOURCE_ID}" \
    --kv-resource-id "${KEY_VAULT_ID}" \
    --skip-ra
  if [ "${RUN_LAST_RC}" -eq 0 ]; then
    secret_sync_enabled=true
  fi
else
  echo "!!! WARNING: could not resolve ${KEY_VAULT_NAME} or the managed identity; secret sync not enabled."
  echo "    The OPC UA trust list (below) requires secret sync and will be skipped."
fi

echo
echo "=== Adding the stations' OPC UA certificates to AIO's trust list ==="
if [ "${secret_sync_enabled}" != "true" ]; then
  echo "!!! NOTE: AIO secret sync is not enabled, so the OPC UA trust list cannot be updated."
  echo "    After enabling it, add each station cert (from /mnt/c/K3s/<Station>/<Line>/PKI/own/certs) with:"
  echo "      az iot ops connector opcua trust add --instance ${AIO_INSTANCE_NAME} \\"
  echo "        --resource-group ${RESOURCE_GROUP} --certificate-file <station>.der"
else
  station_cert_found=false
  for line in "${LINES[@]}"; do
    for station in Assembly Test Packaging; do
      # The station's public certs live under its host-mounted PKI own store. pki/own/certs holds
      # the RSA application instance cert plus alternate ECC curve variants; AIO connects with
      # Basic256Sha256 (RSA), so add only the RSA cert and skip the curve-tagged variants.
      cert_dir="/mnt/c/K3s/${station}/${line}/PKI/own/certs"
      [ -d "${cert_dir}" ] || continue
      for cert_file in "${cert_dir}"/*.der; do
        [ -f "${cert_file}" ] || continue
        case "${cert_file}" in
          *NistP256*|*NistP384*|*BrainpoolP256r1*|*BrainpoolP384r1*) continue ;;
        esac
        station_cert_found=true
        echo ">>> Trusting ${station}/${line}: ${cert_file}"
        # 'az iot ops connector opcua trust add' derives two names from the certificate file: the
        # Key Vault secret name (must match ^[0-9A-Za-z-]+$) and the secretSync targetKey (must match
        # ^[A-Za-z0-9.]([-A-Za-z0-9]+([-._a-zA-Z0-9]?[A-Za-z0-9])*)?...$). The station cert file names
        # contain dots, spaces and '[thumbprint]', which fail both. Copy the cert to a sanitized
        # <stem>.der file (valid targetKey) and pass a hyphen-only --secret-name from the same stem.
        cert_stem="$(basename "${cert_file}" | sed 's/\.[^.]*$//; s/[^0-9A-Za-z]/-/g; s/--*/-/g; s/^-//; s/-$//')"
        safe_cert_file="${AIO_CONFIG_DIR}/${cert_stem}.der"
        cp "${cert_file}" "${safe_cert_file}"
        run az iot ops connector opcua trust add \
          --instance "${AIO_INSTANCE_NAME}" \
          --resource-group "${RESOURCE_GROUP}" \
          --certificate-file "${safe_cert_file}" \
          --secret-name "${cert_stem}"
      done
    done
  done
  if [ "${station_cert_found}" != "true" ]; then
    echo "!!! NOTE: no station OPC UA certificate was found on disk yet. If AIO fails to connect to"
    echo "    a station, export that station's server certificate and run:"
    echo "      az iot ops connector opcua trust add --instance ${AIO_INSTANCE_NAME} \\"
    echo "        --resource-group ${RESOURCE_GROUP} --certificate-file <station>.der"
  fi
fi

# 12d. Make the stations trust the OPC UA clients that connect to them. Two simulation components act
# as OPC UA clients against the stations: the UA Cloud Commander (issues commands) and the MES
# (drives the assembly line and reads station status). With GDS Server Push disabled, their
# certificates are no longer distributed automatically, so each station rejects these clients once it
# leaves provisioning mode unless the client certificate is present in trusted/certs. Each client's
# /app/pki is host-mounted at /mnt/c/K3s/<Component>/<Line>/PKI (see Deployment/<Line>/
# ProductionLine.yaml), so its public cert lives under .../PKI/own/certs. pki/own/certs holds the RSA
# application instance cert plus alternate ECC curve variants; the stations negotiate Basic256Sha256
# (RSA), so copy only the RSA cert and skip the curve-tagged variants. Both client certs are
# distributed in the same pass so no station is left in provisioning mode with an incomplete trust
# list. The OPC UA .NET validator re-reads trusted/certs on each validation, so no station restart is
# required.
echo
echo "=== Establishing trust for the OPC UA clients (Commander, MES) at the stations ==="
# Each entry maps a host PKI component directory to the filename prefix used in trusted/certs.
CLIENT_COMPONENTS="Commander:commander MES:mes"
for client in ${CLIENT_COMPONENTS}; do
  component="${client%%:*}"
  prefix="${client##*:}"
  client_cert_found=false
  for line in "${LINES[@]}"; do
    client_cert_dir="/mnt/c/K3s/${component}/${line}/PKI/own/certs"
    [ -d "${client_cert_dir}" ] || continue
    for cert_file in "${client_cert_dir}"/*.der; do
      [ -f "${cert_file}" ] || continue
      case "${cert_file}" in
        *NistP256*|*NistP384*|*BrainpoolP256r1*|*BrainpoolP384r1*) continue ;;
      esac
      client_cert_found=true
      cert_basename="${prefix}.$(basename "${cert_file}")"
      for station in Assembly Test Packaging; do
        dest_dir="/mnt/c/K3s/${station}/${line}/PKI/trusted/certs"
        run mkdir -p "${dest_dir}"
        run cp "${cert_file}" "${dest_dir}/${cert_basename}"
        echo ">>> ${station}/${line}: ${component} certificate installed into ${dest_dir}"
      done
    done
  done
  if [ "${client_cert_found}" != "true" ]; then
    echo "!!! NOTE: no ${component} OPC UA certificate was found under"
    echo "    /mnt/c/K3s/${component}/<Line>/PKI/own/certs yet. If the stations reject ${component},"
    echo "    copy its own cert into each station's PKI/trusted/certs and retry."
  fi
done

# 12e. Register an OPC UA command (management-group action) so the AIO OPC UA connector's built-in
# commander can execute a command on the station directly - the AIO-native alternative to UA Cloud
# Commander. The reference command is "open the pressure relief valve" on the Seattle assembly
# station (the same command UA-CloudAction triggers). It is modeled as a management-group action of
# type "Call" on the station's telemetry asset: dataSource maps to the OPC UA objectId and targetUri
# to the methodId (see Station.NodeSet2.xml). UA-CloudAction (MESSAGING_PLATFORM=AIO-Commander) then
# invokes it by publishing to azure-iot-operations/asset-operations/<asset>/<managementGroup>/<action>.
#
# This is additive: UA Cloud Commander stays deployed as a backup. The exact CLI verb for actions can
# vary by az iot ops extension version, so this step is best-effort and only warns on failure.
echo
echo "=== Registering the AIO OPC UA commander action (Seattle assembly pressure relief valve) ==="
COMMAND_ASSET="assembly-seattle-asset"
COMMAND_MGMT_GROUP="managementGroup"
COMMAND_ACTION_NAME="OpenPressureReliefValve"
COMMAND_OBJECT_ID="ns=2;i=424"
COMMAND_METHOD_ID="ns=2;i=435"
if az iot ops ns asset opcua management-group --help >/dev/null 2>&1; then
  # Create the management group (carries the OPC UA objectId via --data-source) if the verb exists.
  run az iot ops ns asset opcua management-group add \
    --resource-group "${RESOURCE_GROUP}" \
    --instance "${AIO_INSTANCE_NAME}" \
    --asset "${COMMAND_ASSET}" \
    --name "${COMMAND_MGMT_GROUP}" \
    --data-source "${COMMAND_OBJECT_ID}" || \
    echo "!!! NOTE: could not create management group '${COMMAND_MGMT_GROUP}' on '${COMMAND_ASSET}'; it may already exist or the CLI verb differs in this az iot ops version."
  # Add the Call action (targetUri = methodId) to the management group.
  run az iot ops ns asset opcua management-group action add \
    --resource-group "${RESOURCE_GROUP}" \
    --instance "${AIO_INSTANCE_NAME}" \
    --asset "${COMMAND_ASSET}" \
    --management-group "${COMMAND_MGMT_GROUP}" \
    --name "${COMMAND_ACTION_NAME}" \
    --action-type "Call" \
    --target-uri "${COMMAND_METHOD_ID}" || \
    echo "!!! NOTE: could not add action '${COMMAND_ACTION_NAME}'; verify the management-group action verb for your az iot ops version."
  echo ">>> If successful, UA-CloudAction (MESSAGING_PLATFORM=AIO-Commander) can call:"
  echo "    azure-iot-operations/asset-operations/${COMMAND_ASSET}/${COMMAND_MGMT_GROUP}/${COMMAND_ACTION_NAME}"
else
  echo "!!! NOTE: this az iot ops version does not expose 'ns asset opcua management-group'; skipping the"
  echo "    AIO commander action registration. Add the management group + Call action (objectId"
  echo "    ${COMMAND_OBJECT_ID}, methodId ${COMMAND_METHOD_ID}) on asset '${COMMAND_ASSET}' via the"
  echo "    operations experience portal, or keep using UA Cloud Commander."
fi

# Clean up the generated config files (they contain no secrets).
rm -rf "${AIO_CONFIG_DIR}"

echo
echo "=== Azure IoT Operations setup finished: $(date -Is) ==="
echo "AIO now reads the simulation OPC UA servers and forwards OPC UA PubSub DataSet messages"
echo "to the '${TELEMETRY_EVENTHUB_NAME}' and '${METADATA_EVENTHUB_NAME}' event hubs,"
echo "so the existing ADX/Fabric/Databricks expansion policies apply."
