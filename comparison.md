# DTDLv3 and W3C WoT Thing Model 1.1 Comparision

This document gives a detailed comparison between [DTDL](https://azure.github.io/opendigitaltwins-dtdl/DTDL/v3/DTDL.v3.html) and [W3C WoT Thing Model](https://www.w3.org/TR/wot-thing-description11/).

Hint: JSON-LD keywords like @id, @context, @type etc. are ignored.

## Example Of Conversion

### _Digital Twin Description Language v3_

```json
{
  "@context": "dtmi:dtdl:context;3",
  "@id": "dtmi:thing:model:test;1",
  "@type": "Interface",
  "displayName": {
    "en": "Thing Model Test",
    "it": "Modello di Test",
    "fr": "Modèle de test",
    "de": "Testmodel"
  },
  "description": {
    "en": "Thing Model used for testing",
    "it": "Modello utilizzato a fini di test",
    "fr": "Modèle utilisé à des fins d'essai'",
    "de": "Zu Testzwecken verwendetes Modell"
  },
  "comment": "http://localhost:3000",
  "contents": [
    {
      "@type": "Property",
      "writable": false,
      "schema": {
        "fields": [
          {
            "@type": "Field",
            "name": "status"
          }
        ],
        "@type": "Object",
        "displayName": "availablePower"
      },
      "name": "power",
      "displayName": "availablePower",
      "description": "Property obtained from 'Thing Model Test' Thing Model",
      "comment": "1 form: 1 - href: power"
    },
    {
      "@type": "Property",
      "writable": false,
      "schema": "string",
      "name": "content",
      "displayName": {
        "en": "availableContent",
        "it": "contenutoDisponibile",
        "fr": "contenuDisponible",
        "de": "verfügbarerInhalt"
      },
      "description": "Content of the Test Model",
      "comment": "1 form: 1 - href: content"
    },
    {
      "@type": "Property",
      "writable": false,
      "schema": "integer",
      "name": "temperature",
      "displayName": "availableTemperature",
      "description": "Property obtained from 'Thing Model Test' Thing Model",
      "comment": "1 form: 1 - href: temp"
    },
    {
      "@type": "Property",
      "writable": false,
      "schema": {
        "valueSchema": "string",
        "enumValues": [
          {
            "@type": "EnumValue",
            "displayName": "readyToCharge",
            "name": "readyToCharge",
            "enumValue": "readyToCharge"
          },
          {
            "@type": "EnumValue",
            "displayName": "charging",
            "name": "charging",
            "enumValue": "charging"
          },
          {
            "@type": "EnumValue",
            "displayName": "stopCharging",
            "name": "stopCharging",
            "enumValue": "stopCharging"
          }
        ],
        "@type": "Enum",
        "description": "Current car status (readyToCharge, charging, stopCharging)"
      },
      "name": "status",
      "displayName": "status",
      "description": "Current car status (readyToCharge, charging, stopCharging)",
      "comment": "1 form: 1 - href: /ecar/properties/status"
    },
    {
      "@type": "Property",
      "writable": false,
      "schema": {
        "elementSchema": "double",
        "@type": "Array",
        "displayName": "RGB color value"
      },
      "name": "rgb",
      "displayName": "RGB color value",
      "description": "Property obtained from 'Thing Model Test' Thing Model"
    },
    {
      "@type": "Command",
      "name": "toggle",
      "displayName": "togglePowerStatus",
      "description": "Command obtained from 'Thing Model Test' Thing Model",
      "comment": "1 form: 1 - href: toggle"
    },
    {
      "@type": "Command",
      "name": "setVolume",
      "displayName": "setVolume",
      "description": "Command obtained from 'Thing Model Test' Thing Model",
      "comment": "1 form: 1 - href: setvolume"
    },
    {
      "@type": "Command",
      "Request": {
        "@type": "CommandRequest",
        "name": "rebootRequest",
        "displayName": "Reboot Time",
        "description": "Requested time to reboot the device.",
        "schema": "dateTime"
      },
      "Response": {
        "@type": "CommandResponse",
        "name": "rebootResponse",
        "displayName": "Scheduled Time",
        "description": "Scheduled shutdown time",
        "schema": "dateTime"
      },
      "name": "reboot",
      "displayName": "SystemReboot",
      "description": "Reboots the system at the specified time"
    },
    {
      "@type": "Command",
      "Request": {
        "@type": "CommandRequest",
        "name": "playVideoRequest",
        "displayName": "playVideo Request",
        "description": "playVideo action request",
        "schema": {
          "fields": [
            {
              "@type": "Field",
              "displayName": "VideoIdentifier",
              "name": "identifier",
              "description": "The unique identifier of a Video",
              "schema": "string"
            },
            {
              "@type": "Field",
              "displayName": "VideoName",
              "name": "name",
              "description": "The name of a Video file",
              "schema": "string"
            },
            {
              "@type": "Field",
              "displayName": "Timestamp",
              "name": "timestamp",
              "description": "Request Timestamp",
              "schema": "dateTime"
            },
            {
              "@type": "Field",
              "displayName": "VideoUrl",
              "name": "url",
              "description": "The Video Url",
              "schema": "string"
            }
          ],
          "@type": "Object",
          "displayName": "playVideoRequest",
          "description": "playVideo action request"
        }
      },
      "Response": {
        "@type": "CommandResponse",
        "name": "playVideoResponse",
        "displayName": "playVideo Response",
        "schema": {
          "fields": [
            {
              "@type": "Field",
              "name": "stream",
              "schema": "string"
            },
            {
              "@type": "Field",
              "name": "timestamp",
              "schema": "dateTime"
            }
          ],
          "@type": "Object"
        }
      },
      "name": "playVideo",
      "displayName": "playVideo",
      "description": "Command obtained from 'Thing Model Test' Thing Model",
      "comment": "1 form: 1 - href: playvideo"
    },
    {
      "type": "Telemetry",
      "name": "alert",
      "displayName": "alert",
      "description": "Telemetry obtained from 'Thing Model Test' Thing Model",
      "comment": "2 forms: 1 - href: alrt / 2 - href: ws://localhost:8888/alert / "
    }
  ]
}
```

### _Thing Model 1.1_

```json
{
  "@context": "https://www.w3.org/2019/wot/td/v1",
  "id": "urn:testModel",
  "@type": "tm:ThingModel",
  "title": "Thing Model Test",
  "description": "Thing Model used for testing",
  "descriptions": {
    "en": "Thing Model used for testing",
    "it": "Modello utilizzato a fini di test",
    "fr": "Modèle utilisé à des fins d'essai'",
    "de": "Zu Testzwecken verwendetes Modell"
  },
  "securityDefinitions": {
    "nosec_sc": {
      "scheme": "nosec"
    }
  },
  "security": "nosec_sc",
  "base": "http://localhost:3000",
  "titles": {
    "en": "Thing Model Test",
    "it": "Modello di Test",
    "fr": "Modèle de test",
    "de": "Testmodel"
  },
  "properties": {
    "power": {
      "title": "availablePower",
      "type": "object",
      "properties": {
        "status": {}
      },
      "forms": [
        {
          "op": "readproperty",
          "contentType": "application/json;charset=utf-8",
          "href": "power"
        }
      ]
    },
    "content": {
      "title": "availableContent",
      "titles": {
        "en": "availableContent",
        "it": "contenutoDisponibile",
        "fr": "contenuDisponible",
        "de": "verfügbarerInhalt"
      },
      "description": "Content of the Test Model",
      "type": "string",
      "forms": [
        {
          "op": "readproperty",
          "contentType": "application/json;charset=utf-8",
          "href": "content"
        }
      ]
    },
    "temperature": {
      "title": "availableTemperature",
      "type": "integer",
      "forms": [
        {
          "op": "readproperty",
          "contentType": "application/json;charset=utf-8",
          "href": "temp"
        }
      ]
    },
    "status": {
      "type": "string",
      "description": "Current car status (readyToCharge, charging, stopCharging)",
      "readOnly": true,
      "enum": ["readyToCharge", "charging", "stopCharging"],
      "forms": [
        {
          "href": "/ecar/properties/status",
          "contentType": "application/json",
          "op": ["readproperty"]
        }
      ]
    },
    "rgb": {
      "title": "RGB color value",
      "type": "array",
      "items": {
        "type": "number",
        "minimum": 0,
        "maximum": 255
      },
      "minItems": 3,
      "maxItems": 3
    }
  },
  "actions": {
    "toggle": {
      "safe": true,
      "idempotent": false,
      "title": "togglePowerStatus",
      "forms": [
        {
          "op": "invokeaction",
          "contentType": "application/json;charset=utf-8",
          "href": "toggle"
        }
      ]
    },
    "setVolume": {
      "safe": true,
      "idempotent": false,
      "title": "setVolume",
      "forms": [
        {
          "op": "invokeaction",
          "contentType": "application/json;charset=utf-8",
          "href": "setvolume"
        }
      ]
    },
    "reboot": {
      "title": "SystemReboot",
      "description": "Reboots the system at the specified time",
      "input": {
        "type": "string",
        "format": "date-time",
        "title": "Reboot Time",
        "description": "Requested time to reboot the device."
      },
      "output": {
        "type": "string",
        "format": "date-time",
        "title": "Scheduled Time",
        "description": "Scheduled shutdown time"
      }
    },
    "playVideo": {
      "safe": true,
      "idempotent": false,
      "title": "playVideo",
      "forms": [
        {
          "op": "invokeaction",
          "contentType": "application/json;charset=utf-8",
          "href": "playvideo"
        }
      ],
      "input": {
        "type": "object",
        "description": "playVideo action request",
        "title": "playVideo Request",
        "properties": {
          "identifier": {
            "type": "string",
            "title": "Video Identifier",
            "description": "The unique identifier of a Video"
          },
          "name": {
            "type": "string",
            "title": "Video Name",
            "description": "The name of a Video file"
          },
          "timestamp": {
            "type": "string",
            "format": "date-time",
            "title": "Timestamp",
            "description": "Request Timestamp"
          },
          "url": {
            "type": "string",
            "title": "Video Url",
            "description": "The Video Url"
          }
        }
      },
      "output": {
        "type": "object",
        "properties": {
          "stream": {
            "type": "string"
          },
          "timestamp": {
            "type": "string",
            "format": "date-time"
          }
        }
      }
    }
  },
  "events": {
    "alert": {
      "title": "alert",
      "data": { "type": "object" },
      "forms": [
        {
          "op": "subscribeevent",
          "contentType": "application/json;charset=utf-8",
          "subprotocol": "longpoll",
          "href": "alrt"
        },
        {
          "op": "subscribeevent",
          "contentType": "application/json;charset=utf-8",
          "href": "ws://localhost:8888/alert"
        }
      ]
    }
  }
}
```

## Shared Attributes

Some term definitions in DTDL as well as in WoT may appear in different structures. The semantics of these terms are independent of their context, so they are discussed in general in this section to 

| DTDL Term / Concept | DTDL Description                                                            | WoT TD Term      | WoT TD Description                                                                                                 | Comments                                                         |
|---------------------|-----------------------------------------------------------------------------|------------------|--------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------|
| **displayName**     | A localizable name for display.                                             | **title**        | Provides a human-readable title (e.g., display a text for UI representation) based on a default language.          | Derived from JSON schema. Proposal is to use the WoT definition. |
|                     | Comment: displayName allows JSON-LD language map for multi-language support | **titles**       | Provides multi-language human-readable titles (e.g., display a text for UI representation in different languages). | Proposal is to keep WoT definition.                              |
| **description**     | A localizable description for display.                                      | **description**  | (human-readable) information based on a default language.                                                          | Derived from JSON schema. Proposal is to use the WoT definition. |
|                     | Comment: description allows JSON-LD language map for multi-language support | **descriptions** | Can be used to support (human-readable) information in different languages.                                        | Proposal is to keep WoT definition.                              |
| **comment**         | A comment for model authors.                                                | -                |                                                                                                                    | Proposal is to keep the DTDL definition.                         |


## DTDL Interface / WoT Thing Model

| DTDL Term / Concept      | DTDL Description                                                                                              | WoT TD Term             | WoT TD Description                                                                                                                                                       | Comments                                                                                                        |
|--------------------------|---------------------------------------------------------------------------------------------------------------|-------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------|
| **@context**             | The context to use when processing this Interface. For this version, it must be set to “dtmi:dtdl:context;3”. | **@context**            | The version of the TD Information Model defined in 5. TD Information Model of this specification is identified by the following IRI: https://www.w3.org/2022/wot/td/v1.1 | Proposal is to use the WoT definition                                                                           |
| **@type**                | This must be “Interface”.                                                                                     | **@type**               | Thing Model definitions MUST use the keyword @type at top level and a value of type string or array that equals or respectively contains tm:ThingModel.                  | Proposal is to use the WoT definition                                                                           |
| **@id**                  | An identifer for the Interface. (DTMI datatype)                                                               | **@id**                 | It is recommended that the id value of a Thing Model provides a placeholder such as "id": "urn:example:{{RANDOM_ID_PATTERN}}" for the TD generation process.             | Proposal is to introduce Thing Model id in WoT                                                                  |
|                          |                                                                                                               | **version**             | Provides version information.                                                                                                                                            | Proposal is to keep WoT definition.                                                                             |
|                          |                                                                                                               | **created**             | Provides information when the TD instance was created.                                                                                                                   | Proposal is to keep WoT definition.                                                                             |
|                          |                                                                                                               | **modified**            | Provides information when the TD instance was last modified.                                                                                                             | Proposal is to keep WoT definition.                                                                             |
|                          |                                                                                                               | **support**             | Provides information about the TD maintainer as URI scheme (e.g., mailto [RFC6068], tel [RFC3966], https [RFC9112]).                                                     | Proposal is to keep WoT definition.                                                                             |
| **content**              | A set of elements that define the contents of this Interface.                                                 |                         | Comment: Kind of interactions specified directly in properties, actions, and events container.                                                                           | Proposal is to split this up into 3 separate fields, i.e. WoT "properties", "actions" and "events" (see below). |
| **schemas**              | A set of complex schema objects that are reusable within this Interface.                                      | **schemaDefinitions**   | Set of named data schemas. To be used in a schema name-value pair inside an AdditionalExpectedResponse object.                                                           | Proposal is to keep WoT definition.                                                                             |
| **extends**              | A set of DTMIs that refer to Interfaces from which this Interface inherits contents...                        | **links.rel**               | A Thing Model can extend an existing Thing Model by using the tm:extends mechanism announced in the links definition.                                                    | WoT uses [RFC8288] web linking for inheritance. Proposal is to use that.                                        |
|                          |                                                                                                               |                         | Links provide Web links to arbitrary resources that relate to the specified Thing Description.                                                                           |                                                                                                                 |
|                          |                                                                                                               | **forms**               | Set of form hypermedia controls that describe how an operation can be performed.                                                                                         | Used for WoT protocol bindings. Proposal is to use the WoT definition.                                          |
|                          |                                                                                                               | **security**            | Set of security definition names, chosen from those defined in securityDefinitions.                                                                                      | Proposal is to use the WoT definition.                                                                          |
|                          |                                                                                                               | **securityDefinitions** | Set of named security configurations (definitions only).                                                                                                                 | Proposal is to use the WoT definition.                                                                          |
|                          |                                                                                                               | **profile**             | Indicates mandatory fields defined in the profile. New in version 1.1. Not used yet.                                                                                     | Proposal is to use the WoT definition.                                                                          |
|                          |                                                                                                               | **uriVariables**        | Define URI template variables according to [RFC6570] as collection based on DataSchema declarations.                                                                     | Proposal is to use the WoT definition.                                                                          |
| **"@type": "Property"**  | A Property describes the read-only and read/write state of any digital twin.                                  | **properties**          | All Property-based Interaction Affordances of the Thing.                                                                                                                 | Proposal is to use the WoT definition.                                                                          |
| **"@type": "Command"**   | A Command describes a function or operation that can be performed on any digital twin.                        | **actions**             | All Action-based Interaction Affordances of the Thing.                                                                                                                   | Proposal is to use the WoT definition.                                                                          |
| **"@type": "Telemetry"** | Telemetry describes the data emitted by any digital twin, whether the data is ...                             | **events**              | All Event-based Interaction Affordances of the Thing.                                                                                                                    | Proposal is to use the WoT definition.                                                                          |

### Examples

#### _DTDL v3_

```json
{
  "@context": "dtmi:dtdl:context;3",
  "@id": "dtmi:test:model;1",
  "@type": "Interface",
  "displayName": "Test Model",
  "description": "Thing Model Test",
  "comment": "http://localhost:3000",
  "contents": []
}
```

#### _Thing Model 1.1_

```json

{
  "@context": "https://www.w3.org/2019/wot/td/v1",
  "id": "urn:testModel",
  "@type": "tm:ThingModel",
  "description" : "Thing Model Test",
  "securityDefinitions": {
    "nosec_sc": {
      "scheme": "nosec"
    }
  },
  "security": "nosec_sc",
  "base": "http://localhost:3000",
  "title": "Test Model",
  "properties": [],
  "actions": [],
  "events": []
}
```

## Property/Property

| DTDL Term / Concept | DTDL Description                                                        | WoT TD Term        | WoT TD Description                                                                                                     | Comments                                                            |
|---------------------|-------------------------------------------------------------------------|--------------------|------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------|
| **name**            | The programming name of the element.                                    | **{property key}** | Comment: Programming name is assigned as key name of the property                                                      | Proposal is to keep the DTDL definition but convert to JSON-LD 1.1. |
| **schema**          | The data type of the Property, which is an instance of Schema.          | **type**           | Assignment of JSON-based data types compatible with JSON Schema                                                        | Proposal is to keep WoT definition.                                 |
| **writable**        | A boolean value that indicates whether the Property is writable or not. | **writeOnly**      | Boolean value that is a hint to indicate whether a property interaction / value is write only (=true) or not (=false). | Proposal is to use the WoT definition.                              |
|                     |                                                                         | **readOnly**       | Boolean value that is a hint to indicate whether a property interaction / value is read only (=true) or not (=false).  | Proposal is to use the WoT definition.                              |
|                     |                                                                         | **observable**     | Boolean value that is a hint to indicate whether a property interaction / value is observable (=true) or not (=false). | Proposal is to use the WoT definition.                              |
|                     |                                                                         | **forms**          | Set of form hypermedia controls that describe how an operation can be performed (used for protocol bindings).          | Proposal is to use the WoT definition.                              |
|                     |                                                                         | **uriVariables**   | Define URI template variables according to [RFC6570] as collection based on DataSchema declarations.                   | Proposal is to use the WoT definition.                              |
|                     |                                                                         | **{DataSchema}**   | Comment: At property level there can be the terms from data schema                                                     | Proposal is to use the WoT definition.                              |

### Examples

#### _DTDL v3_

```json

{
  "@type": "Property",
  "writable": false,
  "schema": "string",
  "name": "content",
  "displayName": "availableContent",
  "description": "Content of the Test Model",
  "comment": "1 form: 1- Thing Model form href: content"
},

```

#### _Thing Model 1.1_

```json
"properties" :{
  "content": {
    "title": "availableContent",
    "type": "string",
    "description": "Content of the Test Model",
    "forms": [
      {
        "op": "readproperty",
        "contentType": "application/json;charset=utf-8",
        "href": "content"
      }
    ]
  }
}

```

## Commands/Actions

| DTDL Term / Concept | DTDL Description                                                     | WoT TD Term   | WoT TD Description                                                | Comments                                                            |
|---------------------|----------------------------------------------------------------------|---------------|-------------------------------------------------------------------|---------------------------------------------------------------------|
| **@type**           | If provided, must be "Command"                                       | **action**    |                                                                   | Proposal: Use JSON-LD 1.1 style for better JSON processing          |
| **@id**             | Identifier for the commnand. Assigned automatically if not provided. | **@id**       | Same concept from JSON-LD                                         | Equal, no change needed                                             |
| **name**            | The programming name of the element.                                 | **{map key}** | Comment: Programming name is assigned as key name of the property | Proposal is to keep the DTDL definition but convert to JSON-LD 1.1. |
| **request**         | A description of the input to the Command.                           | **input**     | The input data schema of the Action {DataSchema format}           | Proposal is to use the WoT definition                               |
| **response**        | A description of the output of the Command.                          | **output**    | The output data schema of the Action {DataSchema format}          | Proposal is to use the WoT definition                               |

### Examples

#### _DTDL v3_

```json
{
  "@type": "Command",
  "Request": {
    "@type": "CommandRequest",
    "name": "rebootRequest",
    "displayName": "Reboot Time",
    "description": "Requested time to reboot the device.",
    "schema": "dateTime"
  },
  "Response": {
    "@type": "CommandResponse",
    "name": "rebootResponse",
    "displayName": "Scheduled Time",
    "description": "Scheduled shutdown time",
    "schema": "dateTime"
  },
  "name": "reboot",
  "displayName": "SystemReboot",
  "description": "Reboots the system at the specified time"
}
```

#### _Thing Model 1.1_

```json

"actions":{
 "reboot": {
   "title": "SystemReboot",
   "description": "Reboots the system at the specified time",
   "input": {
     "type": "string",
     "format": "date-time",
     "title": "Reboot Time",
     "description": "Requested time to reboot the device."
   },
   "output": {
     "type": "string",
     "format": "date-time",
     "title": "Scheduled Time",
     "description": "Scheduled shutdown time"
   }
 }
}
```

## Primitive Schema / WoT Type Definitions

| DTDL Term / Concept | DTDL Description                                                                                                          | WoT TD Term (JSON schema)           | WoT TD Description | Comments                                                                       |
|---------------------|---------------------------------------------------------------------------------------------------------------------------|-------------------------------------|--------------------|--------------------------------------------------------------------------------|
| **boolean**         | a boolean value                                                                                                           | type: **boolean**                   | ...                | Proposal is to use the JSON schema and map DTDL primitives to it.              |
| **date**            | a date in ISO 8601 format, per [RFC 3339](https://tools.ietf.org/html/rfc3339)                                            | type: **string + format=date-time** | ...                | "                                                                              |
| **dateTime**        | a date and time in ISO 8601 format per [RFC 3339](https://tools.ietf.org/html/rfc3339)                                    | type: **string + format=date-time** | ...                | "                                                                              |
| **double**          | a finite numeric value that is expressible in IEEE 754 double-precision floating point format, conformant with xsd:double | type: **number**                    | ...                | "                                                                              |
| **duration**        | a duration in ISO 8601 format                                                                                             | type: **string + format=duration**  | ...                | "                                                                              |
| **float**           | a finite numeric value that is expressible in IEEE 754 single-precision floating point format, conformant with xsd:float  | type: **number**                    | ...                | for conversion purposes, number will be always mapped as a double (TM to DTDL) |
| **integer**         | a signed integral numeric value that is expressible in 4 bytes                                                            | type: **integer**                   | ...                | Proposal is to use the JSON schema and map DTDL primitives to it.              |
| **long**            | a signed integral numeric value that is expressible in 8 bytes                                                            | type: **number**                    | ...                | for conversion purposes, number will be always mapped as a double (TM to DTDL) |
| **string**          | a UTF8 string                                                                                                             | type: **string**                    | ...                | Proposal is to use the JSON schema and map DTDL primitives to it.              |
| **time**            | a time in ISO 8601 format, per [RFC 3339](https://tools.ietf.org/html/rfc3339)                                            | type: **string + format=time**      | ...                | Proposal is to use the JSON schema and map DTDL primitives to it.              |

## Array

An Array describes an indexable data type where each element is of the same schema.
The schema for an Array's element can itself be a primitive or complex schema.

The chart below lists the properties that an Array may have.

| DTDL Term / Concept | DTDL Description                                                                       | WoT TD Term (JSON schema) | WoT TD Description                                                               | Comments                                                          |
|---------------------|----------------------------------------------------------------------------------------|---------------------------|----------------------------------------------------------------------------------|-------------------------------------------------------------------|
| **@type**           | This must be "Array".                                                                  | **type**                  | Assignment of JSON-based data types compatible with JSON Schema (... array ...). | Proposal is to use the JSON schema and map DTDL primitives to it. |
| **@id**             | An identifer for the Array. If no @id is provided, one will be assigned automatically. | ...                       | ...                                                                              | "                                                                 |
| **elementSchema**   | The data type of each element in the Array, which is an instance of Schema.            | **items.type**            | The definition of the array type is based on DataSchema Types                    | "                                                                 |
| -                   |                                                                                        | **minItems**        | Defines the minimum number of items that have to be in the array.              | "                                                                 |
| -                  |                                                                                        | **maxItems**        | Defines the maximum number of items that have to be in the array.                | "                                                                 |


### Note

The JSON Schema array can be more general in that it allows a mix of types for the elements. Using the ```elementType``` keyword form JSON Schema expresses the same constraints as the array schema in DTDL. So any DTDL array can be expressed in JSON Schema, but not all JSON Schema arrays can be expressed as DTDL.

### Examples

#### _DTDL v3_

```json

{
  "@type": "Telemetry",
  "name": "ledState",
  "schema": {
    "@type": "Array",
    "elementSchema": "boolean"
  }
}

```

#### _Thing Model 1.1_

```json
"ledState": {
  "type": "array",
  "items": {
    "type": "boolean"
  },
  "minItems": 3,
  "maxItems": 3
}

```

## Enum

| DTDL Term / Concept | DTDL Description                                                                      | WoT TD Term | WoT TD Description                                      | Comments                                   |
|---------------------|---------------------------------------------------------------------------------------|-------------|---------------------------------------------------------|--------------------------------------------|
| **@type**           | This must be "Enum".                                                                  | -         | ...                                                     | Proposal is to merge JSON Schema with DTDL |
| **@id**             | An identifer for the Enum. If no @id is provided, one will be assigned automatically. | **@id**         | Same definition as in DTDL                        | -                                          |
| **enumValues**      | A set of name/value mappings for the Enum.                                            | **oneOf**    | Must be valid against one of the subschemas          | "                                          |
| **valueSchema**     | The data type for the enumValues; all values must be of the same type.                | **type**    | Assignment of JSON-based data types compatible with JSON Schema   | "                                          |

### EnumValue

| DTDL Term / Concept | DTDL Description                                                       | WoT TD Term    | WoT TD Description                              | Comments                            |
|---------------------|------------------------------------------------------------------------|----------------|-------------------------------------------------|-------------------------------------|
| **@type**           | If provided, must be "EnumValue".                                      | -              | -                                               | Proposal is to keep DTDL definition |
| **@id**             | An identifer for the EnumValue. Assigned automatically if not provided | @id            | Same definition as in DTDL                      | "                                   |
| **name**            | The programming name of the element.                                   | **[].name**    | programming name of the value                   | "                                   |
| **enumValue**       | The on-the-wire value that maps to the EnumValue, which may be either an integer or a string. | **[].const**    | The const keyword is used to restrict a value to a single value.                   | "                                   |

### Note

Enum in JSON schema does not support labels for enum values. This proposal is based on this [this](https://github.com/w3c/wot-thing-description/issues/156#issuecomment-426902995) discussion in the WoT community.

### Examples

#### _DTDL v3_

Schema:
```json
{
  "@type": "Telemetry",
  "name": "state",
  "schema": {
    "@type": "Enum",
    "valueSchema": "integer",
    "enumValues": [
      {
        "name": "offline",
        "displayName": "Offline",
        "enumValue": 3
      },
      {
        "name": "online",
        "displayName": "Online",
        "enumValue": 4
      }
    ]
  }
}
```

Value:
```json
"state": 3
```

#### _Thing Model 1.1_

```json

"state": {
  "type": "integer",
  "oneOf": [
      {
        "const": 3,
        "name": "offline",
        "title": "Offline"
      },
      {
        "const": 4,
        "name": "online",
        "title": "Online"
      }
    ]
  }
}

```

## Object

| DTDL Term / Concept | DTDL Description                                                                        | WoT TD Term    | WoT TD Description                                                          | Comments                                                          |
|---------------------|-----------------------------------------------------------------------------------------|----------------|-----------------------------------------------------------------------------|-------------------------------------------------------------------|
| **@type**           | This must be "Object".                                                                  | **type**       | object                                                                      | Proposal is to use the JSON schema and map DTDL primitives to it. |
| **@id**             | An identifer for the Object. If no @id is provided, one will be assigned automatically. | ...            | ...                                                                         | "                                                                 |
| **fields**          | A set of field descriptions, one for each field in the Object.                          | **properties** | A dictionary of object properties which follow the DataSchema specification | "                                                                 |

### Field

A Field describes a field in an Object.

The chart below lists the properties that a Field may have.

| DTDL Term / Concept | DTDL Description                                                                       | WoT TD Term             | WoT TD Description                        | Comments                                                          |
|---------------------|----------------------------------------------------------------------------------------|-------------------------|-------------------------------------------|-------------------------------------------------------------------|
| **@type**           | If provided, must be "Field".                                                          | ...                     | ...                                       | Proposal is to use the JSON schema and map DTDL primitives to it. |
| **@id**             | An identifer for the Field. If no @id is provided, one will be assigned automatically. | ...                     | ...                                       | "                                                                 |
| **name**            | The programming name of the element.                                                   | **properties.key**      | the name is the key of a property field   | "                                                                 |
| **schema**          | The data type of the element, which is an instance of Schema.                          | **properties.key.type** | Type follows the DataSchema specification | "                                                                 |

### Examples

#### _DTDL v3_

```json

"schema": {
  "@type": "Object",
  "displayName": "playVideoRequest",
  "description": "playVideo action request",
  "fields": [
    {
      "@type": "Field",
      "displayName": "VideoIdentifier",
      "name": "identifier",
      "description": "The unique identifier of a Video",
      "schema": "string"
    },
    {
      "@type": "Field",
      "displayName": "VideoName",
      "name": "name",
      "description": "The name of a Video file",
      "schema": "string"
    },
    {
      "@type": "Field",
      "displayName": "Timestamp",
      "name": "timestamp",
      "description": "Request Timestamp",
      "schema": "dateTime"
    },
    {
      "@type": "Field",
      "displayName": "VideoUrl",
      "name": "url",
      "description": "The Video Url",
      "schema": "string"
    }
  ]
}

```

#### _Thing Model 1.1_

```json

{
 "type": "object",
 "description": "playVideo action request",
 "title": "playVideo Request",
 "properties": {
   "identifier": {
     "type": "string",
     "title": "Video Identifier",
     "description": "The unique identifier of a Video"
   },
   "name": {
     "type": "string",
     "title": "Video Name",
     "description": "The name of a Video file"
   },
   "timestamp": {
     "type": "string",
     "format": "date-time",
     "title": "Timestamp",
     "description": "Request Timestamp"
   },
   "url": {
     "type": "string",
     "title": "Video Url",
     "description": "The Video Url"
   }
}

```

## Geospatial Schemas

DTDL provides a set of geospatial schemas, based on [GeoJSON](https://geojson.org/), for modeling a variety of geographic data structures.

| DTDL Term / Concept | DTDL Description                                                            | WoT TD Term | WoT TD Description | Comments                    |
|---------------------|-----------------------------------------------------------------------------|-------------|--------------------|-----------------------------|
| **lineString**      | GeoJSON LineString - dtmi:standard:schema:geospatial:lineString;3           | **@type**   | Must be "geojson:LineString" | Proposal is to keep GEoJSON, but use JSON-LD + JSON Schema |
| **multiLineString** | GeoJSON MultiLineString - dtmi:standard:schema:geospatial:multiLineString;3 |**@type**   | Must be "geojson:MultiLineString" | "                   |
| **multiPoint**      | GeoJSON MultiPoint - dtmi:standard:schema:geospatial:multiPoint;3           |**@type**   | Must be "geojson:MultiPoint"      | "                   |
| **multiPolygon**    | GeoJSON MultiPolygon - dtmi:standard:schema:geospatial:multiPolygon;3       |**@type**   | Must be "geojson:MultiPolygon"    | "                   |
| **point**           | GeoJSON Point - dtmi:standard:schema:geospatial:point;3                     |**@type**   | Must be "geojson:Point"           | "                   |
| **polygon**         | GeoJSON Polygon - dtmi:standard:schema:geospatial:polygon;3                 |**@type**   | Must be "geojson:Polygon"         | "                   |

### Note

GeoJSON is well defined and supports both JSON-LD as well as JSON-Schema. The proposal is to just use these definitions in Thing Models, but not as mandatory, as there are other geospatial standards that are relevant in other fields.
If GeoJSON is used in Thing Models however, it can be recognized in DTDLs.

### Examples

#### _DTDL v3_

This example shows modeling the location of a device as Telemetry using the geospatial schema `point`.

```json

{
  "@type": "Telemetry",
  "name": "location",
  "schema": "point"
}

```

A Telemetry message sent by a particular device reporting its location would have the following structure in JSON (and equivalent structure in other serializations).

```json

{
  "location": {
    "type": "Point",
    "coordinates": [ 47.643742, -122.128014 ]
  }
}

```


#### _Thing Model 1.1_

```json
"location": {
  "@type": "geojson:Point",
  "type": "object",
  "$ref": "geojson" 
}
```



## Relationship

| DTDL Term / Concept | DTDL Description                                                                                           | WoT Term  | WoT Description                                          | Comments                      |
|---------------------|------------------------------------------------------------------------------------------------------------|-----------|----------------------------------------------------------|-------------------------------|
| **@type**           | If provided, must be "Relationship"                                                                        | **@type** | Use **dtdl:Relationship** for now           | Recommend semantic link type to W3C and use custom type **dtdl:Relationship** for now |
| **@id**             | Identifier for the Relationship. Assigned automatically if not provided.                                   | **@id**   |                                                          |                               |
| **comment**         | A comment for model authors                                                                                | -         |                                                          |                               |
| **description**     | Comment for model authors                                                                                  | -         |                                                          | "td:description"              |
| **displayName**     | A localizable name for display.                                                                            | -         |                                                          | "td:title"                    |
| **maxMultiplicity** | The max multiplicity for the realtionship target; defaults to the max allowable value                      | **dtdl:maxMultiplicity**  |                                                          | Use term in TM using context extension  |
| **minMultiplicity** | The min multiplicity for the realtionship target; defaults to the max allowable value                      | **dtdl:minMultiplicity**  |                                                          | Use term in TM using context extension  |
| **name**            | The programming name of the element.                                                                       | **rel**   | A link relation type identifies the semantics of a link. |  Proposal is to use the WoT definition. |
| **properties**      | A set of Properties that define Relationship-specific state.                                               | -         |                                                          |  Use custom terms with context extension |
| **target**          | An Interface identifier. If no target is specified, each instance target is permitted to be any Interface. | **href**  | Target IRI of a link or submission target of a form.     |  Proposal is to use the WoT definition. |
| **writable**        | A boolean value that indicates whether the Relationship is writable or not.                                | -         |                                                          | What does writable mean here? |

## Note

Annotations like ```description``` or ```displayName``` are not supported in a ```tm:link``` as it is not a dataschema/json-schema. 

### Examples

From `Ontologies/ISA95/CommonObjectModels/Part2/OperationsSchedule/OperationsSchedule.json` extended with multiplicity and properties

#### _DTDL v3_

```json
        {
            "@type": "Relationship",
            "name": "isMadeUpOf",
            "displayName": "Is made up of",
            "minMultiplicity": 0,
            "maxMultiplicity": 1,
            "properties": [
              {
                "@type": "Property",
                "name": "lastExecuted",
                "schema": "dateTime"
              }
            ],
            "description": "The operations requests that make up the operations schedule.",
            "target": "dtmi:digitaltwins:isa95:OperationsRequest;1"
        },
```


#### _Thing Model 1.1_

```json
        {
            "@type": "dtdl:Relationship",
            "rel": "isMadeUpOf",
            "title": "Is made up of",
            "dtdl:minMultiplicity": 0,
            "dtdl:maxMultiplicity": 1,
            "properties": [
              "lastExecuted: {
                "schema": "string",
                "format": "datetime"
              }
            ],
            "description": "The operations requests that make up the operations schedule.",
            "href": "dtmi:digitaltwins:isa95:OperationsRequest;1"
        },
```

## Component

| DTDL Term / Concept | DTDL Description                                                               | WoT TD Term       | WoT TD Description         | Comments |
|---------------------|--------------------------------------------------------------------------------|-------------------|----------------------------|----------|
| **@type**           | This must be "Component".                                                      | **links.rel**           | This must be "tm:submodel" | Proposal is to use the WoT definition.          |
| **@id**             | An identifer for the Component. If no @id is provided, assigned automatically. | **@id**           | Same as DTDL               |          |
| **comment**         | A comment for model authors.                                                   | -                 |                            |          |
| **description**     | A localizable description for display.                                         | -                 |                            |          |
| **displayName**     | A localizable name for display.                                                | -                 |                            |          |
| **name**            | The programming name of the element.                                           | -                 |                            |          |
| **schema**          | The data type of the Component, which is an instance of Interface.             | **href**/**type** | IRI of TM                  |          |

## Note

Annotations like ```description``` or ```displayName``` are not supported in a ```tm:submodel``` as it is not a dataschema/json-schema. 


### Examples

#### _DTDL v3_

```json
"content": [
    {
        "@type": "Component",
        "name": "description",
        "displayName": "Description",
        "description": "Contains additional information",
        "schema": "dtmi:digitaltwins:isa95:LangStringSet;1"
    },
]
```

#### _Thing Model 1.1_

```json
"links":[
    {
        "rel": "tm:submodel",
        "title": "Description",
        "description": "Contains additional information",
        "href": "dtmi:digitaltwins:isa95:LangStringSet;1"
    },
]
```

## Map

| DTDL Term / Concept | DTDL Description                                                                     | WoT TD Term | WoT TD Description | Comments                                             |
|---------------------|--------------------------------------------------------------------------------------|-------------|--------------------|------------------------------------------------------|
| **@type**           | This must be "Map".                                                                  | -           | Must be "object"   | Proposal is to use the JSON Schema definition        |
| **@id**             | An identifer for the Map. If no @id is provided, one will be assigned automatically. | -           |                    | "                                                    |
| **mapKey**          | A description of the keys in the Map.                                                | -           |                    | "                                                    |
| **mapValue**        | A description of the values in the Map.                                              | -           |                    | "                                                    |


### MapKey

| DTDL Term / Concept | DTDL Description                                                                        | WoT TD Term | WoT TD Description | Comments |
|---------------------|-----------------------------------------------------------------------------------------|-------------|--------------------|----------|
| **@type**           | If provided, must be "MapKey".                                                          | ...         | ...                | No equivalent in JSON Schema |
| **@id**             | An identifer for the MapKey. If no @id is provided, one will be assigned automatically. | ...         | ...                | "        |
| **comment**         | A comment for model authors.                                                            | ...         | ...                | "        |
| **description**     | A localizable description for display.                                                  | ...         | ...                | "        |
| **displayName**     | A localizable name for display.                                                         | ...         | ...                | "        |
| **name**            | The programming name of the element.                                                    | ...         | ...                | "        |
| **schema**          | The data type of the Map's key, which must be string.                                   | ...         | ...                | "        |

### MapValue

| DTDL Term / Concept | DTDL Description                                                        | WoT TD Term | WoT TD Description | Comments |
|---------------------|-------------------------------------------------------------------------|-------------|--------------------|----------|
| **@type**           | If provided, must be "MapValue".                                        | ...         | ...                | Proposal is to use the JSON Schema additionalProperties |
| **@id**             | An identifer for the MapValue. Assigned automatically if none provided. | ...         | ...                | "        |
| **comment**         | A comment for model authors.                                            | ...         | ...                | "        |
| **description**     | A localizable description for display.                                  | ...         | ...                | "        |
| **displayName**     | A localizable name for display.                                         | ...         | ...                | "        |
| **name**            | The programming name of the element.                                    | ...         | ...                | "        |
| **schema**          | The data type of the element, which is an instance of Schema.           | ...         | ...                | "        |

### Note

The difference to a DTDL object is that the DTDL describes a set of known keys with known value types, while a map allows an arbitrary number of unknown keys. This is consolidated within JSON-Schema in the object type, where ```additionalProperties``` can be used instead of ```properties```.

### Examples

#### _DTDL v3_

```json
{
  "@type": "Property",
  "name": "modules",
  "writable": true,
  "schema": {
    "@type": "Map",
    "mapKey": {
      "name": "moduleName",
      "schema": "string"
    },
    "mapValue": {
      "name": "moduleState",
      "schema": "string"
    }
  }
}
```

#### _Thing Model 1.1_

```json
"modules": {
 "@type": "dtdl:Map",
 "type": "object",
 "additionalProperties": {"type": "string", "title": "moduleState"}
}
```

#### _Value_
```json
"modules": {
  "moduleA": "operational_state",
  "moduleB": "stopped"
}
```

