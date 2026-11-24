#!/usr/bin/env bash
# ConnectUAEdgeTranslatorPi.sh - Deploy UA Edge Translator to the Pi's K3s cluster and connect it to Azure IoT
# Operations through AIO's OPC UA Web of Things (WoT) connectivity, as an additional site of the reference
# solution (https://learn.microsoft.com/azure/iot-operations/discover-manage-assets/howto-configure-opc-ua-web-of-things-connectivity).
#
# Run it on a Raspberry Pi that was set up with SetupAzureIoTOperationsPi.sh. It:
#   - deploys UA Edge Translator from its upstream manifest (UA-EdgeTranslator.yaml) with
#     IGNORE_PROVISIONING_MODE=true - otherwise every tag read returns BadNotReadable until a GDS pushes an
#     issuer certificate - and sets its OPC UA user (k8s secret 'ua-edgetranslator-credentials') to the
#     adminUsername/adminPassword entered when deploying arm.json, instead of the manifest's placeholder secret,
#   - stores the credentials in the deployment's Key Vault and syncs them into AIO with
#     'az iot ops secretsync secret set' (EdgeTranslator only accepts UserName tokens),
#   - establishes mutual OPC UA trust: EdgeTranslator's RSA application certificate goes into AIO's
#     connector trust list and AIO's connector certificate goes into EdgeTranslator's PKI/trusted/certs,
#   - creates the AIO device '<station>-<site>' with the two inbound endpoints of the WoT connectivity:
#     a Microsoft.OpcUa telemetry endpoint '<station>-<site>-ep' and a Microsoft.OpcUa.WoT endpoint
#     '<station>-<site>-wot' (asset discovery enabled, bound to the telemetry endpoint), both
#     SignAndEncrypt/Basic256Sha256 with the synced username/password,
#   - installs 'aio-wot', a helper that calls the WoT endpoint's on-demand mRPC methods (createAsset,
#     listAssets, ...) through the in-cluster mqtt-client pod,
#   - enables OPC UA PubSub metadata (opcUaConformance, required since AIO 2610) on every asset of the device
#     already imported; for assets imported later, run the fast OnboardUAEdgeTranslatorAsset.sh instead.
# Onboarding is manual: send each Thing Description with 'sudo aio-wot createAsset <td.jsonld>'. The OPC UA
# Commander uploads it through EdgeTranslator's OPC 10100-1 WoT Connectivity API and runs discovery on the
# variables EdgeTranslator materializes; the results show up as (Akri) discovered assets, which you import
# in the operations experience under a name starting with '<station>-<site>-' (the discovered name does).
# The existing data flows forward it to Event Hubs,
# so it shows up in ADX/Fabric/Databricks as Site=<site>, Workcell=<station>.
#
# Usage (on the Pi, as root):
#   curl -fsSL https://raw.githubusercontent.com/digitaltwinconsortium/ManufacturingOntologies/main/Deployment/ConnectUAEdgeTranslatorPi.sh | sudo bash -s -- <resource-group> [subscription-id]
# Sign-in (no device code flow - most tenants block it): reuses root's Azure CLI session from
# SetupAzureIoTOperationsPi.sh if it is still valid; otherwise pass a service principal created with
# CreateRaspberryPiServicePrincipal.sh in Azure Cloud Shell, which prints the complete command for this script:
#   curl -fsSL https://raw.githubusercontent.com/digitaltwinconsortium/ManufacturingOntologies/main/Deployment/CreateRaspberryPiServicePrincipal.sh | PI_SCRIPT=ConnectUAEdgeTranslatorPi.sh bash -s -- <resource-group> [subscription-id]
# ('... | sudo AZURE_CLIENT_ID=... AZURE_TENANT_ID=... AZURE_CLIENT_SECRET='...' bash -s -- <rg> [sub]').
#
# Optional environment overrides:
#   SITE                  Site (production line/location) name (default: nuremberg)
#   STATION               Station/workcell name (default: translator)
#   ET_MANIFEST_URL       UA Edge Translator manifest (default: UA-EdgeTranslator.yaml on the upstream main branch)
#   ET_USERNAME, ET_PASSWORD  OPC UA user of EdgeTranslator (default: adminUsername/adminPassword of the
#                         arm.json deployment; the password is read from its Key Vault secret 'adminpassword')
#   ET_ENDPOINT           OPC UA endpoint URL (default: opc.tcp://<service>.<namespace>.svc.cluster.local:4840/UA/UAEdgeTranslator)
#   ET_SECURITY_POLICY    Basic256Sha256 (default), Aes128_Sha256_RsaOaep or Aes256_Sha256_RsaPss
#   PI_PUBLIC_IP          Public egress IPv4 to allow through the Key Vault firewall (auto-detected)
#   K8_BRIDGE_OID         Object ID of the 'K8 Bridge' Entra application, needed to enable resource sync so that
#                         discovered assets appear in the operations experience (passed by
#                         CreateRaspberryPiServicePrincipal.sh; otherwise looked up in Microsoft Graph)

SCRIPT_URL="https://raw.githubusercontent.com/digitaltwinconsortium/ManufacturingOntologies/main/Deployment/ConnectUAEdgeTranslatorPi.sh"

