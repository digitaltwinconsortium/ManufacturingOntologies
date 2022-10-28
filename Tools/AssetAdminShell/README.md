# Querying the Azure Digital Twins graph

> **_NOTE:_**  All queries shown below are based on the ['Standard AAS Samples'](../Sample/Std%20AAS%20Samples%20(8)%20ADT%20Explorer%20Export.json) sample. Just create a new Azure Digital Twin instance and import the file with ADT Explorer.

Using the Asset Administration shell Metamodel ontology to model assets in Azure Digital Twins can lead to quite complex graphs. E.g. the standard sample ['01_Festo'](https://admin-shell-io.com/samples/aasx/01_Festo.aasx) looks like the following in 
[Azure Digital Twins Explorer](https://docs.microsoft.com/en-us/samples/azure-samples/digital-twins-explorer/digital-twins-explorer/):

## Finding AAS referable twins

![](../Assets/images/01_Festo%20in%20ADT.jpg)

To find an AAS Referable in the graph, a list of keys (one global followed by local ones) is used. E.g. for finding the boolean Property 'RCMLabelingPresent' in the 01_Festo sample the keylist looks like:

```xml
<aas:keys>
	<aas:key type="AssetAdministrationShell" idType="IRI">smart.festo.com/demo/aas/1/1/454576463545648365874</aas:key>
	<aas:key type="Submodel" idType="IdShort">Nameplate</aas:key>
	<aas:key type="SubmodelElementCollection" idType="IdShort">Marking_RCM</aas:key>
	<aas:key type="Property" idType="IdShort">RCMLabelingPresent</aas:key>
</aas:keys>
```

Using the [ADT Query language](https://docs.microsoft.com/en-us/azure/digital-twins/concepts-query-language) the following two queries have to be used to find the according twin in the graph:

1. Find Identifiable twin

```sql
SELECT * FROM digitaltwins WHERE IS_OF_MODEL('dtmi:digitaltwins:aas:Identifiable;1') 
AND id = 'smart.festo.com/demo/aas/1/1/454576463545648365874'
```

2. Find referable twin with the Identifiable twin Id (from first query)

```sql
SELECT referable3 FROM DIGITALTWINS MATCH(identifiable)-[]->(referable1)-[]->(referable2)-[]->(referable3) 
WHERE identifiable.$dtId = 'Shell_9359cf0b-9765-4a8a-9ac5-de196948114d' 
AND referable1.idShort = 'Nameplate' AND IS_OF_MODEL(referable1, 'dtmi:digitaltwins:aas:Submodel;1') 
AND referable2.idShort = 'Marking_RCM' AND IS_OF_MODEL(referable2, 'dtmi:digitaltwins:aas:SubmodelElementCollection;1') 
AND referable3.idShort = 'RCMLabelingPresent' AND IS_OF_MODEL(referable3, 'dtmi:digitaltwins:aas:Property;1')
```

The second query will return Property twin:

![](../Assets/images/01_Festo_RCMLabelingProp.jpg)

## AAS Shell queries

The following screenshot from [Azure Digital Twin Explorer](https://docs.microsoft.com/en-us/samples/azure-samples/digital-twins-explorer/digital-twins-explorer/) shows the twins of the
AAS sample ['02_Bosch'](https://admin-shell-io.com/samples/aasx/02_Bosch.aasx) and
['15_Siemens'](https://admin-shell-io.com/samples/aasx/15_Siemens.aasx) (Available for import in ADT Explorer here).

![](../Assets/images/02BoschAnd15Siemens.jpg)

### Finding all AAS shell

```sql
SELECT * FROM DIGITALTWINS WHERE IS_OF_MODEL('dtmi:digitaltwins:aas:AssetAdministrationShell;1')
```

shows the following json output (see [Powershell script with Azure Command line](../Tools/Scripts/ADTQueries/queryForAllShells.ps1))

```json
{
  "result": [
    {
      "$dtId": "Shell_9e0a3ed7-fd9a-4b8b-a203-740e5ca6c76d",
      "$etag": "W/\"728dba1d-7345-4639-831e-f730ed8c353f\"",
      "$metadata": {
        "$model": "dtmi:digitaltwins:aas:AssetAdministrationShell;1",
        "category": {
          "lastUpdateTime": "2022-02-07T11:21:10.3018225Z"
        },
        "idShort": {
          "lastUpdateTime": "2022-02-07T11:21:10.3018225Z"
        }
      },
      "administration": {
        "$metadata": {
          "revision": {
            "lastUpdateTime": "2022-02-07T11:21:10.3018225Z"
          },
          "version": {
            "lastUpdateTime": "2022-02-07T11:21:10.3018225Z"
          }
        },
        "revision": "0",
        "version": "1"
      },
      "category": "CONSTANT",
      "idShort": "Siemens_S7_CPU1515",
      "identification": {
        "$metadata": {
          "id": {
            "lastUpdateTime": "2022-02-07T11:21:10.3018225Z"
          },
          "idType": {
            "lastUpdateTime": "2022-02-07T11:21:10.3018225Z"
          }
        },
        "id": "www.company.com/demo/aas/1234554842136874684321",
        "idType": "IRI"
      }
    },
    {
      "$dtId": "Shell_3977bb3f-f4ce-4877-a64a-c8edc4330898",
      "$etag": "W/\"cebeacfc-c5e2-4e13-bff2-381ad7a87965\"",
      "$metadata": {
        "$model": "dtmi:digitaltwins:aas:AssetAdministrationShell;1",
        "idShort": {
          "lastUpdateTime": "2022-02-08T07:10:12.2854332Z"
        }
      },
      "administration": {
        "$metadata": {}
      },
      "idShort": "Bosch_NexoPistolGripNutrunner",
      "identification": {
        "$metadata": {
          "id": {
            "lastUpdateTime": "2022-02-08T07:10:12.2854332Z"
          },
          "idType": {
            "lastUpdateTime": "2022-02-08T07:10:12.2854332Z"
          }
        },
        "id": "http://boschrexroth.com/shells/0608842005/917004878",
        "idType": "IRI"
      }
    }
  ]
}
```

### Retrieving the 'idShort' local identifiers of all AAS shells

```sql
SELECT idShort FROM DIGITALTWINS WHERE IS_OF_MODEL('dtmi:digitaltwins:aas:AssetAdministrationShell;1')
```

shows the following json output (see [Powershell script with Azure Command line](../Tools/Scripts/ADTQueries/queryForAllShellsIdShorts.ps1))

```json
{
  "result": [
    {
      "idShort": "Siemens_S7_CPU1515"
    },
    {
      "idShort": "Bosch_NexoPistolGripNutrunner"
    }
  ]
}
```

### Retrieving all submodels of an AAS shell (in sample for the Siemens AAS)

```sql
SELECT submodel FROM DIGITALTWINS
 MATCH (shell)-[:submodel]->(submodel)
  WHERE IS_OF_MODEL(shell, 'dtmi:digitaltwins:aas:AssetAdministrationShell;1')
  AND shell.$dtId = 'Shell_9e0a3ed7-fd9a-4b8b-a203-740e5ca6c76d'
```

shows the following json output (see [Powershell script with Azure Command line](../Tools/Scripts/ADTQueries/queryForAllSubmodelsOfShell.ps1)) and projected on 'idShort'

```json
[
  "Nameplate",
  "Identification",
  "Service",
  "Document"
]
```

### Retrieving all Submodel elements of an AAS shell (in sample for the Siemens AAS)

```sql
SELECT submodelElement FROM DIGITALTWINS 
 MATCH (shell)-[:submodel]->(submodel)-[:submodelElement]->(submodelElement)
 WHERE IS_OF_MODEL(shell, 'dtmi:digitaltwins:aas:AssetAdministrationShell;1') 
 AND shell.$dtId = 'Shell_9e0a3ed7-fd9a-4b8b-a203-740e5ca6c76d' 
 AND IS_OF_MODEL(submodel, 'dtmi:digitaltwins:aas:Submodel;1') 
 AND IS_OF_MODEL(submodelElement, 'dtmi:digitaltwins:aas:SubmodelElement;1')
```

### Getting the number of AAS in the graph
```sql
SELECT COUNT() FROM digitaltwins WHERE IS_OF_MODEL('dtmi:digitaltwins:aas:AssetAdministrationShell;1')
```
