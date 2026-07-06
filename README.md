# Manufacturing Ontologies

## Introduction

An ontology defines the language used to describe a system. In the manufacturing domain, these systems can represent a factory or plant but also enterprise applications or supply chains. There are several established ontologies in the manufacturing domain. Most of them have long been standardized. In this repository, we have focused on ISA95 to describe a factory ontology. The ontologies are available [here](https://github.com/digitaltwinconsortium/ManufacturingOntologies/tree/main/Ontologies).

> [!NOTE]
> This article is the **Microsoft OPC UA Reference Solution**, which uses **IEC 62541 standard OPC UA PubSub** to send telemetry data from the edge to the cloud. It is **different** from the default telemetry configuration of Azure IoT Operations, which also caters for scenarions where no OPC UA-enabled telemetry sources are involved, i.e. OPC UA PubSub is **not required** between Azure IoT Operations and cloud endpoints. The Azure IoT Operations architecture is described at [**Azure IoT Operations Overview**](https://learn.microsoft.com/en-us/azure/iot-operations/overview-iot-operations#architecture-overview).

## About this OPC UA reference solution

Manufacturers want to use an industrial IoT solution that doesn't lock them in to walled-garden ecosystems. In addition, they want to deploy this solution on a global scale and connect all of their production sites to it to increase efficiencies for each individual site.

These increased efficiencies lead to faster production, better quality and lower energy consumption, which all lead to lowering the cost for the produced goods.

The solution must be as efficient as possible and enable all required use cases such as condition monitoring, overall equipment effectiveness (OEE) calculation, forecasting, and anomaly detection. By using the insights gained from these use cases, manufacturers can then create digital feedback loops, which can apply optimizations and other changes to the production processes fully automatically.

Interoperability is the key enabler for these requirements. The use of open standards such as OPC UA significantly helps to achieve this interoperability, which lead to the establishment of the [OPC Foundation Cloud Initiative](https://opcfoundation.org/cloud). This OPC UA Reference Solution is Microsoft's implementation of the Cloud Initiative's reference architecture.

## Prerequisites

This reference solution uses Azure Arc. It needs the `custom-locations` application object ID that needs to be passed to the deployment script. You can retrieve it with the following command:

```azurecli
az login --tenant <tenant_id>
az account set --subscription <subscription_id>
az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv
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

The simulation stations accept anonymous/untrusted OPC UA sessions **only until a CA certificate is pushed to them via OPC UA Part 12 Server Push**. After that, each station accepts a client certificate only if its **issuer matches a certificate in the station's `pki/issuer/certs` store**. Azure IoT Operation's connector for OPC UA uses a self-signed application instance certificate, so without extra configuration the stations would **reject** it once provisioned.

The deployment script establishes the required two-way (mutual) trust automatically, after Azure IoT Operations is installed:

1. **Stations trust AIO.** AIO's connector certificate is a self-signed, cert-manager-managed application instance certificate stored in the Kubernetes secret `aio-opc-opcuabroker-default-application-cert` (namespace `azure-iot-operations`) — you **retrieve** it, you don't generate it.

   The script copies this certificate into each station's issuer certs and trusted certs store.

2. **AIO trusts the stations.** The script adds all CA certificates found in the GDS Certificate Authority (CA) store to AIO's connector trust list.

   AIO stores this in the `aio-opc-ua-broker-trust-list` secret.

> [!NOTE]
> This is the automated equivalent of the mutual-trust procedure in [Configure OPC UA certificates infrastructure for the connector for OPC UA](https://learn.microsoft.com/azure/iot-operations/discover-manage-assets/howto-configure-opc-ua-certificates-infrastructure).

## W3C Web of Things

The ontologies defined in this repository are described by leveraging the W3C Web of Things (WoT), which is specified [here](https://www.w3.org/TR/wot-thing-description/). They were generated by an open-source DTDL-WoT conversion tool available [here](https://github.com/web-of-things-open-source/wot-dtdl-converter). A comparison between DTDL and WoT and how the two specs interoperate is described [here](https://github.com/digitaltwinconsortium/ManufacturingOntologies/blob/master/comparison.md).

## International Society of Automation 95 (ISA95/IEC 62264)

ISA95 / IEC 62264 is the manufacturing ontology leveraged by this solution. It is a standard and described [here](https://en.wikipedia.org/wiki/ANSI/ISA-95) and [here](https://en.wikipedia.org/wiki/IEC_62264). The OPC UA Companion Specification for it is available [here](https://github.com/OPCFoundation/UA-Nodeset/tree/latest/ISA-95) and [here](https://github.com/OPCFoundation/UA-Nodeset/tree/latest/ISA95-JOBCONTROL).

## License

<a rel="license" href="http://creativecommons.org/licenses/by/4.0/"><img alt="Creative Commons License" style="border-width:0" src="https://i.creativecommons.org/l/by/4.0/88x31.png" /></a>

This work is licensed under a <a rel="license" href="http://creativecommons.org/licenses/by/4.0/">Creative Commons Attribution 4.0 International License</a>.