main() {

set -u
set -o pipefail

RESOURCE_GROUP="${1:-}"
SUBSCRIPTION_ID="${2:-}"
RESOURCES_NAME="${RESOURCE_GROUP}"

SITE="$(printf '%s' "${SITE:-nuremberg}" | tr '[:upper:]' '[:lower:]')"
STATION="$(printf '%s' "${STATION:-translator}" | tr '[:upper:]' '[:lower:]')"
ET_MANIFEST_URL="${ET_MANIFEST_URL:-https://raw.githubusercontent.com/OPCFoundation/UA-EdgeTranslator/refs/heads/main/UA-EdgeTranslator.yaml}"
ET_USERNAME="${ET_USERNAME:-}"
ET_PASSWORD="${ET_PASSWORD:-}"
ET_SECURITY_POLICY="${ET_SECURITY_POLICY:-Basic256Sha256}"
MQTT_CLIENT_POD="mqtt-client"
MQTT_CLIENT_MANIFEST="https://raw.githubusercontent.com/Azure-Samples/explore-iot-operations/main/samples/quickstarts/mqtt-client.yaml"
WOT_HELPER="/usr/local/bin/aio-wot"

# Same naming as SetupAzureIoTOperationsPi.sh: the cloud parsers derive Workcell/Site from the first two
# '-' separated parts of the asset name ('<station>-<site>-...').
DEVICE_NAME="${STATION}-${SITE}"
ENDPOINT_NAME="${DEVICE_NAME}-ep"
WOT_ENDPOINT_NAME="${DEVICE_NAME}-wot"
ASSET_NAME="${DEVICE_NAME}-asset"

AIO_INSTANCE_NAME="$(printf '%s-aio' "${RESOURCES_NAME}" | tr '[:upper:]' '[:lower:]')"
AIO_NAMESPACE_NAME="$(printf '%s-aions' "${RESOURCES_NAME}" | tr '[:upper:]' '[:lower:]')"
KEY_VAULT_NAME="$(echo "${RESOURCES_NAME}" | tr -d '-' | tr '[:upper:]' '[:lower:]')kv"
KEY_VAULT_NAME="${KEY_VAULT_NAME:0:24}"
AIO_NAMESPACE="azure-iot-operations"
AIO_OPCUA_CERT_SECRET="aio-opc-opcuabroker-default-application-cert"
AIO_TRUST_LIST_SECRET="aio-opc-ua-broker-trust-list"
WOT_TOPIC_PREFIX="${AIO_NAMESPACE}/endpoint-operations/${DEVICE_NAME}/${WOT_ENDPOINT_NAME}"
# Key Vault secrets and the synced k8s secret (in azure-iot-operations) the endpoints reference.
KV_USERNAME_SECRET="${DEVICE_NAME}-opcua-username"
KV_PASSWORD_SECRET="${DEVICE_NAME}-opcua-password"
CREDENTIALS_SYNC_NAME="${DEVICE_NAME}-credentials"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
WORK_DIR="$(mktemp -d)"
chmod 700 "${WORK_DIR}"
trap 'rm -rf "${WORK_DIR}"' EXIT

if [ "$(id -u)" -ne 0 ]; then
  echo "!!! ERROR: run this script as root (sudo)."
  exit 1
fi
if [ -z "${RESOURCE_GROUP}" ]; then
  echo "Usage: curl -fsSL ${SCRIPT_URL} | sudo bash -s -- <resource-group> [subscription-id]"
  exit 1
fi
for _n in "${SITE}" "${STATION}"; do
  if ! [[ "${_n}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
	echo "!!! ERROR: '${_n}' is not a valid SITE/STATION name (lowercase letters, digits and '-')."
	exit 1
  fi
done
case "${ET_SECURITY_POLICY}" in
  Basic256Sha256|Aes128_Sha256_RsaOaep|Aes256_Sha256_RsaPss) ;;
  *) echo "!!! ERROR: unsupported ET_SECURITY_POLICY '${ET_SECURITY_POLICY}'."; exit 1 ;;
esac

mkdir -p /var/log/bootstrap
LOG_FILE="/var/log/bootstrap/ConnectUAEdgeTranslatorPi.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=== Connecting UA Edge Translator to Azure IoT Operations: $(date -Is) ==="
echo "Site: ${SITE}  Station: ${STATION}  Device: ${DEVICE_NAME}"
echo "Endpoints: ${ENDPOINT_NAME} (telemetry), ${WOT_ENDPOINT_NAME} (WoT connectivity)"
echo "Log file: ${LOG_FILE}"

RUN_LAST_RC=0
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

# Edge-to-cloud resource sync ('az iot ops enable-rsync'): grants the first-party K8 Bridge application the
# 'Azure Kubernetes Service Arc Contributor Role' on the instance's custom location, so that resources created
# on the edge - e.g. Akri discovered devices/assets - are projected into Azure Device Registry. Looking up
# K8 Bridge's object ID needs Microsoft Graph, which a resource-group scoped service principal cannot read,
# so CreateRaspberryPiServicePrincipal.sh passes it as K8_BRIDGE_OID.
enable_resource_sync() {
  local k8_bridge_app_id="319f651f-7ddb-4fc6-9857-7aef9250bd05"
  local cl_id k8_oid
  local -a rsync_cmd
  echo
  echo "=== Enabling resource sync (edge -> Azure Device Registry) for ${AIO_INSTANCE_NAME} ==="
  cl_id="$(az iot ops show --name "${AIO_INSTANCE_NAME}" --resource-group "${RESOURCE_GROUP}" \
	--query extendedLocation.name -o tsv 2>/dev/null)"
  if [ -z "${cl_id}" ]; then
	echo "!!! WARNING: could not read the custom location of ${AIO_INSTANCE_NAME}; resource sync not enabled."
	return 0
  fi
  k8_oid="${K8_BRIDGE_OID:-}"
  if [ -z "${k8_oid}" ]; then
	k8_oid="$(az ad sp show --id "${k8_bridge_app_id}" --query id -o tsv 2>/dev/null)"
  fi
  if [ -n "${k8_oid}" ]; then
	if az iot ops enable-rsync --help >/dev/null 2>&1; then
	  rsync_cmd=(enable-rsync)
	else
	  rsync_cmd=(rsync enable)
	fi
	run az iot ops "${rsync_cmd[@]}" --name "${AIO_INSTANCE_NAME}" --resource-group "${RESOURCE_GROUP}" \
	  --k8-bridge-sp-oid "${k8_oid}"
	[ "${RUN_LAST_RC}" -eq 0 ] && return 0
  else
	echo "!!! WARNING: could not look up the K8 Bridge service principal (needs Microsoft Graph access)."
  fi
  echo "    Discovered assets will not show up in the operations experience until you run this once in Azure"
  echo "    Cloud Shell (https://shell.azure.com) as an Owner of the resource group:"
  echo "      az role assignment create --assignee ${k8_bridge_app_id} --role \"Azure Kubernetes Service Arc Contributor Role\" --scope ${cl_id}"
  return 0
}

for _cmd in az jq kubectl openssl base64 curl; do
  if ! command -v "${_cmd}" >/dev/null 2>&1; then
	echo "!!! ERROR: '${_cmd}' not found; run SetupAzureIoTOperationsPi.sh first. Aborting."
	exit 1
  fi
done

# --------------------------
# 1. Azure sign-in (service principal, as in SetupAzureIoTOperationsPi.sh)
# --------------------------
SP_HELPER_URL="https://raw.githubusercontent.com/digitaltwinconsortium/ManufacturingOntologies/main/Deployment/CreateRaspberryPiServicePrincipal.sh"
sp_instructions() {
  echo "    Create a service principal by running this in Azure Cloud Shell (https://shell.azure.com, Bash):"
  echo "      curl -fsSL ${SP_HELPER_URL} | PI_SCRIPT=ConnectUAEdgeTranslatorPi.sh bash -s -- ${RESOURCE_GROUP} ${SUBSCRIPTION_ID}"
  echo "    and run the command it prints on the Pi. Aborting."
}
# A new service principal or secret takes a few minutes to replicate in Entra ID; until then the sign-in
# fails with AADSTS7000229 (no service principal), AADSTS700016 (unknown app) or AADSTS7000215 (invalid
# secret). Retry those for up to 3 minutes.
SP_LOGIN_OUTPUT=""
sp_login() {
  local i
  for i in $(seq 1 12); do
    if SP_LOGIN_OUTPUT="$(az login --service-principal --username "${AZURE_CLIENT_ID}" --password "${AZURE_CLIENT_SECRET:-}" \
         --tenant "${AZURE_TENANT_ID}" --output none 2>&1)"; then
      return 0
    fi
    case "${SP_LOGIN_OUTPUT}" in
      *AADSTS7000229*|*AADSTS700016*|*AADSTS7000215*) ;;
      *) break ;;
    esac
    [ "${i}" -lt 12 ] || break
    echo "    Entra ID has not replicated the service principal/secret yet; retrying in 15s (${i}/11)..."
    sleep 15
  done
  printf '%s\n' "${SP_LOGIN_OUTPUT}" | grep -E '^(ERROR|WARNING)' || printf '%s\n' "${SP_LOGIN_OUTPUT}"
  return 1
}
sp_login_hint() {
  case "${SP_LOGIN_OUTPUT}" in
    *AADSTS7000229*)
      echo "    App ${AZURE_CLIENT_ID} has no service principal (enterprise application) in tenant ${AZURE_TENANT_ID}."
      echo "    Create it and its role in Azure Cloud Shell, then re-run this command:"
      echo "      az ad sp create --id ${AZURE_CLIENT_ID}"
      echo "      az role assignment create --assignee ${AZURE_CLIENT_ID} --role Owner --scope /subscriptions/${SUBSCRIPTION_ID:-<subscription-id>}/resourceGroups/${RESOURCE_GROUP}"
      echo "    Or re-run the helper below (it now creates a missing service principal)." ;;
    *AADSTS7000215*|*AADSTS7000222*)
      echo "    The client secret is wrong or expired; the helper below issues a new one." ;;
    *AADSTS700016*|*AADSTS90002*)
      echo "    App ${AZURE_CLIENT_ID} or tenant ${AZURE_TENANT_ID} does not exist (deleted, or a different tenant)." ;;
  esac
}
echo
echo "=== Signing in to Azure ==="
if [ -n "${AZURE_CLIENT_ID:-}" ] && [ -n "${AZURE_TENANT_ID:-}" ]; then
  if [ -z "${AZURE_CLIENT_SECRET:-}" ]; then
	# Prompt on the terminal (stdin may be the piped script), keeping the secret out of the shell history.
	read -r -s -p "Client secret of service principal ${AZURE_CLIENT_ID}: " AZURE_CLIENT_SECRET </dev/tty 2>/dev/null || true
	echo
  fi
  echo ">>> az login --service-principal (client id ${AZURE_CLIENT_ID})"
  if ! sp_login; then
	echo "!!! ERROR: service principal sign-in failed."
	sp_login_hint
	sp_instructions
	exit 1
  fi
