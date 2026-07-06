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
AIO_INSTANCE_NAME="${RESOURCES_NAME}-AIO"
# Schema registry name must be lowercase (^[a-z0-9][a-z0-9-]*[a-z0-9]$), matching arm.json's
# toLower(concat(resourcesName, '-schemaregistry')).
SCHEMA_REGISTRY_NAME="$(printf '%s-schemaregistry' "${RESOURCES_NAME}" | tr '[:upper:]' '[:lower:]')"
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
# Kubernetes namespaces the simulation stations run in (lower-cased line names).
STATION_NAMESPACES=("munich" "seattle")
# AIO's connector for OPC UA stores its application instance certificate (managed by
# cert-manager) in this Kubernetes secret after 'az iot ops create'.
AIO_OPCUA_CERT_SECRET="aio-opc-opcuabroker-default-application-cert"
AIO_NAMESPACE="azure-iot-operations"
# Inside each station pod (image manufacturingontologies:main) the OPC UA .NET stack keeps its
# PKI under the working directory /app. The station's certificate validator (Station/Program.cs)
# accepts a client cert once provisioned only if its issuer matches a cert in pki/issuer/certs.
STATION_PKI_ISSUER_DIR="/app/pki/issuer/certs"
STATION_PKI_TRUSTED_DIR="/app/pki/trusted/certs"

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

