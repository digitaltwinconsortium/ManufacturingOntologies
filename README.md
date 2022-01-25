# Automotive Manufacturing Ontology



## Digital Twin Definition Language

This work leverages the Digital Twin Definition Language (DTDL), which is specified [here](https://github.com/Azure/opendigitaltwins-dtdl/blob/master/DTDL/v2/dtdlv2.md).



### Production Line Layout

A typical production line is organized into a number of inter-connected stations that a product being manufactured has to pass through. The production line layout for this ontology is as follows (MES stands for Manufacturing Execution System):

![Line](Docs/line.png)



### Model Relationships

The relationships between the models used in this ontology are described via the following diagram (taken from the [Azure Digital Twins Explorer](https://explorer.digitaltwins.azure.net/) tool):

<img src="Docs/modelrelationships.png" alt="relationships" width="500" />



### Machine Information Model

The underlying machine information model is based on OPC UA and can be used for Overall Equipment Effectiveness (OEE) calculation. It is derived from the Microsoft Azure IoT Connected Factory simulation defined [here](https://github.com/Azure/azure-iot-connected-factory/blob/main/Simulation/Factory/Station/StationModel.xml).



### Digital Twin Graph

The resulting digital twin graph is depicted below (taken from the [Azure Digital Twins Explorer](https://explorer.digitaltwins.azure.net/) tool):

![twingraph](Docs/twingraph.png)



### Overall Equipment Effectiveness (OEE) Calculation

OEE is a common metric in production environments, see the reference calculation [here](https://www.oee.com/calculating-oee).



## Production Line Simulation

This repository contains a production line simulation made up of several Stations, leveraging the machine information model described above, as well as a simple Manufacturing Execution System (MES). Both the Stations and the MES are containerized for easy deployment.



### Digital Twin Graph

The digital twin graph for the simulated production line is depcted below (taken from the [Azure Digital Twins Explorer](https://explorer.digitaltwins.azure.net/) tool):

![twingraph](Docs/FactorySimulationTwin.png)



### Installation Instructions

To install the production line simulation, you need a PC or virtual machine. Then follow these steps:
* Use an existing Azure subscription you have admin access to or get a free Azure subscription from [here](https://azure.microsoft.com/en-us/free).
* Deploy an S1 Azure IoT Hub into your Azure subscription. Once deployed, create 6 devices and call them publisher.munich.corp.contoso, publisher.capetown.corp.contoso, publisher.mumbai.corp.contoso, publisher.seattle.corp.contoso, publisher.beijing.corp.contoso and publisher.rio.corp.contoso.
* Download and install the latest .NET Core SDK (not just the Runtime!) from [here](https://dotnet.microsoft.com/en-us/download/dotnet).
* Download and install Docker Desktop from [here](https://www.docker.com/products/docker-desktop), including the Windows Subsystem for Linux (WSL) integration. After installation and a required system restart, accept the license terms and install the WSL2 Linux kernel by following the instructions. Then verify that Docker Desktop is running in the Windows System Tray.
* Browse to [here](https://github.com/digitaltwinconsortium/AutomotiveManufacturingDTDLOntology) and select Code -> Download Zip. Unzip the contents to a directory of your choice.
* Open a command prompt and navigate to the FactorySimulation directory of the Zip you just downloaded.
* Edit the BuildAndRunSimulation.cmd and replace the ENTER_PUBLISHER_DEVICE_CONNECTION_STRING_HERE placeholder string with the primary connection strings of the 6 IoT Hub devices you have created earlier. The connection strings can be accssed by clicking on the names of the devices in the Azure Portal.
* Run the BuildAndRunSimulation.cmd script. This will build the code and Docker container, setup the Docker networks and run the simulation. A total of 8 production lines will be started, each with 3 stations each (assembly, test and packaging) as well as an MES per line and an OPC Publisher instance per factory location. There are 6 locations in total: Munich, Capetown, Mumbai, Seattle, Beijing and Rio.
* Open the Docker Desktop Dashboard by clicking the Docker icon in the Windows system Tray and check out the logs of an MES and a Publisher by clicking on their names to verify that the simulated production has started and OPC UA PubSub telemetry messages are being sent to IoT Hub. Additionally, you can use the Azure IoT Explorer tool from [here](https://github.com/Azure/azure-iot-explorer/releases) by entering the IoT Hub Owner Primary Connection String in the tool, selecting one of the OPC Publishers and clicking on Telemetry -> Start.

If you want to store the OPC UA PubSub telemetry data in a time-series database and do further analysis on it, you can deploy an instance of Azure Data Explorer from the Azure Portal and connect is directly to your IoT Hub you set up above by following the steps in the lower half of the article from [here](https://www.linkedin.com/pulse/using-azure-data-explorer-opc-ua-erich-barnstedt/).



## License

<a rel="license" href="http://creativecommons.org/licenses/by/4.0/"><img alt="Creative Commons License" style="border-width:0" src="https://i.creativecommons.org/l/by/4.0/88x31.png" /></a>

This work is licensed under a <a rel="license" href="http://creativecommons.org/licenses/by/4.0/">Creative Commons Attribution 4.0 International License</a>.