# 'az account show' only reads the local profile, so verify the cached session against the resource group
# (the setup's service principal may have been deleted or its secret expired since).
elif az account show >/dev/null 2>&1 \
	 && az group show --name "${RESOURCE_GROUP}" ${SUBSCRIPTION_ID:+--subscription "${SUBSCRIPTION_ID}"} --output none 2>/dev/null; then
  echo "Reusing the existing Azure CLI session ($(az account show --query user.name -o tsv 2>/dev/null))."
else
  echo "!!! ERROR: no valid Azure CLI session for resource group ${RESOURCE_GROUP} and no service principal given"
  echo "    (AZURE_CLIENT_ID/AZURE_TENANT_ID/AZURE_CLIENT_SECRET)."
  sp_instructions
  exit 1
fi
if [ -n "${SUBSCRIPTION_ID}" ]; then
  run az account set --subscription "${SUBSCRIPTION_ID}"
else
  SUBSCRIPTION_ID="$(az account show --query id -o tsv 2>/dev/null)"
fi
echo "Subscription: ${SUBSCRIPTION_ID}"

if ! az iot ops show --name "${AIO_INSTANCE_NAME}" --resource-group "${RESOURCE_GROUP}" --output none 2>/dev/null; then
  echo "!!! ERROR: AIO instance ${AIO_INSTANCE_NAME} not found in ${RESOURCE_GROUP}; run SetupAzureIoTOperationsPi.sh first. Aborting."
  exit 1
fi