# Helper: log a command, run it, warn (but continue) on failure.
run() {
  echo
  echo ">>> $*"
  "$@"
  local rc=$?
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
if ! az login --identity --username "${MANAGED_IDENTITY_CLIENT_ID}" --allow-no-subscriptions >/dev/null; then
  echo "!!! ERROR: az login --identity failed. Aborting AIO setup."
  exit 1
fi
run az account set --subscription "${SUBSCRIPTION_ID}"

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
# 3. Register the resource providers AIO/Arc need
# --------------------------
echo
echo "=== Registering resource providers ==="
for rp in Microsoft.ExtendedLocation Microsoft.Kubernetes Microsoft.KubernetesConfiguration \
		  Microsoft.IoTOperations Microsoft.DeviceRegistry Microsoft.SecretSyncController; do
  run az provider register -n "${rp}"
done

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

echo
echo "=== Creating the Azure IoT Operations instance ==="
run az iot ops create \
  --resource-group "${RESOURCE_GROUP}" \
  --cluster "${CLUSTER_NAME}" \
  --name "${AIO_INSTANCE_NAME}" \
  --sr-resource-id "${SCHEMA_REGISTRY_ID}"

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

	run az iot ops ns device endpoint inbound add opcua \
	  --resource-group "${RESOURCE_GROUP}" \
	  --instance "${AIO_INSTANCE_NAME}" \
	  --device "${safe_name}" \
	  --name "${safe_name}-ep" \
	  --endpoint-address "${endpoint_address}"

	# Build the asset config with one data point per OpcNodes entry. The NodeId is kept verbatim
	# as the data point dataSource; a sanitized, unique name is generated for each point.
	asset_config="${AIO_CONFIG_DIR}/asset-${line}-${safe_name}.json"
	jq --arg ep "${safe_name}-ep" --argjson idx "${idx}" '
	  {
		enabled: true,
		endpointRef: $ep,
		datasets: [
		  {
			name: "telemetry",
			dataPoints: [
			  ( .[$idx].OpcNodes // [] )
			  | to_entries[]
			  | {
				  name: ("node-" + (.key|tostring)),
				  dataSource: .value.Id,
				  dataPointConfiguration: ( { samplingInterval: (.value.OpcSamplingInterval // 1000) } | tojson )
				}
			]
		  }
		]
	  }
	' "${persistency}" > "${asset_config}"

	node_count="$(jq -r ".[${idx}].OpcNodes | length" "${persistency}")"
	echo ">>> ${safe_name}: ${node_count} data point(s) from persistency.json"

	run az iot ops ns asset opcua create \
	  --resource-group "${RESOURCE_GROUP}" \
	  --instance "${AIO_INSTANCE_NAME}" \
	  --device "${safe_name}" \
	  --endpoint "${safe_name}-ep" \
	  --name "${safe_name}-asset" \
	  --config-file "${asset_config}"

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
			"inputs": ["\$metadata.user_properties.subject"],
			"output": "DataSetWriterId",
			"description": "CloudEvent subject -> dataset identity"
		  },
		  {
			"inputs": ["\$metadata.user_properties.time"],
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
			"inputs": ["\$metadata.user_properties.subject"],
			"output": "DataSetWriterId",
			"description": "CloudEvent subject -> dataset identity"
		  },
		  {
			"inputs": ["\$metadata.user_properties.time"],
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
# The simulation stations accept anonymous/untrusted OPC UA sessions ONLY while their
# pki/issuer/certs store is empty ("provisioning mode"). Once UA Cloud Publisher, acting as the
# GDS, pushes a CA certificate to the stations via OPC UA Part 12 Server Push, each station
# accepts a client certificate only if that certificate's Issuer matches the Subject of a cert
# in its pki/issuer/certs store (see Station/Program.cs CertificateValidationCallback).
#
# AIO's connector for OPC UA presents a cert-manager-managed, self-signed application instance
# certificate (secret aio-opc-opcuabroker-default-application-cert). To make the stations trust
# it after provisioning, we copy AIO's certificate into each station's pki/issuer/certs (so the
# station treats AIO as a trusted issuer; AIO's cert is self-signed, so Issuer==Subject==itself
# and the match succeeds) and into pki/trusted/certs (peer trust). The validator re-reads these
# directories on each validation, so no station restart is required.
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

    # 12b. Copy AIO's certificate into every station pod's issuer + trusted stores.
    for ns in "${STATION_NAMESPACES[@]}"; do
      echo
      echo "--- Distributing AIO certificate to stations in namespace '${ns}' ---"
      station_pods="$(kubectl -n "${ns}" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
      if [ -z "${station_pods}" ]; then
        echo "!!! WARNING: no pods found in namespace '${ns}'; skipping."
        continue
      fi
      for pod in ${station_pods}; do
        cert_basename="aio-opcuabroker.$(basename "${aio_cert_to_copy##*.}")"
        # Ensure the PKI directories exist inside the pod, then copy the cert into both.
        run kubectl -n "${ns}" exec "${pod}" -- sh -c "mkdir -p '${STATION_PKI_ISSUER_DIR}' '${STATION_PKI_TRUSTED_DIR}'"
        run kubectl -n "${ns}" cp "${aio_cert_to_copy}" "${pod}:${STATION_PKI_ISSUER_DIR}/${cert_basename}"
        run kubectl -n "${ns}" cp "${aio_cert_to_copy}" "${pod}:${STATION_PKI_TRUSTED_DIR}/${cert_basename}"
        echo ">>> ${ns}/${pod}: AIO certificate installed into issuer + trusted stores"
      done
    done
  else
    echo "!!! WARNING: AIO connector certificate was empty; stations will not trust AIO."
  fi
else
  echo "!!! WARNING: secret ${AIO_OPCUA_CERT_SECRET} not found in ${AIO_NAMESPACE};"
  echo "    cannot distribute AIO's certificate to the stations. AIO connections may be refused"
  echo "    after UA Cloud Publisher provisions the stations via GDS Server Push."
fi

# 12c. Make AIO trust the stations. UA Cloud Publisher's PKI (its GDS CA, which signs the certs
# the stations present) is host-mounted at /mnt/c/K3s/PublisherConfig/<line>/PKI. Add any CA
# certificates found there to AIO's connector trust list so AIO trusts the stations.
echo
echo "=== Adding UA Cloud Publisher's CA to AIO's OPC UA trust list ==="
publisher_ca_found=false
for line in "${LINES[@]}"; do
  # The OPC UA .NET stack keeps issuer/CA certificates under <PKI>/issuer/certs.
  for ca_dir in \
    "/mnt/c/K3s/PublisherConfig/${line}/PKI/issuer/certs" \
    "/mnt/c/K3s/PublisherConfig/${line}/PKI/trusted/certs"; do
    [ -d "${ca_dir}" ] || continue
    for ca_file in "${ca_dir}"/*.der "${ca_dir}"/*.crt; do
      [ -f "${ca_file}" ] || continue
      publisher_ca_found=true
      echo ">>> Trusting ${ca_file}"
      run az iot ops connector opcua trust add \
        --instance "${AIO_INSTANCE_NAME}" \
        --resource-group "${RESOURCE_GROUP}" \
        --certificate-file "${ca_file}"
    done
  done
done
if [ "${publisher_ca_found}" != "true" ]; then
  echo "!!! NOTE: no UA Cloud Publisher CA certificate was found on disk yet. If AIO fails to"
  echo "    connect to a station after provisioning, export the station/GDS CA certificate and run:"
  echo "      az iot ops connector opcua trust add --instance ${AIO_INSTANCE_NAME} \\"
  echo "        --resource-group ${RESOURCE_GROUP} --certificate-file <ca>.der"
fi

# Clean up the generated config files (they contain no secrets).
rm -rf "${AIO_CONFIG_DIR}"

echo
echo "=== Azure IoT Operations setup finished: $(date -Is) ==="
echo "AIO now reads the simulation OPC UA servers and forwards OPC UA PubSub DataSet messages"
echo "to the '${TELEMETRY_EVENTHUB_NAME}' and '${METADATA_EVENTHUB_NAME}' event hubs,"
echo "so the existing ADX/Fabric/Databricks expansion policies apply."
