# Manufacturing Ontologies

## Introduction

An ontology defines the language used to describe a system. In the manufacturing domain, these systems can represent a factory or plant but also enterprise applications or supply chains. There are several established ontologies in the manufacturing domain. Most of them have long been standardized. In this repository, we have focused on two of these ontologies, namely ISA95 to describe a factory ontology and IEC 63278 Asset Administration Shell to describe a manufacturing supply chain. Furthermore, we have included a factory simulation and an end-to-end solution architecture for you to try out the ontologies, leveraging IEC 62541 OPC UA and the Microsoft Azure Cloud.

## Digital Twin Definition Language

The ontologies defined in this repository are described by leveraging the Digital Twin Definition Language (DTDL), which is specified [here](https://github.com/Azure/opendigitaltwins-dtdl/blob/master/DTDL/v2/dtdlv2.md).

## ISA95

The ISA95 standard is described [here](https://en.wikipedia.org/wiki/ANSI/ISA-95).

## IEC 63278 Asset Administration Shell (AAS)

The IEC 63278 Asset Administration Shell is described [here](https://www.plattform-i40.de/IP/Redaktion/EN/Standardartikel/specification-administrationshell.html).

## Overall Solution Architecture

<img src="Docs/architecture.png" alt="architecture" width="900" />

## IEC 62541 OPC UA Production Line Simulation

This repository also contains a production line simulation made up of several Stations, leveraging the machine information model described above, as well as a simple Manufacturing Execution System (MES). Both the Stations and the MES are containerized for easy deployment.

### UA Cloud Twin

The simulation makes use of the UA Cloud Twin also available from the Digital Twin Consortium [here](https://github.com/digitaltwinconsortium/UA-CloudTwin). It automatically detects OPC UA assets from the OPC UA telemetry messages sent to the cloud and registers ISA95-compatible digital twins in Azure Digital Twins service for you.

#### Mapping OPC UA Servers to the ISA95 Hierarchy Model

UA Cloud Twin takes the combination of the OPC UA Application URI and the OPC UA Namespace URIs discovered in the OPC UA telemetry stream and creates ISA95 Work Center assets for each one.

#### Mapping OPC UA PubSub Publishers to the ISA95 Hierarchy Model

UA Cloud Twin takes the OPC UA Publisher ID and creates ISA95 Area assets for each one.

#### Mapping OPC UA PubSub Datasets to the ISA95 Hierarchy Model

UA Cloud Twin takes each OPC UA Field discovered in the received Dataset metadata and creates an ISA95 Work Unit asset for each.

### Default Simulation Configuration

The simulation is configured to include 8 production lines by default and the configuration can be altered in the StartSimulation.cmd script. The default configuration is depicted below:

| Production Line | Ideal Cycle Time (in seconds) |
|:---------------:|:-----------------------------:|
| Munich | 6 |
| Capetown | 8 |
| Mumbai | 11 |
| Seattle |	6 |
| Beijing 1	| 9 |
| Beijing 2	| 8 |
| Beijing 3	| 4 |
| Rio |	10 |

### OPC UA Node IDs of Station OPC UA Server

The following OPC UA Node IDs are used in the Station OPC UA Server for telemetry to the cloud
* i=379 - manufactured product serial number
* i=385 - number of manufactured products
* i=391 - number of discarded products
* i=398 - running time
* i=399 - faulty time
* i=400 - status (0=station ready to do work, 1=work in progress, 2=work done and good part manufactured, 3=work done and scrap manufactured, 4=station in fault state)
* i=406 - energy consumption
* i=412 - ideal cycle time
* i=418 - actual cycle time
* i=434 - pressure

### Automatic Installation of Production Line Simulation and Cloud Services

Simply click on the button below:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2Fazure-quickstart-templates%2Fmaster%2Fquickstarts%2Fmicrosoft.storage%2Fstorage-account-create%2Fazuredeploy.json)

### Manual Installation Instructions

To install the production line simulation and cloud services manually, you need a Windows PC or virtual machine with at least *16GB of memory* as you will be deploying 30 Docker Containers. You will also need an Azure subscription you have admin access to or get a free Azure subscription from [here](https://azure.microsoft.com/en-us/free).

Follow these steps:

1. Deploy an S1 Azure IoT Hub with *2 scale units* into your Azure subscription. Once deployed, create 6 devices and call them publisher.munich.corp.contoso, publisher.capetown.corp.contoso, publisher.mumbai.corp.contoso, publisher.seattle.corp.contoso, publisher.beijing.corp.contoso and publisher.rio.corp.contoso.

2. Download and install Docker Desktop from [here](https://www.docker.com/products/docker-desktop), including the Windows Subsystem for Linux (WSL) integration. After installation and a required system restart, accept the license terms and install the WSL2 Linux kernel by following the instructions. Then verify that Docker Desktop is running in the Windows System Tray and enable Kubernetes in Settings.

3. Browse to [here](https://github.com/digitaltwinconsortium/ManufacturingOntologies) and select Code -> Download Zip. Unzip the contents to a directory of your choice.

4. Navigate to the OnPremAssets directory of the Zip you just downloaded and edit the settings.json file for each publisher directory located in the Config directory. Replace [myiothub] with the name of your IoT Hub and replace [publisherkey] with the primary key of the 6 IoT Hub publisher devices you have created earlier. This data can be accessed by clicking on the names of the devices in the Azure Portal.

5. Run the StartSimulation.cmd script from the OnPremAssets folder in a cmd prompt window. This will run the simulation. A total of 8 production lines will be started, each with 3 stations each (assembly, test and packaging) as well as an MES per line and a UA Cloud Publisher instance per factory location. There are 6 locations in total: Munich, Capetown, Mumbai, Seattle, Beijing and Rio. Then check your IoT Hub in the Azure Portal to verify that OPC UA telemetry is flowing to the cloud.

6. Deploy an Azure Digital Twins service and check the "Assign Azure Digital Twins Data Owner role" checkbox during deployment.

7. Deploy an Azure Web App service and select "Docker Container" for the Publish setting, "Linux" for the Operating System setting and then under the Docker tab, select "Single Container" for the options setting, "Private Registry" for the Image Source setting, "https://ghcr.io/" for the Server URL setting and finally "digitaltwinconsortium/ua-cloudtwin:main" for the Image and tag setting. Once deployed, enable the System assigned Identity and under Access Control -> Role Assignments of your Azure Digital Twin service instance, add a new Role Assignment of type "Azire Digital Twins Data Owner", assign it's access to "Managed Identity" and under "Select Users", select your previously deployed Azure Web App service instance.

8. Open the URL of your Azure Web App service in a browser and fill in the two fields under Setup and click Connect. The Azure Event Hub connection string can be read for Azure IoT Hub under "Built-in Endpoints"->"Event Hub-compatible endpoint" in the Azure Portal.

Please note: If you update your Docker Desktop runtime environment, you will need to stop and restart the simulation!

### Next Steps

If you want to store the OPC UA PubSub telemetry data in a time-series database and do further analysis on it, you can deploy an instance of Azure Data Explorer (ADX) from the Azure Portal and connect it directly to your IoT Hub by following the steps in the lower half of the article from [here](https://www.linkedin.com/pulse/using-azure-data-explorer-opc-ua-erich-barnstedt/). Then, import the Station nodeset file into your ADX instance, using the UA Cloud Nodeset Viewer tool also located in the Digital Twin Consortium's GitHub [here](https://github.com/digitaltwinconsortium/UANodesetWebViewer). Once you do that, you can e.g. calculate the OEE using the ADX queries found [here](https://github.com/digitaltwinconsortium/ManufacturingDTDLOntologies/tree/main/ADXQueries).

Also, if you want to test a "digital feedback loop", i.e. triggering a command on one of the OPC UA servers in the simulation from the cloud, based on a time-series reaching a certain threshold (the simulated pressure), then configure and run the StartUACloudCommander.bat file and deploy the PressureRelief Azure Function in your Azure subscription and create an application registration for your ADX instance as described [here](https://docs.microsoft.com/en-us/azure/data-explorer/provision-azure-ad-app). You also need to define the following environment variables in the Azure portal for the Function:
* ADX_INSTANCE_URL
* ADX_DB_NAME
* AAD_TENANT_ID
* APPLICATION_KEY
* APPLICATION_ID
* IOT_HUB_NAME
* IOT_HUB_KEY
* UACOMMANDER_NAME
* UA_SERVER_ENDPOINT
* UA_SERVER_METHOD_ID
* UA_SERVER_OBJECT_ID
* UA_SERVER_DNS_NAME

## License

<a rel="license" href="http://creativecommons.org/licenses/by/4.0/"><img alt="Creative Commons License" style="border-width:0" src="https://i.creativecommons.org/l/by/4.0/88x31.png" /></a>

This work is licensed under a <a rel="license" href="http://creativecommons.org/licenses/by/4.0/">Creative Commons Attribution 4.0 International License</a>.
