# Manufacturing Ontologies

## Digital Twin Definition Language

These ontologoes leverage the Digital Twin Definition Language (DTDL), which is specified [here](https://github.com/Azure/opendigitaltwins-dtdl/blob/master/DTDL/v2/dtdlv2.md).

### Production Line Layout

A typical production line is organized into a number of inter-connected stations that a product being manufactured has to pass through. The production line layout for this ontology is as follows (MES stands for Manufacturing Execution System):

![Line](Docs/line.png)

### Model Relationships

The relationships between the models used in this ontology are described via the following diagram (taken from the [Azure Digital Twins Explorer](https://explorer.digitaltwins.azure.net/) tool):

<img src="Docs/modelrelationships.png" alt="relationships" width="500" />

### Machine Information Model

The underlying machine information model is based on OPC UA and can be used for Overall Equipment Effectiveness (OEE) calculation. It is defined [here](https://github.com/digitaltwinconsortium/ManufacturingDTDLOntologies/blob/main/FactorySimulation/Station/Station.NodeSet2.xml) and is also available in the UA Cloud Library [here](https://uacloudlibrary.opcfoundation.org/).

### Automotive Digital Twin Graph

The digital twin graph for an automotive production line is depicted below (taken from the [Azure Digital Twins Explorer](https://explorer.digitaltwins.azure.net/) tool):

![twingraph](Docs/twingraph.png)

## Production Line Simulation

This repository also contains a production line simulation made up of several Stations, leveraging the machine information model described above, as well as a simple Manufacturing Execution System (MES). Both the Stations and the MES are containerized for easy deployment.

### Simulation Digital Twin Graph

The digital twin graph for the simulated production line is depicted below (taken from the [Azure Digital Twins Explorer](https://explorer.digitaltwins.azure.net/) tool):

<img src="Docs/FactorySimulationTwin.png" alt="relationships" width="250" />

### Installation Instructions

To install the production line simulation, you need a Windows PC or virtual machine with at least 8GB of memory. Then follow these steps:

* Use an existing Azure subscription you have admin access to or get a free Azure subscription from [here](https://azure.microsoft.com/en-us/free).

* Deploy an S1 Azure IoT Hub into your Azure subscription. Once deployed, create 6 devices and call them publisher.munich.corp.contoso, publisher.capetown.corp.contoso, publisher.mumbai.corp.contoso, publisher.seattle.corp.contoso, publisher.beijing.corp.contoso and publisher.rio.corp.contoso. Create another 6 devices, but replace the word "publisher" with "twin", i.e. twin.munich.corp.contoso,etc.

* Download and install the latest .NET Core SDK (not just the Runtime!) from [here](https://dotnet.microsoft.com/en-us/download/dotnet).

* Download and install Docker Desktop from [here](https://www.docker.com/products/docker-desktop), including the Windows Subsystem for Linux (WSL) integration. After installation and a required system restart, accept the license terms and install the WSL2 Linux kernel by following the instructions. Then verify that Docker Desktop is running in the Windows System Tray.

* Browse to [here](https://github.com/digitaltwinconsortium/ManufacturingDTDLOntologies) and select Code -> Download Zip. Unzip the contents to a directory of your choice.

* Open a command prompt and navigate to the FactorySimulation directory of the Zip you just downloaded.

* Edit the BuildAndRunSimulation.cmd and replace the ENTER_PUBLISHER_DEVICE_CONNECTION_STRING_HERE placeholder string with the primary connection strings of the 6 IoT Hub publisher devices you have created earlier. Also replace the ENTER_TWIN_DEVICE_CONNECTION_STRING_HERE string with the primary connection strings of the 6 IoT Hub twin devices you have created earlier. The connection strings can be accssed by clicking on the names of the devices in the Azure Portal.

* Run the BuildAndRunSimulation.cmd script. This will build the code and Docker container, setup the Docker networks and run the simulation. A total of 8 production lines will be started, each with 3 stations each (assembly, test and packaging) as well as an MES per line and an OPC Publisher instance per factory location. There are 6 locations in total: Munich, Capetown, Mumbai, Seattle, Beijing and Rio.

* Open the Docker Desktop Dashboard by clicking the Docker icon in the Windows system Tray and check out the logs of an MES and a Publisher by clicking on their names to verify that the simulated production has started and OPC UA PubSub telemetry messages are being sent to IoT Hub. Additionally, you can use the Azure IoT Explorer tool from [here](https://github.com/Azure/azure-iot-explorer/releases) by entering the IoT Hub Owner Primary Connection String in the tool, selecting one of the OPC Publishers and clicking on Telemetry -> Start.

If you want to store the OPC UA PubSub telemetry data in a time-series database and do further analysis on it, you can deploy an instance of Azure Data Explorer (ADX) from the Azure Portal and connect is directly to your IoT Hub you set up above by following the steps in the lower half of the article from [here](https://www.linkedin.com/pulse/using-azure-data-explorer-opc-ua-erich-barnstedt/). Once you do that, you can e.g. calculate the OEE using the ADX queries found [here](https://github.com/digitaltwinconsortium/ManufacturingDTDLOntologies/tree/main/ADXQueries).

Also, if you want to test a "digital feedback loop", i.e. triggering a command on one of the OPC UA servers in the simulation from the cloud, based on a time-series reaching a certain threshold (the simulated pressure), then deploy the PressureRelief Azure Function in your Azure subscription and create an application registration for your ADX instance as described [here](https://docs.microsoft.com/en-us/azure/data-explorer/provision-azure-ad-app). You also need to define the following environment variables in the Azure portal for the Function:
* ADX_INSTANCE_URL
* ADX_DB_NAME
* AAD_TENANT_ID
* APPLICATION_KEY
* APPLICATION_ID
* IOT_HUB_NAME
* IOT_HUB_KEY
* OPC_TWIN_NAME
* UA_SERVER_ENDPOINT
* UA_SERVER_METHOD_ID
* UA_SERVER_OBJECT_ID
* UA_SERVER_DNS_NAME

### Overall Equipment Effectiveness (OEE) Calculation

OEE is a common metric in production environments, see the reference calculation [here](https://www.oee.com/calculating-oee).

### Default Simulation Configuration

The simulation is configured to include 8 production lines by default and the configuration can be altered in the BuildAndRunSimulation.cmd script. The default configuration is depicted below:

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


## License

<a rel="license" href="http://creativecommons.org/licenses/by/4.0/"><img alt="Creative Commons License" style="border-width:0" src="https://i.creativecommons.org/l/by/4.0/88x31.png" /></a>

This work is licensed under a <a rel="license" href="http://creativecommons.org/licenses/by/4.0/">Creative Commons Attribution 4.0 International License</a>.
