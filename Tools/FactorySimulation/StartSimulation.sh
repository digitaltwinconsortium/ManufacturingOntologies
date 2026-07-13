#!/bin/bash

echo .
if [[ ! -n $1 ]];
then
    echo "No argument passed!"
    echo "Argument must be of the form: Endpoint=sb://[eventhubnamespace].servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=[key]"
    exit 1
else
    echo "Connection string received (redacted)."
fi

connectionstring=$1
tmp=${1#*//}   # remove prefix ending in "//"
name=${tmp%.servicebus*}   # remove suffix starting with ".servicebus"

echo .
echo Event Hubs name: $name

# Resolve paths relative to this script's own location, not the caller's working directory, so the
# relative "./PublisherConfig" and "../../Deployment" copies below work whether this script is run
# from its own folder (manual use) or invoked by Bootstrap.sh from a different directory.
cd "$(dirname "$0")" || exit 1

echo .
echo Copying config files...
mkdir -p /mnt/c/K3s
cp -r ./PublisherConfig /mnt/c/K3s
cp -r ../../Deployment /mnt/c/K3s

echo .
echo Configuring files...
cd /mnt/c/K3s/PublisherConfig/Munich
sed -i "s|myeventhubsnamespaceprimarykeyconnectionstring|$connectionstring|g" settings.json
sed -i "s|myeventhubsnamespace|$name|g" settings.json

cd /mnt/c/K3s/PublisherConfig/Seattle
sed -i "s|myeventhubsnamespaceprimarykeyconnectionstring|$connectionstring|g" settings.json
sed -i "s|myeventhubsnamespace|$name|g" settings.json

cd /mnt/c/K3s/Deployment/Munich
sed -i "s|myeventhubsnamespaceprimarykeyconnectionstring|$connectionstring|g" ProductionLine.yaml
sed -i "s|myeventhubsnamespace|$name|g" ProductionLine.yaml

cd /mnt/c/K3s/Deployment/Seattle
sed -i "s|myeventhubsnamespaceprimarykeyconnectionstring|$connectionstring|g" ProductionLine.yaml
sed -i "s|myeventhubsnamespace|$name|g" ProductionLine.yaml

# --------------------------------------------------------------------------------------------------
# ADX endpoint for UA-CloudAction (edge): substitute the Azure Data Explorer cluster URI into both
# ProductionLine.yaml files. UA-CloudAction reads the simulated pressure telemetry from ADX. It
# authenticates using Microsoft Entra Workload Identity (see below and SetupAzureIoTOperations.sh) - the
# shared '<rg>-Identity' managed identity already has ADX access, so no service principal or secret is
# needed. The ADX cluster + resource group are auto-derived from the authenticated az CLI (the only Kusto
# cluster in the subscription); override with ADX_CLUSTER_NAME / ADX_RESOURCE_GROUP / ADX_CLUSTER_URI.
if [[ -z "${ADX_CLUSTER_NAME}" || -z "${ADX_RESOURCE_GROUP}" ]]; then
    adx_lookup="$(az kusto cluster list --query "[0].{name:name, rg:resourceGroup}" -o tsv 2>/dev/null)"
    if [[ -n "${adx_lookup}" ]]; then
        ADX_CLUSTER_NAME="${ADX_CLUSTER_NAME:-$(echo "${adx_lookup}" | awk '{print $1}')}"
        ADX_RESOURCE_GROUP="${ADX_RESOURCE_GROUP:-$(echo "${adx_lookup}" | awk '{print $2}')}"
    fi
fi
adx_cluster_uri="${ADX_CLUSTER_URI}"
if [[ -z "${adx_cluster_uri}" && -n "${ADX_CLUSTER_NAME}" && -n "${ADX_RESOURCE_GROUP}" ]]; then
    adx_cluster_uri="$(az kusto cluster show --name "${ADX_CLUSTER_NAME}" --resource-group "${ADX_RESOURCE_GROUP}" --query uri -o tsv 2>/dev/null)"
fi
if [[ -n "${adx_cluster_uri}" ]]; then
    for line_dir in /mnt/c/K3s/Deployment/Munich /mnt/c/K3s/Deployment/Seattle; do
        cd "${line_dir}"
        sed -i "s|https://myadxcluster.myregion.kusto.windows.net|${adx_cluster_uri}|g" ProductionLine.yaml
    done
    echo "Set UA-CloudAction ADX cluster URI to ${adx_cluster_uri}."
else
    echo "Warning: could not derive the ADX cluster URI; the ADX_INSTANCE_URL placeholder in"
    echo "ProductionLine.yaml keeps its default (set ADX_CLUSTER_URI to override)."
fi

# --------------------------------------------------------------------------------------------------
# ADX access via Microsoft Entra Workload Identity: substitute the shared managed identity's client id
# into the ua-cloud-action service-account annotation in both ProductionLine.yaml files.
# SetupAzureIoTOperations.sh then federates that identity with the service account so UA-CloudAction
# queries ADX with a federated token (no secret). Derive the client id from the '<rg>-Identity' identity;
# override with UA_CLOUD_ACTION_MI_CLIENT_ID if needed.
mi_client_id="${UA_CLOUD_ACTION_MI_CLIENT_ID}"
if [[ -z "${mi_client_id}" ]]; then
    mi_client_id="$(az identity list --query "[?ends_with(name,'-Identity')].clientId | [0]" -o tsv 2>/dev/null)"
fi
if [[ -n "${mi_client_id}" ]]; then
    for line_dir in /mnt/c/K3s/Deployment/Munich /mnt/c/K3s/Deployment/Seattle; do
        cd "${line_dir}"
        sed -i "s|myManagedIdentityClientId|${mi_client_id}|g" ProductionLine.yaml
    done
    echo "Set UA-CloudAction workload-identity client id to ${mi_client_id}."
else
    echo "Warning: could not derive the '<rg>-Identity' managed identity client id; the workload-identity"
    echo "annotation in ProductionLine.yaml keeps its placeholder (set UA_CLOUD_ACTION_MI_CLIENT_ID to override)."
fi

echo .
echo Starting Munich production line...
cd /mnt/c/K3s/Deployment/Munich
kubectl apply -f ProductionLine.yaml

echo Waiting for production lines to be started, please be patient...
sleep 30

echo Starting UA-CloudPublisher...
kubectl apply -f UA-CloudPublisher.yaml

echo .
echo Starting Seattle production line...
cd /mnt/c/K3s/Deployment/Seattle
kubectl apply -f ProductionLine.yaml

echo Waiting for production lines to be started, please be patient...
sleep 30

echo Starting UA-CloudPublisher...
kubectl apply -f UA-CloudPublisher.yaml

echo .
echo Production lines started.
exit 0
