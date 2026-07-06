# Connect Azure IoT Operations to the Reference Solution

[Azure IoT Operations](https://learn.microsoft.com/en-us/azure/iot-operations/overview-iot-operations) is a unified data plane for the edge. It is a set of modular, scalable, and highly available data services that run on [Azure Arc-enabled](https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/overview) edge Kubernetes clusters. It lets you capture data from the shop floor via its built-in [connector for OPC UA](https://learn.microsoft.com/en-us/azure/iot-operations/discover-manage-assets/overview-opcua-broker), process it at the edge with data flows, and route it to the cloud.

This document describes how Azure IoT Operations (AIO) can be deployed, so AIO reads OPC UA telemetry from the simulated production lines and forwards it to the Azure Event Hubs namespace.

## Deploying

Azure IoT Operations is provisioned by the main `Deployment/arm.json` template. One parameter is required for it:

| Parameter | Type | Description |
| --- | --- | --- |
| `customLocationsOid` | string (required) | Object ID of the `custom-locations` Microsoft Entra application, needed to enable Arc custom locations. |

Because enabling the Arc `custom-locations` feature needs the `custom-locations` application object ID — you compute it once, up front, and pass it in:

```azurecli
export OBJECT_ID=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv)
```

Then deploy with the parameter set, for example:

```azurecli
az deployment group create \
  --resource-group <RESOURCE_GROUP> \
  --template-file Deployment/arm.json \
  --parameters resourcesName=<NAME> adminUsername=<USER> adminPassword=<PASSWORD> \
               customLocationsOid=$OBJECT_ID
```

> [!NOTE]
> Only **one** Azure IoT Operations instance is supported per resource group.

## OPC UA certificate mutual trust

The simulation stations accept anonymous/untrusted OPC UA sessions **only until UA Cloud Publisher (acting as the GDS) pushes a CA certificate to them via OPC UA Part 12 Server Push**. After that, each station accepts a client certificate only if its **issuer matches a certificate in the station's `pki/issuer/certs` store** (see the certificate validator in `Tools/FactorySimulation/Station/Program.cs`). AIO's connector for OPC UA uses a self-signed application instance certificate, so without extra configuration the stations would **reject** it once provisioned.

`Deployment/SetupAzureIoTOperations.sh` establishes the required two-way (mutual) trust automatically, after Azure IoT Operations is installed:

1. **Stations trust AIO.** AIO's connector certificate is a self-signed, cert-manager-managed application instance certificate stored in the Kubernetes secret `aio-opc-opcuabroker-default-application-cert` (namespace `azure-iot-operations`) — you **retrieve** it, you don't generate it.

   The script copies this certificate into each station pod's `/app/pki/issuer/certs` and `/app/pki/trusted/certs`.

2. **AIO trusts the stations.** The script adds all CA certificates found in the GDS Certificate Authority (CA) store to AIO's connector trust list.

   AIO stores this in the `aio-opc-ua-broker-trust-list` secret.

> [!NOTE]
> This is the automated equivalent of the mutual-trust procedure in [Configure OPC UA certificates infrastructure for the connector for OPC UA](https://learn.microsoft.com/azure/iot-operations/discover-manage-assets/howto-configure-opc-ua-certificates-infrastructure).
