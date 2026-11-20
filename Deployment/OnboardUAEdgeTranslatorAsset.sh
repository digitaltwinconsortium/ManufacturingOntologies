#!/usr/bin/env bash
# OnboardUAEdgeTranslatorAsset.sh - Fast follow-up to ConnectUAEdgeTranslatorPi.sh for each new Thing
# Description: finishes the onboarding of the UA Edge Translator assets you imported in the operations
# experience, without redeploying or re-trusting anything.
#
# Workflow per asset:
#   1. On the Pi: send the Thing Description to UA Edge Translator (runs AIO asset discovery):
#        sudo aio-wot createAsset <thing-description.jsonld>
#   2. In the operations experience: Discovery > Discovered assets > select it > Import and create asset
#      (only the dataset is needed; keep a name starting with '<station>-<site>-', which the default has).
#   3. Run this script. It:
#        - lists the discovered assets of the device and whether they are imported yet,
#        - enables OPC UA PubSub metadata (opcUaConformance, required since AIO 2610) on every imported asset
#          of the device that does not have it yet (REFRESH=true re-publishes the metadata of all of them),
#        - warns about asset names the cloud parsers cannot map to Workcell/Site.
#
# It only uses the Azure CLI (plus jq), so it takes seconds and runs on the Pi or in Azure Cloud Shell:
#   Pi:          curl -fsSL https://raw.githubusercontent.com/digitaltwinconsortium/ManufacturingOntologies/main/Deployment/OnboardUAEdgeTranslatorAsset.sh | sudo bash -s -- <resource-group> [subscription-id]
#   Cloud Shell: curl -fsSL https://raw.githubusercontent.com/digitaltwinconsortium/ManufacturingOntologies/main/Deployment/OnboardUAEdgeTranslatorAsset.sh | bash -s -- <resource-group> [subscription-id]
# Sign-in: reuses the current Azure CLI session (Cloud Shell, or root's session on the Pi from the setup
# scripts) if it can read the resource group; otherwise pass the service principal created with
# CreateRaspberryPiServicePrincipal.sh: '... | sudo AZURE_CLIENT_ID=... AZURE_TENANT_ID=... AZURE_CLIENT_SECRET='...' bash -s -- <rg> [sub]'.
#
# Optional environment overrides:
#   SITE, STATION   Same values as for ConnectUAEdgeTranslatorPi.sh (default: nuremberg, translator)
#   REFRESH=true    Also re-publish the metadata of assets that already have it enabled

SCRIPT_URL="https://raw.githubusercontent.com/digitaltwinconsortium/ManufacturingOntologies/main/Deployment/OnboardUAEdgeTranslatorAsset.sh"