# --------------------------
# 2. Admin credentials of the arm.json deployment
# --------------------------
# EdgeTranslator's OPC UA user is the adminUsername/adminPassword entered when deploying arm.json: the
# username is a plain deployment parameter, the password is stored in the deployment's Key Vault as
# 'adminpassword' (secure parameters cannot be read back from the deployment).
echo
echo "=== Reading the admin credentials of the arm.json deployment ==="
detect_public_ipv4() {
  local url ip
  for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip https://checkip.amazonaws.com; do
	ip="$(curl -4 -fsS --max-time 10 "${url}" 2>/dev/null | tr -d '[:space:]')"
	if [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
	  echo "${ip}"
	  return 0
	fi
  done
  return 1
}
kv_reachable() { az keyvault secret list --vault-name "${KEY_VAULT_NAME}" --maxresults 1 --output none 2>/dev/null; }
# Object ID of the signed-in principal from the ARM token's 'oid' claim (no Microsoft Graph permission needed).
access_token_claim() {
  local payload
  payload="$(az account get-access-token --query accessToken -o tsv 2>/dev/null | cut -d. -f2 | tr '_-' '/+')"
  while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload="${payload}="; done
  printf '%s' "${payload}" | base64 -d 2>/dev/null | jq -r --arg c "$1" '.[$c] // empty' 2>/dev/null
}
if ! kv_reachable; then
  # Firewall: the Pi's public IP changed or arm.json was re-deployed (which resets the vault's IP rules).
  # RBAC: arm.json grants Key Vault data roles only to the managed identity and SetupAzureIoTOperationsPi.sh
  # to the principal it ran as - a new service principal (new object ID) needs its own role assignment.
  KEY_VAULT_ID="$(az keyvault show --name "${KEY_VAULT_NAME}" --resource-group "${RESOURCE_GROUP}" --query id -o tsv 2>/dev/null)"
  PI_PUBLIC_IP="${PI_PUBLIC_IP:-$(detect_public_ipv4)}"
  if [ -n "${PI_PUBLIC_IP}" ]; then
	echo ">>> Allowing the Pi's public IP ${PI_PUBLIC_IP} through the Key Vault firewall"
	run az keyvault network-rule add --name "${KEY_VAULT_NAME}" --resource-group "${RESOURCE_GROUP}" \
	  --ip-address "${PI_PUBLIC_IP}/32" --output none
  else
	echo "!!! WARNING: could not detect the Pi's public IP (set PI_PUBLIC_IP=<ip>)."
  fi
  SIGNED_IN_OID="$(access_token_claim oid)"
  SIGNED_IN_PRINCIPAL_TYPE="User"
  [ "$(az account show --query user.type -o tsv 2>/dev/null)" = "servicePrincipal" ] && SIGNED_IN_PRINCIPAL_TYPE="ServicePrincipal"
  if [ -n "${KEY_VAULT_ID}" ] && [ -n "${SIGNED_IN_OID}" ]; then
	existing_ra="$(az role assignment list --scope "${KEY_VAULT_ID}" --role "Key Vault Secrets Officer" \
	  --fill-principal-name false --query "[?principalId=='${SIGNED_IN_OID}'].id | [0]" -o tsv 2>/dev/null)"
	if [ -z "${existing_ra}" ]; then
	  echo ">>> Granting ${SIGNED_IN_PRINCIPAL_TYPE} ${SIGNED_IN_OID} 'Key Vault Secrets Officer' on ${KEY_VAULT_NAME}"
	  run az role assignment create --assignee-object-id "${SIGNED_IN_OID}" \
		--assignee-principal-type "${SIGNED_IN_PRINCIPAL_TYPE}" --role "Key Vault Secrets Officer" \
		--scope "${KEY_VAULT_ID}" --output none
	fi
  else
	echo "!!! WARNING: could not resolve Key Vault ${KEY_VAULT_NAME} or the signed-in principal; grant it"
	echo "    'Key Vault Secrets Officer' on the vault manually."
  fi
  echo ">>> Waiting for Key Vault access (firewall and role changes take a few minutes to propagate)..."
  for _i in $(seq 1 36); do
	kv_reachable && break
	sleep 10
  done
fi
# Latest deployment in the resource group that has an adminUsername parameter (arm.json; fabric.json uses the same).
ARM_USERNAME="$(az deployment group list --resource-group "${RESOURCE_GROUP}" \
  --query "sort_by([?properties.parameters.adminUsername], &properties.timestamp)[-1].properties.parameters.adminUsername.value" \
  -o tsv 2>/dev/null)"
ARM_PASSWORD=""
if kv_reachable; then
  ARM_PASSWORD="$(az keyvault secret show --vault-name "${KEY_VAULT_NAME}" --name adminpassword --query value -o tsv 2>/dev/null)"
else
  echo "!!! WARNING: Key Vault ${KEY_VAULT_NAME} is not reachable from the Pi:"
  az keyvault secret list --vault-name "${KEY_VAULT_NAME}" --maxresults 1 --output none 2>&1 | grep -m 3 -v '^$' | sed 's/^/    /'
fi
echo "adminUsername: ${ARM_USERNAME:-<not found>}"
echo "adminPassword: $([ -n "${ARM_PASSWORD}" ] && echo "<read from ${KEY_VAULT_NAME}/adminpassword>" || echo '<not found>')"

# --------------------------
# 3. Deploy UA Edge Translator
# --------------------------
echo
echo "=== Deploying UA Edge Translator (${ET_MANIFEST_URL}) ==="
if ! curl -fsSL --retry 3 "${ET_MANIFEST_URL}" -o "${WORK_DIR}/ua-edgetranslator.yaml"; then
  echo "!!! ERROR: could not download ${ET_MANIFEST_URL}. Aborting."
  exit 1
fi
# Render the manifest to JSON client-side so it can be inspected and patched with jq. kubectl prints one
# JSON object per YAML document (or a List), so slurp and flatten them into one array.
if ! kubectl create --dry-run=client -o json -f "${WORK_DIR}/ua-edgetranslator.yaml" \
	 | jq -sc '[.[] | if .kind == "List" then .items[] else . end]' > "${WORK_DIR}/et-objects.json"; then
  echo "!!! ERROR: could not parse ${ET_MANIFEST_URL}. Aborting."
  exit 1
fi
ET_DEPLOYMENT="$(jq -r '[.[] | select(.kind == "Deployment")][0].metadata.name // empty' "${WORK_DIR}/et-objects.json")"
if [ -z "${ET_DEPLOYMENT}" ]; then
  echo "!!! ERROR: ${ET_MANIFEST_URL} contains no Deployment. Aborting."
  exit 1
fi
# Evaluates a jq filter against the manifest's Deployment.
et_deployment() {
  jq -r --arg d "${ET_DEPLOYMENT}" "[.[] | select(.kind == \"Deployment\" and .metadata.name == \$d)][0] | $1" \
	"${WORK_DIR}/et-objects.json"
}
ET_NAMESPACE="$(et_deployment '.metadata.namespace // "default"')"
ET_CONTAINER="$(et_deployment '.spec.template.spec.containers | (map(select(any(.ports[]?; .containerPort == 4840))) + .)[0].name')"
ET_CREDENTIALS_SECRET="$(et_deployment '[.spec.template.spec.containers[].env[]? | select(.name == "OPCUA_USERNAME") | .valueFrom.secretKeyRef.name // empty][0] // "ua-edgetranslator-credentials"')"
ET_UID="$(et_deployment '.spec.template.spec.securityContext.runAsUser // 1654')"
ET_GID="$(et_deployment '.spec.template.spec.securityContext.runAsGroup // 1654')"
# Host directories behind the pod's /app/settings and /app/pki mounts.
hostpath_for_mount() {
  et_deployment ".spec.template.spec as \$s
	| ([\$s.containers[].volumeMounts[]? | select(.mountPath == \"$1\") | .name] | first) as \$v
	| [\$s.volumes[]? | select(.name == \$v) | .hostPath.path // empty] | first // empty"
}
ET_SETTINGS_DIR="$(hostpath_for_mount /app/settings)"
ET_PKI_DIR="$(hostpath_for_mount /app/pki)"
ET_SETTINGS_DIR="${ET_SETTINGS_DIR:-/mnt/c/K3s/UAEdgeTranslator/Settings}"
ET_PKI_DIR="${ET_PKI_DIR:-/mnt/c/K3s/UAEdgeTranslator/PKI}"
ET_SERVICE="$(jq -r --arg ns "${ET_NAMESPACE}" '[.[] | select(.kind == "Service" and (.metadata.namespace // "default") == $ns
  and any(.spec.ports[]?; .port == 4840)) | .metadata.name][0] // empty' "${WORK_DIR}/et-objects.json")"
ET_ENDPOINT="${ET_ENDPOINT:-opc.tcp://${ET_SERVICE:-${ET_DEPLOYMENT}}.${ET_NAMESPACE}.svc.cluster.local:4840/UA/UAEdgeTranslator}"
echo "Deployment: ${ET_NAMESPACE}/${ET_DEPLOYMENT} (container ${ET_CONTAINER})"
echo "Settings:   ${ET_SETTINGS_DIR}"
echo "PKI:        ${ET_PKI_DIR}"
echo "Endpoint:   ${ET_ENDPOINT} (SignAndEncrypt/${ET_SECURITY_POLICY}, username/password)"

# Create the hostPath directories up front; the manifest's init container fixes their ownership.
while IFS= read -r _dir; do
  [ -n "${_dir}" ] && mkdir -p "${_dir}"
done < <(et_deployment '.spec.template.spec.volumes[]?.hostPath.path // empty')

# OPC UA user: the arm.json admin credentials (section 2). The manifest only carries a REPLACE_ME placeholder
# secret, which is dropped below so that re-applying the manifest never overwrites them.
kubectl create namespace "${ET_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
existing_user="$(kubectl -n "${ET_NAMESPACE}" get secret "${ET_CREDENTIALS_SECRET}" -o jsonpath='{.data.OPCUA_USERNAME}' 2>/dev/null | base64 -d 2>/dev/null)"
existing_pass="$(kubectl -n "${ET_NAMESPACE}" get secret "${ET_CREDENTIALS_SECRET}" -o jsonpath='{.data.OPCUA_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null)"
ET_USERNAME="${ET_USERNAME:-${ARM_USERNAME}}"
ET_PASSWORD="${ET_PASSWORD:-${ARM_PASSWORD}}"
if [ -z "${ET_USERNAME}" ] || [ -z "${ET_PASSWORD}" ]; then
  if [ -n "${existing_user}" ] && [ "${existing_user}" != "REPLACE_ME" ] \
	 && [ -n "${existing_pass}" ] && [ "${existing_pass}" != "REPLACE_ME" ]; then
	echo "!!! WARNING: could not read the arm.json admin credentials; keeping the OPC UA user '${existing_user}'"
	echo "    from ${ET_NAMESPACE}/${ET_CREDENTIALS_SECRET}."
	ET_USERNAME="${existing_user}"
	ET_PASSWORD="${existing_pass}"
  else
	echo "!!! ERROR: could not read the arm.json admin credentials (deployment parameter adminUsername and Key Vault"
	echo "    secret ${KEY_VAULT_NAME}/adminpassword). Check the Pi's access to the resource group and Key Vault, or pass"
	echo "    them explicitly: '... | sudo ET_USERNAME=<user> ET_PASSWORD=<password> bash -s -- ${RESOURCE_GROUP}'. Aborting."
	exit 1
  fi
fi
credentials_changed=false
if [ "${ET_USERNAME}" != "${existing_user}" ] || [ "${ET_PASSWORD}" != "${existing_pass}" ]; then
  credentials_changed=true
  # Values go through files so they never appear on a command line (ps, logs).
  if kubectl -n "${ET_NAMESPACE}" get secret "${ET_CREDENTIALS_SECRET}" >/dev/null 2>&1; then
	# Patch instead of replace: keeps optional keys such as UACL* or LICENSE_KEY.
	printf '%s' "${ET_USERNAME}" | base64 -w0 > "${WORK_DIR}/u.b64"
	printf '%s' "${ET_PASSWORD}" | base64 -w0 > "${WORK_DIR}/p.b64"
	jq -n --rawfile u "${WORK_DIR}/u.b64" --rawfile p "${WORK_DIR}/p.b64" \
	  '{data: {OPCUA_USERNAME: $u, OPCUA_PASSWORD: $p}}' > "${WORK_DIR}/secret-patch.json"
	run kubectl -n "${ET_NAMESPACE}" patch secret "${ET_CREDENTIALS_SECRET}" --type merge --patch-file "${WORK_DIR}/secret-patch.json"
	rm -f "${WORK_DIR}/u.b64" "${WORK_DIR}/p.b64" "${WORK_DIR}/secret-patch.json"
  else
	printf '%s' "${ET_USERNAME}" > "${WORK_DIR}/OPCUA_USERNAME"
	printf '%s' "${ET_PASSWORD}" > "${WORK_DIR}/OPCUA_PASSWORD"
	run kubectl -n "${ET_NAMESPACE}" create secret generic "${ET_CREDENTIALS_SECRET}" \
	  --from-file="${WORK_DIR}/OPCUA_USERNAME" --from-file="${WORK_DIR}/OPCUA_PASSWORD"
	rm -f "${WORK_DIR}/OPCUA_USERNAME" "${WORK_DIR}/OPCUA_PASSWORD"
  fi
  if [ "${RUN_LAST_RC}" -ne 0 ]; then
	echo "!!! ERROR: could not write secret ${ET_NAMESPACE}/${ET_CREDENTIALS_SECRET}. Aborting."
	exit 1
  fi
else
  echo ">>> ${ET_NAMESPACE}/${ET_CREDENTIALS_SECRET} already holds the OPC UA user '${ET_USERNAME}'."
fi
echo "OPC UA user: ${ET_USERNAME} (password stored in ${ET_NAMESPACE}/${ET_CREDENTIALS_SECRET})"

# Without an issuer certificate EdgeTranslator is in provisioning mode: it auto-accepts any client but
# answers every tag read with BadNotReadable. IGNORE_PROVISIONING_MODE lifts the read block; clients must
# then be trusted explicitly (done for AIO in section 6).
jq --arg d "${ET_DEPLOYMENT}" --arg c "${ET_CONTAINER}" '
  {apiVersion: "v1", kind: "List",
   items: map(select(.kind != "Secret")
	 | if .kind == "Deployment" and .metadata.name == $d then
		 .spec.template.spec.containers |= map(if .name == $c then
		   .env = ([.env[]? | select(.name != "IGNORE_PROVISIONING_MODE")] + [{name: "IGNORE_PROVISIONING_MODE", value: "true"}])
		 else . end)
	   else . end)}' "${WORK_DIR}/et-objects.json" > "${WORK_DIR}/et-manifest.json"
et_existed=false
kubectl -n "${ET_NAMESPACE}" get deployment "${ET_DEPLOYMENT}" >/dev/null 2>&1 && et_existed=true
run kubectl apply -f "${WORK_DIR}/et-manifest.json"
if [ "${RUN_LAST_RC}" -ne 0 ]; then
  echo "!!! ERROR: could not deploy UA Edge Translator. Aborting."
  exit 1
fi
# Environment variables from a secret are only read at container start.
if [ "${et_existed}" = "true" ] && [ "${credentials_changed}" = "true" ]; then
  run kubectl -n "${ET_NAMESPACE}" rollout restart "deployment/${ET_DEPLOYMENT}"
fi
run kubectl -n "${ET_NAMESPACE}" rollout status "deployment/${ET_DEPLOYMENT}" --timeout=600s

# pki/own/certs holds the RSA application certificate plus ECC variants; the RSA policies need the RSA one.
et_rsa_certs() {
  local f
  for f in "${ET_PKI_DIR}"/own/certs/*.der; do
	[ -f "${f}" ] || continue
	case "${f}" in
	  *NistP256*|*NistP384*|*BrainpoolP256r1*|*BrainpoolP384r1*) continue ;;
	esac
	printf '%s\n' "${f}"
  done
}
echo ">>> Waiting for UA Edge Translator's application certificate in ${ET_PKI_DIR}/own/certs..."
for _i in $(seq 1 60); do
  [ -n "$(et_rsa_certs)" ] && break
  sleep 5
done
if [ -z "$(et_rsa_certs)" ]; then
  echo "!!! ERROR: no RSA application certificate in ${ET_PKI_DIR}/own/certs. Check the pod with"
  echo "    kubectl -n ${ET_NAMESPACE} logs deployment/${ET_DEPLOYMENT} --tail=100. Aborting."
  exit 1
fi

# --------------------------
# 4. Credentials: Key Vault -> AIO secret sync
# --------------------------
echo
echo "=== Syncing the OPC UA credentials into AIO (${CREDENTIALS_SYNC_NAME}) ==="
credentials_synced=false
if kv_reachable; then
  printf '%s' "${ET_USERNAME}" > "${WORK_DIR}/username"
  printf '%s' "${ET_PASSWORD}" > "${WORK_DIR}/password"
  echo ">>> az keyvault secret set --vault-name ${KEY_VAULT_NAME} --name ${KV_USERNAME_SECRET} / ${KV_PASSWORD_SECRET}"
  if az keyvault secret set --vault-name "${KEY_VAULT_NAME}" --name "${KV_USERNAME_SECRET}" \
	   --file "${WORK_DIR}/username" --encoding utf-8 --output none \
	 && az keyvault secret set --vault-name "${KEY_VAULT_NAME}" --name "${KV_PASSWORD_SECRET}" \
	   --file "${WORK_DIR}/password" --encoding utf-8 --output none; then
	run az iot ops secretsync secret set \
	  --instance "${AIO_INSTANCE_NAME}" \
	  --resource-group "${RESOURCE_GROUP}" \
	  --secret-sync-name "${CREDENTIALS_SYNC_NAME}" \
	  --secret-map "${KV_USERNAME_SECRET}=username" \
	  --secret-map "${KV_PASSWORD_SECRET}=password"
	[ "${RUN_LAST_RC}" -eq 0 ] && credentials_synced=true
  else
	echo "!!! WARNING: could not write the credentials to Key Vault ${KEY_VAULT_NAME}."
  fi
  rm -f "${WORK_DIR}/username" "${WORK_DIR}/password"
else
  echo "!!! WARNING: Key Vault ${KEY_VAULT_NAME} is not reachable from the Pi (firewall/RBAC)."
fi

if [ "${credentials_synced}" = "true" ]; then
  echo ">>> Waiting for secret ${AIO_NAMESPACE}/${CREDENTIALS_SYNC_NAME} to be synced..."
  for _i in $(seq 1 60); do
	_keys="$(kubectl -n "${AIO_NAMESPACE}" get secret "${CREDENTIALS_SYNC_NAME}" -o json 2>/dev/null \
	  | jq -r '(.data // {}) | (has("username") and has("password"))' 2>/dev/null)"
	[ "${_keys}" = "true" ] && break
	sleep 5
  done
  if [ "${_keys:-}" = "true" ]; then
	echo ">>> Credentials synced."
  else
	echo "!!! WARNING: ${CREDENTIALS_SYNC_NAME} is not populated yet; the connector retries once secret sync catches up."
  fi
elif [ "${credentials_changed}" != "true" ] && kubectl -n "${AIO_NAMESPACE}" get secret "${CREDENTIALS_SYNC_NAME}" >/dev/null 2>&1; then
  echo ">>> Keeping the existing secret ${AIO_NAMESPACE}/${CREDENTIALS_SYNC_NAME}."
else
  # Fallback without Key Vault: a plain k8s secret with the same name/keys works for the connector, but is
  # not managed by secret sync. Re-run this script once Key Vault is reachable to switch over.
  echo "!!! WARNING: falling back to a local k8s secret ${AIO_NAMESPACE}/${CREDENTIALS_SYNC_NAME}."
  printf '%s' "${ET_USERNAME}" > "${WORK_DIR}/username"
  printf '%s' "${ET_PASSWORD}" > "${WORK_DIR}/password"
  kubectl -n "${AIO_NAMESPACE}" create secret generic "${CREDENTIALS_SYNC_NAME}" \
	--from-file="${WORK_DIR}/username" --from-file="${WORK_DIR}/password" \
	--dry-run=client -o yaml | kubectl apply -f -
  rm -f "${WORK_DIR}/username" "${WORK_DIR}/password"
fi
unset ET_PASSWORD existing_pass ARM_PASSWORD

# --------------------------
# 5. AIO trusts UA Edge Translator
# --------------------------
echo
echo "=== Adding UA Edge Translator's certificate to AIO's trust list ==="
et_trust_key=""
while IFS= read -r cert_file; do
  # Key Vault secret names and secretSync target keys reject the dots, spaces and brackets of the file name.
  cert_stem="$(basename "${cert_file}" | sed 's/\.[^.]*$//; s/[^0-9A-Za-z]/-/g; s/--*/-/g; s/^-//; s/-$//')"
  cp "${cert_file}" "${WORK_DIR}/${cert_stem}.der"
  run az iot ops connector opcua trust add \
	--instance "${AIO_INSTANCE_NAME}" \
	--resource-group "${RESOURCE_GROUP}" \
	--certificate-file "${WORK_DIR}/${cert_stem}.der" \
	--secret-name "${cert_stem}"
  et_trust_key="${cert_stem}.der"
done < <(et_rsa_certs)
echo ">>> Waiting for ${et_trust_key} in ${AIO_TRUST_LIST_SECRET}..."
for _i in $(seq 1 60); do
  _present="$(kubectl -n "${AIO_NAMESPACE}" get secret "${AIO_TRUST_LIST_SECRET}" -o json 2>/dev/null \
	| jq -r --arg k "${et_trust_key}" '(.data // {}) | has($k)' 2>/dev/null)"
  [ "${_present}" = "true" ] && break
  sleep 5
done
if [ "${_present:-}" = "true" ]; then
  echo ">>> Trusted."
else
  echo "!!! WARNING: not synced yet; the connector picks it up once secret sync catches up."
fi

# --------------------------
# 6. UA Edge Translator trusts AIO
# --------------------------
# With IGNORE_PROVISIONING_MODE EdgeTranslator no longer auto-accepts clients, so install AIO's connector
# certificate (used by the connector and the OPC UA Commander) into its trusted store. The OPC UA .NET
# stack re-reads the directory store on each validation; no restart is needed.
echo
echo "=== Adding AIO's connector certificate to UA Edge Translator's trusted store ==="
AIO_CERT_SECRET_JSON="$(kubectl -n "${AIO_NAMESPACE}" get secret "${AIO_OPCUA_CERT_SECRET}" -o json 2>/dev/null)"
if [ -n "${AIO_CERT_SECRET_JSON}" ]; then
  printf '%s' "${AIO_CERT_SECRET_JSON}" | jq -r '.data["tls.crt"] // empty' | base64 -d > "${WORK_DIR}/aio.crt" 2>/dev/null
  # tls.crt may hold a chain; the first certificate is the connector's application certificate.
  if openssl x509 -in "${WORK_DIR}/aio.crt" -outform der -out "${WORK_DIR}/aio.der" 2>/dev/null; then
	run mkdir -p "${ET_PKI_DIR}/trusted/certs"
	run install -m 0644 -o "${ET_UID}" -g "${ET_GID}" "${WORK_DIR}/aio.der" "${ET_PKI_DIR}/trusted/certs/aio-opcuabroker.der"
	# If the certificate is CA-issued rather than self-signed, the validator also needs the issuing CA to
	# build the chain. It goes into trusted/certs, not issuer/certs: a file in issuer/certs would end
	# EdgeTranslator's provisioning mode.
	aio_subject="$(openssl x509 -in "${WORK_DIR}/aio.crt" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//')"
	aio_issuer="$(openssl x509 -in "${WORK_DIR}/aio.crt" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer=//')"
	if [ "${aio_subject}" != "${aio_issuer}" ]; then
	  printf '%s' "${AIO_CERT_SECRET_JSON}" | jq -r '.data["ca.crt"] // empty' | base64 -d > "${WORK_DIR}/aio-ca.crt" 2>/dev/null
	  if openssl x509 -in "${WORK_DIR}/aio-ca.crt" -outform der -out "${WORK_DIR}/aio-ca.der" 2>/dev/null; then
		run install -m 0644 -o "${ET_UID}" -g "${ET_GID}" "${WORK_DIR}/aio-ca.der" "${ET_PKI_DIR}/trusted/certs/aio-opcuabroker-ca.der"
	  else
		echo "!!! WARNING: AIO's certificate is issued by '${aio_issuer}' but the secret has no ca.crt;"
		echo "    copy that CA into ${ET_PKI_DIR}/trusted/certs if EdgeTranslator reports BadCertificateChainIncomplete."
	  fi
	fi
  else
	echo "!!! WARNING: could not read AIO's connector certificate from ${AIO_OPCUA_CERT_SECRET}."
  fi
else
  echo "!!! WARNING: secret ${AIO_NAMESPACE}/${AIO_OPCUA_CERT_SECRET} not found; UA Edge Translator will reject AIO."
fi

# --------------------------
# 7. AIO device: OPC UA telemetry endpoint + WoT connectivity endpoint
# --------------------------
# Both endpoints point to EdgeTranslator with the same address, security and credentials. The OPC UA
# Commander manages assets through the Microsoft.OpcUa.WoT endpoint (EdgeTranslator only allows that for an
# authenticated user over SignAndEncrypt) and binds the discovered assets to the Microsoft.OpcUa endpoint
# named by 'endpointRef', which the connector uses to read the variables and publish telemetry.
echo
echo "=== Configuring AIO device ${DEVICE_NAME} (endpoints ${ENDPOINT_NAME} and ${WOT_ENDPOINT_NAME}) ==="
NS_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DeviceRegistry/namespaces/${AIO_NAMESPACE_NAME}"

# Discovered assets only exist as custom resources on the cluster until resource sync is enabled; only then
# are they synced to Azure Device Registry and listed under Discovery in the operations experience.
enable_resource_sync

if az resource show --ids "${NS_ID}/devices/${DEVICE_NAME}" --output none 2>/dev/null; then
  echo ">>> Device ${DEVICE_NAME} already exists."
else
  run az iot ops ns device create \
	--resource-group "${RESOURCE_GROUP}" \
	--instance "${AIO_INSTANCE_NAME}" \
	--name "${DEVICE_NAME}" \
	--manufacturer "OPC Foundation" \
	--model "UA Edge Translator"
fi

run az iot ops ns device endpoint inbound add opcua \
  --resource-group "${RESOURCE_GROUP}" \
  --instance "${AIO_INSTANCE_NAME}" \
  --device "${DEVICE_NAME}" \
  --name "${ENDPOINT_NAME}" \
  --endpoint-address "${ET_ENDPOINT}" \
  --security-mode signAndEncrypt \
  --security-policy "${ET_SECURITY_POLICY}" \
  --user-ref "${CREDENTIALS_SYNC_NAME}/username" \
  --pass-ref "${CREDENTIALS_SYNC_NAME}/password" \
  --replace true

# The WoT endpoint reuses the telemetry endpoint's saved security settings.
TELEMETRY_SECURITY="$(az iot ops ns device show --name "${DEVICE_NAME}" --instance "${AIO_INSTANCE_NAME}" \
  --resource-group "${RESOURCE_GROUP}" --output json 2>/dev/null \
  | jq -c --arg ep "${ENDPOINT_NAME}" '.properties.endpoints.inbound[$ep].additionalConfiguration // "{}"
	  | (if type == "string" then (try fromjson catch {}) else . end) | .security // empty | objects' 2>/dev/null)"
if [ -z "${TELEMETRY_SECURITY}" ]; then
  echo "!!! WARNING: could not read back the security settings of ${ENDPOINT_NAME}; using SignAndEncrypt/${ET_SECURITY_POLICY}."
  TELEMETRY_SECURITY="$(jq -nc --arg p "${ET_SECURITY_POLICY}" '{autoAcceptUntrustedServerCertificates: false,
	securityMode: "signAndEncrypt", securityPolicy: ("http://opcfoundation.org/UA/SecurityPolicy#" + $p)}')"
fi
# Thing Descriptions are sent on demand with the createAsset mRPC (aio-wot), so the endpoint only carries
# the discovery and security settings.
WOT_CONFIG="$(jq -nc --arg ref "${ENDPOINT_NAME}" --argjson sec "${TELEMETRY_SECURITY}" \
  '{runAssetDiscovery: true, endpointRef: $ref, security: $sec}')"
echo "WoT endpoint configuration: ${WOT_CONFIG}"
run az iot ops ns device endpoint inbound add custom \
  --resource-group "${RESOURCE_GROUP}" \
  --instance "${AIO_INSTANCE_NAME}" \
  --device "${DEVICE_NAME}" \
  --name "${WOT_ENDPOINT_NAME}" \
  --endpoint-type Microsoft.OpcUa.WoT \
  --endpoint-address "${ET_ENDPOINT}" \
  --user-ref "${CREDENTIALS_SYNC_NAME}/username" \
  --pass-ref "${CREDENTIALS_SYNC_NAME}/password" \
  --additional-config "${WOT_CONFIG}" \
  --replace true
if [ "${RUN_LAST_RC}" -ne 0 ]; then
  echo "!!! ERROR: could not configure the WoT endpoint ${WOT_ENDPOINT_NAME}. Aborting."
  exit 1
fi

# --------------------------
# 8. MQTT client + aio-wot helper for the on-demand mRPC methods
# --------------------------
echo
echo "=== Preparing the mRPC client (${AIO_NAMESPACE}/${MQTT_CLIENT_POD}, ${WOT_HELPER}) ==="
if ! kubectl -n "${AIO_NAMESPACE}" get pod "${MQTT_CLIENT_POD}" >/dev/null 2>&1; then
  run kubectl apply -f "${MQTT_CLIENT_MANIFEST}"
fi
run kubectl -n "${AIO_NAMESPACE}" wait --for=condition=Ready "pod/${MQTT_CLIENT_POD}" --timeout=300s
# mosquitto_rr is in Alpine's 'mosquitto' package, not in 'mosquitto-clients'. Retry while the pod's own
# startup 'apk add' may still hold the package database lock.
rr_ready=false
for _i in $(seq 1 30); do
  if kubectl -n "${AIO_NAMESPACE}" exec "${MQTT_CLIENT_POD}" -- sh -c \
	 'command -v mosquitto_rr >/dev/null 2>&1 || apk add --no-cache mosquitto >/dev/null 2>&1' 2>/dev/null; then
	rr_ready=true
	break
  fi
  sleep 10
done
[ "${rr_ready}" = "true" ] || echo "!!! WARNING: could not install mosquitto_rr in ${MQTT_CLIENT_POD} yet; aio-wot retries on first use."

{
  echo '#!/usr/bin/env bash'
  echo '# aio-wot - on-demand mRPC calls to the OPC UA WoT connectivity endpoint of Azure IoT Operations'
  echo "# (installed by ConnectUAEdgeTranslatorPi.sh for ${DEVICE_NAME}/${WOT_ENDPOINT_NAME})."
  printf 'AIO_NAMESPACE=%q\nWOT_TOPIC_PREFIX=%q\nMQTT_CLIENT_POD=%q\nMQTT_CLIENT_MANIFEST=%q\n' \
    "${AIO_NAMESPACE}" "${WOT_TOPIC_PREFIX}" "${MQTT_CLIENT_POD}" "${MQTT_CLIENT_MANIFEST}"
  cat <<'HELPER'
set -euo pipefail
usage() {
  cat <<EOF
Usage: aio-wot createAsset <thing-description.jsonld> [asset-name]   upload a TD and run asset discovery
	   aio-wot listAssets                                            list UA Edge Translator's assets
	   aio-wot <method> '<json-payload>'                             e.g. connectionTest, deleteAsset
Sends an AIO RPC request to ${WOT_TOPIC_PREFIX}/<method> through the ${MQTT_CLIENT_POD} pod and prints the
response's MQTT user properties (AppErrCode/AppErrPayload on failure) and body.
EOF
  exit 1
}
[ -n "${KUBECONFIG:-}" ] || [ -f "${HOME}/.kube/config" ] || export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
method="${1:-}"
case "${method}" in
  ""|-h|--help) usage ;;
  createAsset)
	[ -f "${2:-}" ] || usage
	# Strip a UTF-8 BOM; EdgeTranslator tolerates it, jq does not.
	td="$(sed '1s/^\xEF\xBB\xBF//' "$2")"
	if ! printf '%s' "${td}" | jq -e 'type == "object"' >/dev/null 2>&1; then
	  echo "aio-wot: $2 is not a JSON Thing Description." >&2
	  case "${td,,}" in
		*'<!doctype html'*|*'<html'*)
		  echo "         It is an HTML page - download the raw file (https://raw.githubusercontent.com/...)," >&2
		  echo "         not the github.com/.../blob/... page." >&2 ;;
		*) { printf '%s' "${td}" | jq . 2>&1 >/dev/null || true; } | sed 's/^/         /' >&2 ;;
	  esac
	  exit 1
	fi
	# EdgeTranslator names the asset after the TD's 'name'; sending a TD it already has updates that asset.
	name="${3:-$(printf '%s' "${td}" | jq -r '.name // empty')}"
	if [ -z "${name}" ]; then
	  echo "aio-wot: $2 has no 'name'; pass the asset name as the second argument." >&2
	  exit 1
	fi
	payload="$(printf '%s' "${td}" | base64 -w0 | jq -Rc --arg a "${name}" \
	  '{assetName: $a, td: ., tdContentType: "application/td+json", runAssetDiscovery: true}')"
	;;
  *)
	payload="${2:-}"
	[ -n "${payload}" ] || payload='{}'
	;;
