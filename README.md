# OPC UA Reference Solution

> [!NOTE]
> This article is the **Microsoft OPC UA reference solution**, which uses **IEC 62541 standard OPC UA PubSub** to send telemetry data from the edge to the cloud. It is **different** from other telemetry configurations of Azure IoT Operations, since Azure IoT Operations also caters for scenarions where no OPC UA-enabled telemetry sources are involved, i.e. OPC UA PubSub is **not required** between Azure IoT Operations and cloud endpoints. The Azure IoT Operations architecture is described in the [**Azure IoT Operations Overview**](https://learn.microsoft.com/en-us/azure/iot-operations/overview-iot-operations#architecture-overview).

## About this solution

Manufacturers want to use an industrial IoT solution that doesn't lock them in to walled-garden ecosystems. In addition, they want to deploy this solution on a global scale and connect all of their production sites to it to increase efficiencies for each individual site.

These increased efficiencies lead to faster production, better quality and lower energy consumption, which all lead to lowering the cost for the produced goods.

The solution must be as efficient as possible and enable all required use cases such as condition monitoring, overall equipment effectiveness (OEE) calculation, forecasting, and anomaly detection. By using the insights gained from these use cases, manufacturers can then create digital feedback loops, which can apply optimizations and other changes to the production processes fully automatically.

Interoperability is the key enabler for these requirements. The use of open standards such as OPC UA significantly helps to achieve this interoperability, which lead to the establishment of the [OPC Foundation Cloud Initiative](https://opcfoundation.org/cloud). This OPC UA reference solution is Microsoft's implementation of the Cloud Initiative's reference architecture.

## Prerequisites

This reference solution deploys Azure Arc, which requires the `custom-locations` application object ID that needs to be passed to the deployment script. You can retrieve it with the following Azure CLI commands:

```azurecli
az login --tenant <tenant_id>
az account set --subscription <subscription_id>
az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv
```

The reference solution also deploys Azure IoT Operations, which requires the following resource providers to be registered in the subscription. Registering a resource provider is a subscription-scope action, so it must be done once by a subscription Owner or Contributor before deployment. You can do so via the following Azure CLI commands:

```azurecli
az provider register --namespace Microsoft.ExtendedLocation
az provider register --namespace Microsoft.Kubernetes
az provider register --namespace Microsoft.KubernetesConfiguration
az provider register --namespace Microsoft.IoTOperations
az provider register --namespace Microsoft.DeviceRegistry
az provider register --namespace Microsoft.SecretSyncController
```

## Postrequisites

The reference solution also deploys the Azure IoT Schema Registry, which requires the **IoT Operations Arc extension** service principal to be granted the **Azure Device Registry Administrator** role. This role assignment is **optional for this reference solution**, as the schema registry is only used by Azure IoT Operations data flows for schema-based serialization (Parquet/Delta) to storage destinations such as Azure Data Lake Storage or direct connections to Microsoft Fabric OneLake.

The deployment script logs a warning containing the extension service principal's object id. Retrieve it from the deployment (bootstrap) log on the simulation VM via SSH:

```bash
sudo grep -oP "IoT Operations arc extension' service principal '\K[0-9a-fA-F-]{36}" /var/log/bootstrap/Bootstrap.log
```

A subscription Owner or User Access Administrator must then create the role assignment **after** the deployment completes, replacing `<extension_principal_id>` with the id printed above and `<subscription_id>`, `<resource_group>` and `<resources_name>` (the `resourcesName` deployment parameter in lowercase) with your values. Do so via the following Azure CLI command:

```azurecli
az role assignment create --assignee-object-id <extension_principal_id> --assignee-principal-type ServicePrincipal --role "Azure Device Registry Administrator" --scope /subscriptions/<subscription_id>/resourceGroups/<resource_group>/providers/Microsoft.DeviceRegistry/schemaRegistries/<resources_name>-schemaregistry
```

## Articles in this reference solution

The following articles describe how to deploy this reference solution as well as how to connect it to various Microsoft services:

- [Connect Azure Data Explorer to the reference solution](adx.md) describes the end-to-end industrial IoT reference solution that uses Azure Data Explorer to store and analyze OPC UA telemetry for use cases such as condition monitoring, OEE calculation, and anomaly detection.
- [Connect Azure Databricks to the reference solution](databricks.md) walks through storing and analyzing OPC UA PubSub telemetry in Azure Databricks using Delta Lake tables and Structured Streaming ingestion from Azure Event Hubs.
- [Connect Microsoft Fabric to the reference solution](fabric.md) explains how to ingest and process the reference solution's OPC UA PubSub data in a Microsoft Fabric Eventhouse for Real-Time Intelligence, mirroring the same tables, functions, and views used by Azure Data Explorer.
- [Connect Microsoft Power BI to the reference solution](powerbi.md) describes how to connect Microsoft Power BI to the reference solution's OPC UA PubSub data.
- [Connect Azure Managed Grafana to the reference solution](grafana.md) describes how to connect Azure Managed Grafana to the reference solution's OPC UA PubSub data.
- [Connect Microsoft Dynamics 365 Field Service to the reference solution](fieldservice.md) describes how to connect Microsoft Dynamics 365 Field Service to the reference solution's OPC UA PubSub data.
- [Connect SAP to the reference solution](https://learn.microsoft.com/en-us/azure/architecture/guide/iot/howto-connect-on-premises-sap-to-azure) describes how to connect SAP to the reference solution.
- [Connect an industrial data space to the reference solution](https://learn.microsoft.com/en-us/azure/architecture/guide/iot/howto-iot-industrial-dataspaces) describes how to connect an industrial data space to the reference solution.
- [Import OPC UA Information Models from the UA Cloud Library into Azure services](cloudlib.md) describes how to import standardized OPC UA information models from the OPC Foundation's UA Cloud Library into Azure services.

## Production line simulation

The production line simulation is made up of several stations, using the station OPC UA information model, and a simple manufacturing execution system (MES). Both the stations and the MES are containerized for easy deployment. Their configuration is:

| Production Line | Ideal Cycle Time (in seconds) |
| --- | --- |
| Munich | 6 |
| Seattle | 10 |

| Shift Name | Start | End |
| --- | --- | --- |
| Morning | 07:00 | 14:00 |
| Afternoon | 15:00 | 22:00 |
| Night | 23:00 | 06:00 |

Shift times are in local time zone of Seattle and Munich. There are 1 hour breaks between shifts.

The station OPC UA server uses the following OPC UA node IDs for telemetry to the cloud:

- `i=379` - manufactured product serial number
- `i=385` - number of manufactured products
- `i=391` - number of discarded products
- `i=398` - running time
- `i=399` - faulty time
- `i=400` - status (0=station ready to do work, 1=work in progress, 2=work done and good part manufactured, 3=work done and scrap manufactured, 4=station in fault state)
- `i=406` - energy consumption
- `i=412` - ideal cycle time
- `i=418` - actual cycle time
- `i=434` - pressure

The solution uses a digital feedback loop to manage the pressure in a simulated station. To implement the feedback loop, the solution triggers a command from the cloud on one of the OPC UA servers in the simulation. The trigger activates when simulated time-series pressure data reaches a certain threshold. You can see the pressure of the assembly machine in the Azure Data Explorer dashboard. The pressure is released at regular intervals for the Seattle production line. In a real-world deployment, something as critical as opening a pressure relief valve would be done on-premises. This example simply demonstrates how to achieve the digital feedback loop.

## OPC UA certificate trust

The simulation stations accept anonymous/untrusted OPC UA sessions **only while they are in provisioning mode**, that is, until trust material is placed in their PKI stores (either through an OPC UA GDS push or through manual copying). After that, each station accepts a peer certificate only if it is present in the station's `pki/trusted/certs` store or is signed by an issuer in its `pki/issuer/certs` store. Azure IoT Operations' connector for OPC UA uses a self-signed application instance certificate, and each station in turn presents its own self-signed server certificate, so without extra configuration the two sides would **reject** each other once provisioned.

The deployment script establishes the required two-way (mutual) trust automatically, after Azure IoT Operations is installed:

1. **Stations trust AIO.** AIO's connector certificate is a self-signed, cert-manager-managed application instance certificate stored in the Kubernetes secret `aio-opc-opcuabroker-default-application-cert`.

   The script copies this certificate into each station's `pki/trusted/certs` store. The stations mount this store from the host (`/mnt/c/K3s/<Station>/<Line>/PKI`), and the certificate validator re-reads it on each validation, so no station restart is required.

2. **AIO trusts the stations.** The script enables Azure IoT Operations secret sync (reusing the solution's Key Vault and shared managed identity) and then adds each station's own OPC UA server certificate — for the Assembly, Test and Packaging stations of every production line.

   AIO stores this as the `aio-opc-ua-broker-trust-list` secret, synced from Key Vault.

> [!NOTE]
> This is the automated equivalent of the mutual-trust procedure in [Configure OPC UA certificates infrastructure for the connector for OPC UA](https://learn.microsoft.com/azure/iot-operations/discover-manage-assets/howto-configure-opc-ua-certificates-infrastructure).

## Access the Arc-enabled Kubernetes cluster from the Azure portal

When you browse the Kubernetes resources of the Arc-enabled cluster (or the Azure IoT Operations instance) in the Azure portal, you are prompted for a **service account bearer token**. Generate one by logging on to the deployed VM via SSH and then running the following commands:

```bash
# Create a service account (in the default namespace).
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml create serviceaccount arc-portal-user -n default

# Grant it cluster-admin so it can view all resources.
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml create clusterrolebinding arc-portal-user-binding --clusterrole cluster-admin --serviceaccount default:arc-portal-user

# Create a long-lived token secret for the service account.
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: arc-portal-user-secret
  annotations:
    kubernetes.io/service-account.name: arc-portal-user
type: kubernetes.io/service-account-token
EOF

# Print the token, then paste it into the portal's "Service account bearer token" prompt.
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get secret arc-portal-user-secret -o jsonpath='{$.data.token}' | base64 -d
```