main() {

set -u
set -o pipefail

RESOURCE_GROUP="${1:-}"
SUBSCRIPTION_ID="${2:-}"
SITE="$(printf '%s' "${SITE:-nuremberg}" | tr '[:upper:]' '[:lower:]')"
STATION="$(printf '%s' "${STATION:-translator}" | tr '[:upper:]' '[:lower:]')"
REFRESH="${REFRESH:-false}"
DEVICE_NAME="${STATION}-${SITE}"
ADR_API_VERSION="2025-10-01"

if [ -z "${RESOURCE_GROUP}" ]; then
  echo "Usage: curl -fsSL ${SCRIPT_URL} | bash -s -- <resource-group> [subscription-id]"
  exit 1
fi
AIO_NAMESPACE_NAME="$(printf '%s-aions' "${RESOURCE_GROUP}" | tr '[:upper:]' '[:lower:]')"
for _cmd in az jq; do
  if ! command -v "${_cmd}" >/dev/null 2>&1; then
	echo "!!! ERROR: '${_cmd}' not found. Aborting."
	exit 1
  fi
done

echo "=== Onboarding UA Edge Translator assets of device ${DEVICE_NAME}: $(date -Is) ==="

# --------------------------
# 1. Azure sign-in
# --------------------------
SP_HELPER_URL="https://raw.githubusercontent.com/digitaltwinconsortium/ManufacturingOntologies/main/Deployment/CreateRaspberryPiServicePrincipal.sh"
sp_instructions() {
  echo "    Run this script in Azure Cloud Shell (https://shell.azure.com) instead, or create a service principal"
  echo "    there and run the command it prints on the Pi:"
  echo "      curl -fsSL ${SP_HELPER_URL} | PI_SCRIPT=OnboardUAEdgeTranslatorAsset.sh bash -s -- ${RESOURCE_GROUP} ${SUBSCRIPTION_ID}"
}
group_readable() {
  az group show --name "${RESOURCE_GROUP}" ${SUBSCRIPTION_ID:+--subscription "${SUBSCRIPTION_ID}"} --output none 2>/dev/null
}
if [ -n "${AZURE_CLIENT_ID:-}" ] && [ -n "${AZURE_TENANT_ID:-}" ]; then
  if [ -z "${AZURE_CLIENT_SECRET:-}" ]; then
	read -r -s -p "Client secret of service principal ${AZURE_CLIENT_ID}: " AZURE_CLIENT_SECRET </dev/tty 2>/dev/null || true
	echo
  fi
  echo ">>> az login --service-principal (client id ${AZURE_CLIENT_ID})"
  # A new service principal/secret can take a few minutes to replicate in Entra ID.
  login_ok=false
  for _i in $(seq 1 12); do
	if login_out="$(az login --service-principal --username "${AZURE_CLIENT_ID}" --password "${AZURE_CLIENT_SECRET:-}" \
		 --tenant "${AZURE_TENANT_ID}" --output none 2>&1)"; then
	  login_ok=true
	  break
	fi
	case "${login_out}" in
	  *AADSTS7000229*|*AADSTS700016*|*AADSTS7000215*) ;;
	  *) break ;;
	esac
	[ "${_i}" -lt 12 ] || break
	echo "    Entra ID has not replicated the service principal/secret yet; retrying in 15s (${_i}/11)..."
	sleep 15
  done
  if [ "${login_ok}" != "true" ]; then
	printf '%s\n' "${login_out}" | grep -E '^(ERROR|WARNING)' || printf '%s\n' "${login_out}"
	echo "!!! ERROR: service principal sign-in failed."
	sp_instructions
	exit 1
  fi
elif az account show >/dev/null 2>&1 && group_readable; then
  echo "Reusing the existing Azure CLI session ($(az account show --query user.name -o tsv 2>/dev/null))."
else
  echo "!!! ERROR: no valid Azure CLI session for resource group ${RESOURCE_GROUP} and no service principal given"
  echo "    (AZURE_CLIENT_ID/AZURE_TENANT_ID/AZURE_CLIENT_SECRET)."
  sp_instructions
  exit 1
fi
if [ -n "${SUBSCRIPTION_ID}" ]; then
  az account set --subscription "${SUBSCRIPTION_ID}" || exit 1
else
  SUBSCRIPTION_ID="$(az account show --query id -o tsv 2>/dev/null)"
fi
NS_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DeviceRegistry/namespaces/${AIO_NAMESPACE_NAME}"
echo "Subscription: ${SUBSCRIPTION_ID}  Device Registry namespace: ${AIO_NAMESPACE_NAME}"

# All items of a Device Registry collection ('assets' or 'discoveredAssets'), following nextLink.
list_adr() {
  local url="https://management.azure.com${NS_ID}/$1?api-version=${ADR_API_VERSION}" page
  while [ -n "${url}" ]; do
	if ! page="$(az rest --method get --url "${url}" -o json 2>&1)"; then
	  echo "${page}" >&2
	  return 1
	fi
	printf '%s' "${page}" | jq -c '.value[]?'
	url="$(printf '%s' "${page}" | jq -r '.nextLink // empty')"
  done
}

if ! ASSETS="$(list_adr assets | jq -sc --arg d "${DEVICE_NAME}" '[.[] | select(.properties.deviceRef.deviceName == $d)]')"; then
  echo "!!! ERROR: could not list the assets of Device Registry namespace ${AIO_NAMESPACE_NAME}. Aborting."
  exit 1