esac
if ! printf '%s' "${payload}" | jq -e . >/dev/null 2>&1; then
  echo "aio-wot: the payload is not valid JSON." >&2
  exit 1
fi
# The quickstart mqtt-client is a bare Pod (no controller), so a node reboot/drain or an AIO upgrade can
# remove it for good. Recreate it on demand instead of failing with 'pods "mqtt-client" not found'.
if ! kubectl -n "${AIO_NAMESPACE}" get pod "${MQTT_CLIENT_POD}" >/dev/null 2>&1; then
  echo "aio-wot: ${AIO_NAMESPACE}/${MQTT_CLIENT_POD} not found; recreating it..." >&2
  kubectl apply -f "${MQTT_CLIENT_MANIFEST}" >/dev/null
fi
kubectl -n "${AIO_NAMESPACE}" wait --for=condition=Ready "pod/${MQTT_CLIENT_POD}" --timeout=300s >/dev/null
# mosquitto_rr is in Alpine's 'mosquitto' package. Retry while a fresh pod's own startup 'apk add' may
# still hold the package database lock.
rr_ready=false
for _i in $(seq 1 30); do
  if kubectl -n "${AIO_NAMESPACE}" exec "${MQTT_CLIENT_POD}" -- sh -c \
	 'command -v mosquitto_rr >/dev/null 2>&1 || apk add --no-cache mosquitto >/dev/null 2>&1' 2>/dev/null; then
	rr_ready=true
	break
  fi
  sleep 10
