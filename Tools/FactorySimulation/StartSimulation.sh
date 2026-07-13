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
# ADX access for UA-CloudAction (edge): create a dedicated Entra service principal and grant it Viewer
# on the 'ontologies' ADX database, then substitute its credentials into the ProductionLine.yaml files.
# UA-CloudAction authenticates to ADX with APPLICATION_ID + APPLICATION_KEY + AAD_TENANT_ID (see
# ActionProcessor.cs -> WithAadApplicationKeyAuthentication). This step is skipped unless the ADX cluster
# is identified via environment variables:
#   ADX_CLUSTER_NAME, ADX_RESOURCE_GROUP  (required to provision)
#   ADX_CLUSTER_URI                        (optional; else derived from cluster properties)
#   ADX_DATABASE_NAME                      (optional; defaults to 'ontologies')
#   UA_CLOUD_ACTION_SP_NAME                (optional; defaults to 'ua-cloud-action-adx')
# Requires an authenticated az CLI (the Bootstrap VM's managed identity or an interactive login) with
# rights to create the app registration and assign the ADX database principal.
adx_db_name="${ADX_DATABASE_NAME:-ontologies}"
sp_display_name="${UA_CLOUD_ACTION_SP_NAME:-ua-cloud-action-adx}"
if [[ -n "${ADX_CLUSTER_NAME}" && -n "${ADX_RESOURCE_GROUP}" ]]; then
    echo .
    echo "Provisioning ADX service principal '${sp_display_name}' for UA-CloudAction..."

    tenant_id="$(az account show --query tenantId -o tsv 2>/dev/null)"
    adx_cluster_uri="${ADX_CLUSTER_URI}"
    if [[ -z "${adx_cluster_uri}" ]]; then
        adx_cluster_uri="$(az kusto cluster show --name "${ADX_CLUSTER_NAME}" --resource-group "${ADX_RESOURCE_GROUP}" --query uri -o tsv 2>/dev/null)"
    fi

    # Create the app registration if it does not already exist, then ensure a service principal + secret.
    app_id="$(az ad app list --display-name "${sp_display_name}" --query "[0].appId" -o tsv 2>/dev/null)"
    if [[ -z "${app_id}" ]]; then
        app_id="$(az ad app create --display-name "${sp_display_name}" --query appId -o tsv)"
    fi
    az ad sp show --id "${app_id}" >/dev/null 2>&1 || az ad sp create --id "${app_id}" >/dev/null
    sp_object_id="$(az ad sp show --id "${app_id}" --query id -o tsv)"
    app_secret="$(az ad app credential reset --id "${app_id}" --display-name ua-cloud-action --years 1 --query password -o tsv)"

    # Grant the service principal Viewer on the ADX database (read-only query access is sufficient).
    az kusto database-principal-assignment create \
        --cluster-name "${ADX_CLUSTER_NAME}" \
        --resource-group "${ADX_RESOURCE_GROUP}" \
        --database-name "${adx_db_name}" \
        --principal-assignment-name "ua-cloud-action-viewer" \
        --principal-id "${app_id}" \
        --principal-type "App" \
        --role "Viewer" \
        --tenant-id "${tenant_id}" >/dev/null 2>&1 || echo "  warning: could not assign ADX Viewer role (assign it manually if needed)."

    # Substitute the ADX service-principal credentials into both ProductionLine.yaml files.
    for line_dir in /mnt/c/K3s/Deployment/Munich /mnt/c/K3s/Deployment/Seattle; do
        cd "${line_dir}"
        sed -i "s|https://myadxcluster.myregion.kusto.windows.net|${adx_cluster_uri}|g" ProductionLine.yaml
        sed -i "s|myAppRegistrationClientId|${app_id}|g" ProductionLine.yaml
        sed -i "s|myAppRegistrationClientSecret|${app_secret}|g" ProductionLine.yaml
        sed -i "s|myTenantId|${tenant_id}|g" ProductionLine.yaml
    done
    echo "ADX service principal ${app_id} granted Viewer on database '${adx_db_name}'."
else
    echo .
    echo "Skipping ADX service principal provisioning (set ADX_CLUSTER_NAME and ADX_RESOURCE_GROUP to enable);"
    echo "UA-CloudAction ADX placeholders in ProductionLine.yaml must then be filled in manually."
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