fi
DISCOVERED="$(list_adr discoveredAssets | jq -sc --arg d "${DEVICE_NAME}" '[.[] | select(.properties.deviceRef.deviceName == $d)]')" \
  || DISCOVERED='[]'

# --------------------------
# 2. Discovered assets and their import state
# --------------------------
echo
echo "=== Discovered assets of ${DEVICE_NAME} ==="
NOT_IMPORTED="$(jq -nr --argjson a "${ASSETS}" --argjson d "${DISCOVERED}" '
  ([$a[] | .properties.discoveredAssetRefs // [] | if type == "array" then .[] else . end]) as $refs
  | $d[] | .name as $n
  | "  \($n): " + (if ($refs | index($n)) then "imported" else "NOT IMPORTED yet" end)')"
if [ -n "${NOT_IMPORTED}" ]; then
  printf '%s\n' "${NOT_IMPORTED}"
else
  echo "  none (send a Thing Description with 'sudo aio-wot createAsset <td.jsonld>' on the Pi first;"
  echo "  discovered assets show up here a minute or two later)"
fi

# --------------------------
# 3. OPC UA PubSub metadata (AIO 2610: only published with opcUaConformance=true)
# --------------------------
echo
echo "=== OPC UA metadata of the imported assets of ${DEVICE_NAME} ==="
UPDATED=0
FAILED=0
while IFS=$'\t' read -r asset defaults; do
  [ -n "${asset}" ] || continue
  case "${asset}" in
	"${STATION}-${SITE}-"*) ;;
	*) echo "!!! WARNING: '${asset}' does not start with '${STATION}-${SITE}-'; ADX/Fabric/Databricks derive"
	   echo "    Workcell/Site from the first two '-' separated parts of the asset name." ;;
  esac
  enabled="$(printf '%s' "${defaults}" | jq -Rr 'try (fromjson | .opcUaConformance == true) catch false' 2>/dev/null)"
  if [ "${enabled}" = "true" ] && [ "${REFRESH}" != "true" ]; then
	echo "  ${asset}: already enabled"
	continue
  fi
  new_defaults="$(printf '%s' "${defaults}" \
	| jq -Rsc '(try fromjson catch {}) // {} | if type == "object" then . else {} end
		| .opcUaConformance = true | tojson' 2>/dev/null)"
  [ -n "${new_defaults}" ] || new_defaults='"{\"opcUaConformance\":true}"'
  # Changing the description as well makes the connector re-publish the metadata.
  if az resource update --ids "${NS_ID}/assets/${asset}" \
	   --set "properties.defaultDatasetsConfiguration=${new_defaults}" \
			 "properties.description=UA Edge Translator (site ${SITE}), metadata refresh at $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	   --output none; then
	echo "  ${asset}: enabled"
	UPDATED=$((UPDATED + 1))
  else
	echo "!!! WARNING: could not update ${asset}."
	FAILED=$((FAILED + 1))
  fi
done < <(printf '%s' "${ASSETS}" | jq -r '.[] | [.name, (.properties.defaultDatasetsConfiguration // "")] | @tsv')
if [ "$(printf '%s' "${ASSETS}" | jq 'length')" -eq 0 ]; then
  echo "  no imported asset yet: import the discovered asset in the operations experience, then re-run this script."
fi

echo
echo "=== Done: ${UPDATED} asset(s) updated, ${FAILED} failed ==="
if [ "${UPDATED}" -gt 0 ]; then
  cat <<'EOF'
The metadata reaches ADX/Fabric/Databricks about a minute after the asset update has synced to the edge.
Check on the Pi:
  kubectl exec mqtt-client -n azure-iot-operations -- sh -c 'mosquitto_sub --host aio-broker --port 18883 \
	-t "azure-iot-operations/metadata/#" -V mqttv5 -F "%t" -C 20 -W 120 --cafile /var/run/certs/ca.crt \
	-D CONNECT authentication-method K8S-SAT -D CONNECT authentication-data "$(cat /var/run/secrets/tokens/broker-sat)"'
EOF
fi
[ "${FAILED}" -eq 0 ]
}

main "$@"