done
if [ "${rr_ready}" != "true" ]; then
  echo "aio-wot: could not install mosquitto_rr in ${MQTT_CLIENT_POD}." >&2
  exit 1
fi
# AIO RPC protocol (https://github.com/Azure/iot-operations-sdks/blob/main/doc/reference/rpc-protocol.md):
# fresh correlation data and response topic per request; the payload is streamed in so large TDs stay off
# the command line.
printf '%s' "${payload}" | kubectl -n "${AIO_NAMESPACE}" exec -i "${MQTT_CLIENT_POD}" -- sh -c '
  c="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d " \n")"
  f="/tmp/aio-wot-$c.json"
  cat > "$f"
  mosquitto_rr -h aio-broker -p 18883 --cafile /var/run/certs/ca.crt \
	-D connect authentication-method K8S-SAT \
	-D connect authentication-data "$(cat /var/run/secrets/tokens/broker-sat)" \
	-V mqttv5 -q 1 \
	-D publish correlation-data "$c" \
	-D publish message-expiry-interval 60 \
	-D publish payload-format-indicator 1 \
	-D publish content-type application/json \
	-D publish user-property __protVer 1.0 \
	-W 75 -F "%P\n%p" -t "$1" -e "clients/aio-wot/$c/$2" -f "$f"
  rc=$?
  rm -f "$f"
  exit $rc' sh "${WOT_TOPIC_PREFIX}/${method}" "${method}"
