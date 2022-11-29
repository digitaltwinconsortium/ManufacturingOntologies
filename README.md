# Manufacturing Ontologies

## Introduction

An ontology defines the language used to describe a system. In the manufacturing domain, these systems can represent a factory or plant but also enterprise applications or supply chains. There are several established ontologies in the manufacturing domain. Most of them have long been standardized. In this repository, we have focused on two of these ontologies, namely ISA95 to describe a factory ontology and IEC 63278 Asset Administration Shell to describe a manufacturing supply chain. Furthermore, we have included a factory simulation and an end-to-end solution architecture for you to try out the ontologies, leveraging IEC 62541 OPC UA and the Microsoft Azure Cloud.

## Digital Twin Definition Language

The ontologies defined in this repository are described by leveraging the Digital Twin Definition Language (DTDL), which is specified [here](https://github.com/Azure/opendigitaltwins-dtdl/blob/master/DTDL/v2/dtdlv2.md).

## International Society of Automation 95 (ISA95)

The ISA95 standard is described [here](https://en.wikipedia.org/wiki/ANSI/ISA-95).

## IEC 63278 Asset Administration Shell (AAS)

The IEC 63278 Asset Administration Shell is described [here](https://www.plattform-i40.de/IP/Redaktion/EN/Standardartikel/specification-administrationshell.html).

## IEC 62541 Open Platform Communications Unified Architecture (OPC UA)

IEC 62541 Open Platform Communications Unified Architecture (OPC UA) is described [here](https://opcfoundation.org). 

## Overall Solution Architecture

<img src="Docs/architecture.png" alt="architecture" width="900" />

## Production Line Simulation

This repository also contains a production line simulation made up of several Stations, leveraging the machine information model described above, as well as a simple Manufacturing Execution System (MES). Both the Stations and the MES are containerized for easy deployment.

### UA Cloud Twin

The simulation makes use of the UA Cloud Twin also available from the Digital Twin Consortium [here](https://github.com/digitaltwinconsortium/UA-CloudTwin). It automatically detects OPC UA assets from the OPC UA telemetry messages sent to the cloud and registers ISA95-compatible digital twins in Azure Digital Twins service for you.

<img src="Docs/twingraph.png" alt="twingraph" width="900" />

#### Mapping OPC UA Servers to the ISA95 Hierarchy Model

UA Cloud Twin takes the combination of the OPC UA Application URI and the OPC UA Namespace URIs discovered in the OPC UA telemetry stream (specifically, in the OPC UA PubSub metadata messages) and creates ISA95 Work Center assets for each one. UA Cloud Publisher sends the OPC UA PubSub metadata messages to a seperate broker topic to make sure all metadata can be read by UA Cloud Twin before the processing of the telemetry messags starts.

#### Mapping OPC UA PubSub Publishers to the ISA95 Hierarchy Model

UA Cloud Twin takes the OPC UA Publisher ID and creates ISA95 Area assets for each one.

#### Mapping OPC UA PubSub Datasets to the ISA95 Hierarchy Model

UA Cloud Twin takes each OPC UA Field discovered in the received Dataset metadata and creates an ISA95 Work Unit asset for each.

### Default Simulation Configuration

The simulation is configured to include 8 production lines. The default configuration is depicted below:

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

### Preparing for the Installation of the Production Line Simulation

The production line simulation runs on an on-prem, single-node Kubernetes cluster, provided by Docker Desktop ontop of a Windows Virtual Machine. The Kubernetes cluster is managed from the cloud via Azure Arc. Azure Arc requires a key pair (public and private) to operate. Create the required key pair via the [Azure Cloud Shell](https://shell.azure.com)'s `ssh-keygen` command:

    ssh-keygen -t rsa -b 4096

Note: The first time you start the Azure Cloud Shell, you will be prompted to setup Azure Storage. Simply click on Create Storage.

Note: By default, the public and private key files are created in the ~/.ssh directory. Running the ssh-keygen command will overwrite any SSH key pair with the same name already existing in the given location.

Then, display the public key and copy everything past `ssh-rsa ` up to and including `==`. You will need it later when deploying the Azure resources:

    more ~/.ssh/id_rsa.pub

Note: If you need to access the keys at a later date, you can simply click on the Azure Cloud Shell icon in the top-right-hand corner of the Azure Portal to open the Azure Chould Shell again.

### Installation of Production Line Simulation and Cloud Services

Clicking on the button below will **deploy** all required resources (on Microsoft Azure):

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fdigitaltwinconsortium%2FManufacturingOntologies%2Fmain%2FDeployment%2Farm.json)

You can also **visualize** the resources that will get deployed by clicking the button below:

<a href="http://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2Fdigitaltwinconsortium%2FManufacturingOntologies%2Fmain%2FDeployment%2Farm.json" data-linktype="external"><img src="https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg?sanitize=true" alt="Visualize" data-linktype="external"></a>

Once the deployment is complete, log in to the deployed Windows VM via Remote Desktop (Connect -> Download RDP file in the Azure Portal), using the credentials you provided during deployment and download and **install Docker Desktop** from [here](https://www.docker.com/products/docker-desktop), including the Windows Subsystem for Linux (WSL) integration. After installation and a required system restart, accept the license terms and install the WSL2 Linux kernel by following the instructions. Then restart one more time, verify that Docker Desktop is running in the Windows System Tray and enable Kubernetes under Settings -> Kubernetes -> Enable Kubernetes -> Apply & restart.

<img src="Docs/Kubernetes.png" alt="Kubernetes" width="900" />

### Running the Production Line Simulation

On the deployed VM, download this repo from [here](https://github.com/digitaltwinconsortium/ManufacturingOntologies/archive/refs/heads/main.zip) and extract to a directory of your choice. Then navigate to the OnPremAssets directory of the unzipped content and run the **StartSimulation** command from the OnPremAssets folder in a command prompt by supplying the primary key connection string of your Event Hubs namespace and the Azure region you picked during deployment as parameters. The primary key connection string can be read in the Azure Portal under your Event Hubs' "share access policy" -> "RootManagedSharedAccessKey". The azure region needs to be specified as a DNS acronym as listed [here](https://learn.microsoft.com/en-us/azure/automation/how-to/automation-region-dns-records#dns-records-per-region), e.g. for Azure region East US 2 you would pass in eus2 as parameter:

    StartSimulation Endpoint=sb://ontologies.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=abcdefgh= eus2

Please note: The StartSimulation script will launch UA Cloud Twin as its last step. Please log in with the credentials you provided during the deployment and click Apply to apply the UA Cloud Twin configuration.

Please note: If you restart Docker Desktop at any time, you will need to stop and then restart the simulation, too!

### Next Steps

If you want to view the digital twins graph automatically created in the Azure Digital Twins service, assign yourself the Azure Digital Twins Data Owner role in the Azure Portal and open the Azure Digital Twins Explorer directly from the Azure Digital Twins overview page.

If you want to add a 3D viewer to the simulation, you can follow the steps to configure the 3D Scenes Studio outlined [here](https://learn.microsoft.com/en-us/azure/digital-twins/how-to-use-3d-scenes-studio) and map the 3D robot model from [here](https://cardboardresources.blob.core.windows.net/public/RobotArms.glb) to the digital twins automatically generated by the UA Cloud Twin:

<img src="Docs/3dviewer.png" alt="3dviewer" width="900" />

If you want to calculate OEE, add no-code dashboards or make predictions about the production, set up the [Data History](https://learn.microsoft.com/en-us/azure/digital-twins/concepts-data-history) feature in the Azure Digital Twins service to historize your contextualized OPC UA data to Azure Data Explorer deployed in this solution. You can find the wizard to set this up in the Azure Digital Twins service configuration in the Azure portal. 

If you want to test a "digital feedback loop", i.e. triggering a command on one of the OPC UA servers in the simulation from the cloud, based on a time-series reaching a certain threshold (the simulated pressure), then configure and run the StartUACloudCommander.bat file by providing the two environment variables (ENTER_EVENT_HUBS_HOSTNAME_HERE in the form "yourname-eventhubs.servicebus.windows.net" and ENTER_EVENT_HUBS_CONNECTION_STRING_HERE in the form "Endpoint=sb://yourname-eventhubs.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=abcdefgh=") in the batch file and deploy the PressureRelief Azure Function in your Azure subscription and create an application registration for your ADX instance as described [here](https://docs.microsoft.com/en-us/azure/data-explorer/provision-azure-ad-app). You also need to define the following environment variables in the Azure portal for the Function:

* ADX_INSTANCE_URL - the endpoint of your ADX cluster, e.g. https://ontologies.eastus2.kusto.windows.net/
* ADX_DB_NAME - the name of your ADX database
* AAD_TENANT_ID - the GUID of your AAD tenant of your Azure subscription
* APPLICATION_KEY - the secret you created during pressure relief function app registration
* APPLICATION_ID - the GUID assigned to the pressure relief function during app registration
* BROKERNAME - the name of your event hubs namespace, e.g. ontologies-eventhubs.servicebus.windows.net
* USERNAME - set to "$ConnectionString"
* PASSWORD - the primary key connection string of your event hubs namespace
* TOPIC - set to "commander.corp.contoso.command"
* RESPONSE_TOPIC - set to "commander.corp.contoso.reponse"
* UA_SERVER_ENDPOINT - set to "opc.tcp://assembly.seattle.corp.contoso/ua/seattle/" to open the pressure relief valve of the Seattle assembly machine
* UA_SERVER_METHOD_ID - set to "ns=2;i=435"
* UA_SERVER_OBJECT_ID - set to "ns=2;i=424"
* UA_SERVER_APPLICATION_NAME - set to "assembly"
* UA_SERVER_DNS_NAME - set to "seattle"

### Replacing the Production Line Simulation with a Real Production Line

Once you are ready to connect your own production line, simply delete the VM through the Azure Portal or, if you are running the simulation on a local PC, call the StopSimulation.cmd script. Then run UA Cloud Publisher on a Docker-enabled edge gateway PC (on Windows, for Linux, remove the "c:" bits) with the following command. The PC needs Internet access (via port 8883) and needs to be able to connect to your OPC UA-enabled machiens in your production line:

    docker run -itd -v c:/publisher/logs:/app/logs -v c:/publisher/settings:/app/settings -p 80:80 ghcr.io/barnstee/ua-cloudpublisher:main

In this case, UA Cloud Publisher stores its configuration and log files locally on the Edge PC under c:/publisher on Windows or /publisher on Linux.

Then, open a browser on the Edge PC and navigate to http://localhost. You are now connected to the UA Cloud Publisher's interactive UI. Select the Configuration menu item and enter the following information, replacing [myeventhubsnamespace] with the name of your Event Hubs namespace and replacing [myeventhubsnamespaceprimarykeyconnectionstring] with the primary key connection string of your Event Hubs namespace. The primary key connection string can be read in the Azure Portal under your Event Hubs' "share access policy" -> "RootManagedSharedAccessKey". Then click Update:
  
    BrokerClientName: "UACloudPublisher"  
    BrokerUrl: "[myeventhubsnamespace].servicebus.windows.net"
    BrokerPort: 9093  
    BrokerUsername: "$ConnectionString"  
    BrokerPassword: "[myeventhubsnamespaceprimarykeyconnectionstring]"  
    BrokerMessageTopic: "data"
    BrokerMetadataTopic: "metadata"  
    SendUAMetadata: true  
    MetadataSendInterval: 43200  
    BrokerCommandTopic: ""
    BrokerResponseTopic: ""  
    BrokerMessageSize: 262144  
    CreateBrokerSASToken: false  
    UseTLS: false  
    PublisherName: "UACloudPublisher"  
    InternalQueueCapacity: 1000  
    DefaultSendIntervalSeconds: 1  
    DiagnosticsLoggingInterval: 30  
    DefaultOpcSamplingInterval: 500  
    DefaultOpcPublishingInterval: 1000  
    UAStackTraceMask: 645  
    ReversiblePubSubEncoding: false  
    AutoLoadPersistedNodes: true  

Next, we will configure the OPC UA data nodes from your machines (or connectivity adapter software). To do so, select the OPC UA Server Connect menu item, enter the OPC UA server IP address and port and click Connect. You can now browse the OPC UA Server you want to send telemetry data from. If you have found the OPC UA node you want, right click it and select publish.

That's it! You can check what is currently being published by selecting the Publishes Nodes menu item. You can also see diagnostics information from UA Cloud Publisher on the Diagnostics menu item.

## License

<a rel="license" href="http://creativecommons.org/licenses/by/4.0/"><img alt="Creative Commons License" style="border-width:0" src="https://i.creativecommons.org/l/by/4.0/88x31.png" /></a>

This work is licensed under a <a rel="license" href="http://creativecommons.org/licenses/by/4.0/">Creative Commons Attribution 4.0 International License</a>.
