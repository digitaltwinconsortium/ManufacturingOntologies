#!/usr/bin/env bash
# CreateRaspberryPiServicePrincipal.sh - create the Azure sign-in that SetupAzureIoTOperationsPi.sh uses on
# the Raspberry Pi, and print the complete command to run on the Pi.
#
# Why: SetupAzureIoTOperationsPi.sh must sign in to Azure on the Pi. Its interactive fallback is the device
# code flow ('az login --use-device-code'), which many tenants block with a Conditional Access policy
# (sign-in error 53003, "Access has been blocked by Conditional Access policies"). This helper runs where
# you CAN sign in - Azure Cloud Shell (https://shell.azure.com, Bash) is easiest because it is already signed
# in, or any machine with a signed-in Azure CLI - and creates a service principal for the Pi instead:
#   - scoped to the deployment's resource group only (Owner, because the Pi setup creates role assignments
#     for Azure IoT Operations, the Key Vault and the workload-identity federation),
#   - with a short-lived client secret (default 30 days; re-run this helper to issue a new one),
#   - and it registers the subscription-level resource providers Azure IoT Operations needs (which a
#     resource-group-scoped service principal cannot do) and looks up the 'custom-locations' object ID
#     (which needs Microsoft Graph access the service principal does not have).
#
# Usage (Azure Cloud Shell, Bash):
#   curl -fsSL https://raw.githubusercontent.com/digitaltwinconsortium/ManufacturingOntologies/main/Deployment/CreateRaspberryPiServicePrincipal.sh | bash -s -- <resource-group> [subscription-id]
#
# Then copy the printed command into a terminal (or SSH session) on the Raspberry Pi.
#
# Requirements for the account running this helper: Owner (or User Access Administrator) on the resource
# group, permission to create app registrations in Microsoft Entra ID (allowed for all users by default;
# otherwise the 'Application Developer' role), and Contributor on the subscription to register providers.
#
# Optional environment overrides:
#   SP_NAME       Display name of the service principal (default: <resource-group>-pi-setup)
#   SECRET_DAYS   Lifetime of the client secret in days (default: 30)
#
# After the Pi setup completed and you no longer need to re-run it, delete the service principal with the
# 'az ad app delete' command printed at the end.