HELPER
} > "${WORK_DIR}/aio-wot"
run install -m 0755 "${WORK_DIR}/aio-wot" "${WOT_HELPER}"

# --------------------------
# 9. OPC UA PubSub metadata (AIO 2610: only published with opcUaConformance=true)
# --------------------------
# The operations experience imports a discovered asset under its discovered name (e.g.
# '<device>-<wotEndpoint>-<td>-<hash>-0') with a dataset 'dataset-0' unless renamed, and one TD becomes one
# asset, so enable the metadata on every asset bound to this device rather than on one fixed name.
echo
echo "=== Enabling OPC UA metadata for the assets of device ${DEVICE_NAME} ==="
DEVICE_ASSETS=""
ASSETS_URL="https://management.azure.com${NS_ID}/assets?api-version=2025-10-01"
while [ -n "${ASSETS_URL}" ]; do
  ASSETS_PAGE="$(az rest --method get --url "${ASSETS_URL}" -o json 2>/dev/null || true)"
  [ -n "${ASSETS_PAGE}" ] || break
  DEVICE_ASSETS="${DEVICE_ASSETS}$(printf '%s' "${ASSETS_PAGE}" | jq -r --arg d "${DEVICE_NAME}" \
	'.value[]? | select(.properties.deviceRef.deviceName == $d) | .name')"$'\n'
  ASSETS_URL="$(printf '%s' "${ASSETS_PAGE}" | jq -r '.nextLink // empty')"
done
DEVICE_ASSET_COUNT=0
while read -r _asset; do
  [ -n "${_asset}" ] || continue
  DEVICE_ASSET_COUNT=$((DEVICE_ASSET_COUNT + 1))
  _asset_id="${NS_ID}/assets/${_asset}"
  echo ">>> ${_asset}"
  case "${_asset}" in
	"${STATION}-${SITE}-"*) ;;
	*) echo "!!! WARNING: '${_asset}' does not start with '${STATION}-${SITE}-'; ADX/Fabric/Databricks derive"
	   echo "    Workcell/Site from the first two '-' separated parts of the asset name." ;;
  esac
  CURRENT_DEFAULTS="$(az resource show --ids "${_asset_id}" --query "properties.defaultDatasetsConfiguration" -o tsv 2>/dev/null || true)"
  NEW_DEFAULTS="$(printf '%s' "${CURRENT_DEFAULTS}" \
	| jq -Rsc '(try fromjson catch {}) // {} | if type == "object" then . else {} end
		| .opcUaConformance = true | tojson' 2>/dev/null)"
  [ -n "${NEW_DEFAULTS}" ] || NEW_DEFAULTS='"{\"opcUaConformance\":true}"'
  run az resource update --ids "${_asset_id}" \
	--set "properties.defaultDatasetsConfiguration=${NEW_DEFAULTS}" \
		  "properties.description=UA Edge Translator (site ${SITE}), metadata refresh at $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--output none
done <<< "${DEVICE_ASSETS}"
if [ "${DEVICE_ASSET_COUNT}" -eq 0 ]; then
  echo "=== No asset of device ${DEVICE_NAME} imported yet; re-run this script afterwards to enable its OPC UA metadata ==="
fi

echo
echo "=== Done: $(date -Is) ==="
cat <<EOF
UA Edge Translator runs in ${ET_NAMESPACE} and is connected to AIO as device ${DEVICE_NAME}. Its OPC UA user
is '${ET_USERNAME}' with the adminPassword of the arm.json deployment (unless overridden). Next steps:

1. Send each Thing Description to UA Edge Translator through the WoT endpoint (on-demand mRPC). The TD's
   'name' becomes the asset name in EdgeTranslator; the response shows status (Created/Updated), assetNodeId
   and discovery.discoveredAssetNames. Object properties (e.g. Rockwell UDTs), arrays of objects and events
   have no OPC 10100-1 mapping and are not discovered.
	 sudo aio-wot createAsset /path/to/thing.jsonld
	 sudo aio-wot listAssets

2. Check the discovered assets (Akri) with the variables EdgeTranslator now exposes:
	 kubectl get discoveredassets.namespaces.deviceregistry.microsoft.com -n ${AIO_NAMESPACE}
	 kubectl get devices.namespaces.deviceregistry.microsoft.com ${DEVICE_NAME} -n ${AIO_NAMESPACE} -o jsonpath='{.status.endpoints.inbound}'; echo

3. Import them in the operations experience (Discovery > Discovered assets > select the asset > Import and
   create asset; they appear there a minute or two after discovery, once resource sync has synced them).
   Only the dataset is needed (events and management groups can stay empty). Keep an asset name that starts
   with '${STATION}-${SITE}-' (the discovered name does, or use e.g. '${ASSET_NAME}'): the cloud parsers
   derive Workcell=${STATION} and Site=${SITE} from it. The suggested dataset name/topic can stay as is,
   since the data flows forward everything under azure-iot-operations/data/#.

4. After each import, enable the OPC UA metadata (opcUaConformance) of the new asset with the fast follow-up
   script (takes seconds; also runs in Azure Cloud Shell without sudo), instead of re-running this one:
     curl -fsSL https://raw.githubusercontent.com/digitaltwinconsortium/ManufacturingOntologies/main/Deployment/OnboardUAEdgeTranslatorAsset.sh | sudo bash -s -- ${RESOURCE_GROUP} ${SUBSCRIPTION_ID}

Verify the telemetry and metadata:
  kubectl get assets.namespaces.deviceregistry.microsoft.com -n ${AIO_NAMESPACE}
  kubectl exec mqtt-client -n ${AIO_NAMESPACE} -- sh -c 'mosquitto_sub --host aio-broker --port 18883 \\
	-t "azure-iot-operations/data/#" -t "azure-iot-operations/metadata/#" -V mqttv5 -F "%t %p" -C 20 -W 120 \\
	--cafile /var/run/certs/ca.crt -D CONNECT authentication-method K8S-SAT \\
	-D CONNECT authentication-data "\$(cat /var/run/secrets/tokens/broker-sat)"' | grep ${STATION}-${SITE}

Troubleshooting:
  kubectl get pods -n ${AIO_NAMESPACE} | grep aio-opc-   # then: kubectl logs -n ${AIO_NAMESPACE} <pod> | grep -i 'translator\\|wot'
  kubectl logs -n ${ET_NAMESPACE} deployment/${ET_DEPLOYMENT} --tail=200 | grep -i 'certificate\\|session\\|asset'
  ls ${ET_PKI_DIR}/rejected/certs   # AIO's cert here = not trusted by EdgeTranslator
Full log: ${LOG_FILE}
EOF

}

main "$@"