main() {

set -u
set -o pipefail

RESOURCE_GROUP="${1:-}"
SUBSCRIPTION_ID="${2:-}"
PI_SCRIPT_URL="https://raw.githubusercontent.com/digitaltwinconsortium/ManufacturingOntologies/main/Deployment/SetupAzureIoTOperationsPi.sh"
SP_NAME="${SP_NAME:-${RESOURCE_GROUP}-pi-setup}"
SECRET_DAYS="${SECRET_DAYS:-30}"
CUSTOM_LOCATIONS_APP_ID="bc313c14-388c-4e7d-a58e-70017303ee3b"
AIO_PROVIDERS="Microsoft.ExtendedLocation Microsoft.Kubernetes Microsoft.KubernetesConfiguration Microsoft.IoTOperations Microsoft.DeviceRegistry Microsoft.SecretSyncController"

if [ -z "${RESOURCE_GROUP}" ]; then
  echo "Usage: bash $0 <resource-group> [subscription-id]"
  echo "  <resource-group>  resource group the cloud deployment (arm.json, edgeDeploymentTarget=RaspberryPi) was deployed to"
  exit 1
fi
if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: the Azure CLI is required. Run this helper in Azure Cloud Shell (https://shell.azure.com)."
  exit 1
fi
if ! az account show >/dev/null 2>&1; then
  echo "ERROR: the Azure CLI is not signed in. Run 'az login' first (Azure Cloud Shell is already signed in)."
  exit 1
fi
if [ -n "${SUBSCRIPTION_ID}" ]; then
  if ! az account set --subscription "${SUBSCRIPTION_ID}"; then
	echo "ERROR: cannot select subscription ${SUBSCRIPTION_ID}."
	exit 1
  fi
else
  SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
fi
TENANT_ID="$(az account show --query tenantId -o tsv)"
echo "Subscription: $(az account show --query name -o tsv) (${SUBSCRIPTION_ID})"

RG_ID="$(az group show --name "${RESOURCE_GROUP}" --query id -o tsv 2>/dev/null)"
if [ -z "${RG_ID}" ]; then
  echo "ERROR: resource group '${RESOURCE_GROUP}' not found in subscription ${SUBSCRIPTION_ID}. Deploy"
  echo "       Deployment/arm.json with edgeDeploymentTarget=RaspberryPi to it first."
  exit 1
fi

echo
echo "=== Registering the resource providers Azure IoT Operations needs ==="
for rp in ${AIO_PROVIDERS}; do
  state="$(az provider show --namespace "${rp}" --query registrationState -o tsv 2>/dev/null)"
  if [ "${state}" = "Registered" ]; then
	echo "  ${rp}: Registered"
  elif az provider register --namespace "${rp}" --output none 2>/dev/null; then
	echo "  ${rp}: registration started"
  else
	echo "  WARNING: could not register ${rp}; ask a subscription Owner/Contributor to run:"
	echo "           az provider register --namespace ${rp} --subscription ${SUBSCRIPTION_ID}"
  fi
done

echo
echo "=== Looking up the 'custom-locations' application ==="
CUSTOM_LOCATIONS_OID="$(az ad sp show --id "${CUSTOM_LOCATIONS_APP_ID}" --query id -o tsv 2>/dev/null)"
if [ -n "${CUSTOM_LOCATIONS_OID}" ]; then
  echo "  object ID: ${CUSTOM_LOCATIONS_OID}"
else
  echo "  WARNING: could not read it from Microsoft Graph; the Pi setup falls back to the value passed to the"
  echo "           arm.json deployment (customLocationsOid)."
fi

echo
echo "=== Creating service principal '${SP_NAME}' (Owner on resource group ${RESOURCE_GROUP}) ==="
# Re-running patches the existing app registration and keeps the role assignment.
APP_ID="$(az ad sp create-for-rbac --name "${SP_NAME}" --role Owner --scopes "${RG_ID}" \
  --create-password false --query appId -o tsv)"
if [ -z "${APP_ID}" ]; then
  echo "ERROR: could not create the service principal. Your account needs permission to create app"
  echo "       registrations (or the 'Application Developer' role) and Owner on the resource group."
  exit 1
fi
END_DATE="$(date -u -d "+${SECRET_DAYS} days" +%Y-%m-%d 2>/dev/null || date -u -v+"${SECRET_DAYS}"d +%Y-%m-%d)"
# Overwrites any previous secret of this service principal, so only one short-lived secret ever exists.
CLIENT_SECRET="$(az ad app credential reset --id "${APP_ID}" --display-name "pi-setup" \
  --end-date "${END_DATE}" --query password -o tsv 2>/dev/null)"
if [ -z "${CLIENT_SECRET}" ]; then
  echo "ERROR: could not create a client secret for app ${APP_ID}."
  exit 1
fi
echo "  client ID: ${APP_ID}, secret valid until ${END_DATE}"

PI_ENV="AZURE_CLIENT_ID=${APP_ID} AZURE_TENANT_ID=${TENANT_ID} AZURE_CLIENT_SECRET='${CLIENT_SECRET}'"
[ -n "${CUSTOM_LOCATIONS_OID}" ] && PI_ENV="${PI_ENV} CUSTOM_LOCATIONS_OID=${CUSTOM_LOCATIONS_OID}"

echo
echo "=================================================================================================="
echo "Run this on the Raspberry Pi (it contains a secret - do not share it):"
echo
echo "curl -fsSL ${PI_SCRIPT_URL} | sudo ${PI_ENV} bash -s -- ${RESOURCE_GROUP} ${SUBSCRIPTION_ID}"
echo
echo "=================================================================================================="
echo "The service principal can sign in for ${SECRET_DAYS} days (re-run this helper for a new secret). The"
echo "role assignment and the new secret can take a minute to become effective. When you no longer need to"
echo "re-run the Pi setup, delete the service principal (Azure IoT Operations keeps working without it):"
echo "  az ad app delete --id ${APP_ID}"

}

main "$@"
