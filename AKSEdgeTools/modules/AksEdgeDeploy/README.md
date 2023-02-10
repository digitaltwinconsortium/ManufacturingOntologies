# AksEdgeDeploy (aide)

AksEdgeDeploy module enables you to automate the AKS edge installation, deployment and provisioning easily with a simple json specification.

The `Start-AideWorkflow` function in the modole does the following:

- Installs the required version of the AKS edge
- Validate the json parameters
- Creates the required network switch
- Deploys the AKS edge virtual machine with the json parameters
- Verifies the AKS edge virtual machine is up and running

## Usage

1. Populate the *aide-userconfig.json* with the desired parameters and values. Below is the minimal configuration example for a single machine deployment with 4GB memory.

    ```json
    {
        "SchemaVersion": "1.1",
        "Version": "1.0",
        "AksEdgeProduct" : "AKS Edge Essentials - K8s (Public Preview)",
        "AksEdgeConfig": {
            "SchemaVersion": "1.5",
            "Version": "1.0",
            "DeploymentType": "SingleMachineCluster",
            "Init": {
                "ServiceIPRangeSize": 0
            },
            "Network": {
                "NetworkPlugin": "flannel",
                "InternetDisabled": false
            },
            "User": {
                "AcceptEula": true,
                "AcceptOptionalTelemetry": true
            },
            "Machines": [
                {
                    "LinuxNode": {
                        "CpuCount": 4,
                        "MemoryInMB": 4096,
                        "DataSizeInGB": 20
                    }
                }
            ]
        },
        "Azure": {
            "SubscriptionName":"Visual Studio Enterprise",
            "SubscriptionId": "",
            "TenantId":"",
            "ResourceGroupName": "aksedgepreview-rg",
            "ServicePrincipalName" : "aksedge-sp",
            "Location" : "EastUS"
        }
    }
    ```

2. Call `Start-AideWorkflow` with the json file as input. This will perform the deployment.

```powershell
Start-AideWorkflow -jsonFile 'C:\MyConfigs\aide-userconfig.json'
```

## AksEdgeDeploy Config Json

Find below the details of the supported parameters in the json file.

|Node| Parameter | Required | Type / Values | Comments |
|-| --------- | -------- |---------------- | -------- |
|SchemaVersion| - | Mandatory | 1.1 | Fixed value, schema version. Reserved  |
|Version| - | Mandatory | 1.0 | Fixed value, json instance version  |
|AksEdgeProduct| - | Mandatory | AKS Edge Essentials - K8s <br> AKS Edge Essentials - K3s | Desired product K8s or K3s |
|AksEdgeProductUrl| - | Optional | URL | URL to download the MSI  |
|Azure | ClusterName | Optional | String | Name of the cluster for Arc connection. Default is hostname-distribution (abc-k8s or def-k3s)|
|| SubscriptionName | Mandatory | GUID | Name of the Azure Subscription  |
|| SubscriptionId | Optional | GUID | Azure Subscription ID  |
|| TenantId | Optional | GUID | Azure Tenant ID  |
|| ResourceGroupName | Mandatory | String | ResourceGroupName  |
|| ServicePrincipalName | Mandatory | String | ServicePrincipalName  |
|| Location | Mandatory | String | Location  |
|| CustomLocationOID | Optional | GUID | ObjectID for the custom location resource provider  |
|| `Auth`.ServicePrincipalId |Mandatory | GUID | Specify service principal appID to use|
|| `Auth`.Password |Mandatory| String | Specify the password (in clear) |
|InstallOptions| InstallPath | Optional | String |  Path to install the product  |
|| VhdxPath | Optional | String | Path to store the vhdx files  |
|VSwitch| Name | Optional | String | Name for the external switch, mandatory for ScalableCluster|
|| AdapterName | Optional | String | Name for the physical adapter, mandatory for ScalableCluster|
|AksEdgeConfigFile| - | Optional | String | File path to the AKS Edge Configuration json. Either `AksEdgeConfig` or `AksEdgeConfigFile` needs to be specified.|
|AksEdgeConfig| - | Optional | Json object | Embedded json object for AKS Edge Configuration|

![AksEdgeDeploy json](AksEdgeDeploy.png)

## AksEdge Config Json

![AksEdge Schema json](AksEdgeSchema.png)


## AKS Edge Essentials Arc Connection

The following functions enables you to install and use `Arc enabled Servers` and `Arc enabled Kubernetes` easily on a windows IoT device.

### Usage

1. Populate the *aide-userconfig.json* with the desired values.
2. Run the script [`AksEdgeAzureSetup.ps1`](../../scripts/AksEdgeAzureSetup/AksEdgeAzureSetup.ps1) in the `tools\scripts\AksEdgeAzureSetup` directory to setup your Azure subscription, create the resource group, setup the required extensions and also create the service principal with minimal privileges(`Azure Connected Machine Onboarding`,`Kubernetes Cluster - Azure Arc Onboarding`). You will need to login for Azure CLI interactively for the first time to create the service principal. This step is required to be run only once per subscription.

   ```powershell
   # prompts for interactive login for serviceprincipal creation with minimal privileges
    cd .\scripts\AksEdgeAzureSetup
   .\AksEdgeAzureSetup.ps1 .\aide-userconfig.json
   ```

    If you require to create the service principal with `Contributor` role at the resource group level, you can add the `-spContributorRole` switch.

    >[!Note] You will require the Contributor role if you need to disconnect your kubernetes cluster using `Disconnect-AideArcKubernetes`.
    To, reset an already existing service principal, use `-spCredReset`. Reset should be used cautiously.

   ```powershell
   # creates service principal with Contributor role at resource group level
   .\AksEdgeAzureSetup.ps1 .\aide-userconfig.json -spContributorRole
   ```

   ```powershell
   # resets the existing service principal
   .\AksEdgeAzureSetup.ps1 .\aide-userconfig.json -spCredReset
   ```

    ```powershell
   # you can test the creds with 
   .\AksEdgeAzureSetup-Test.ps1 .\aide-userconfig.json
   ```

3. Import the AksEdgeDeploy module and set the user config.
4. Run `Initialize-AideArc` to install the required software (Azure CLI) and validates that Azure setup is good.
5. `Connect-AideArcServer` to connect your machine to Arc-enabled server.
6. After installing AKS edge or any kuberenetes cluster in your Linux VM, verify with `kubectl get nodes` and then call `Connect-AideArcKubernetes`

```powershell
# installs AzCLI 
Initialize-AideArc
# Connects the Win IoT machine to Arc-enabled server
Connect-AideArcServer
# Prereq: install AKS edge and deploy cluster
# test the cluster is good
kubectl get nodes
# Connect the cluster to Arc-enabled Kubernetes
Connect-AideArcKubernetes
```

alternatively, you can use `Connect-AideArc` that enables both Arc-enabled server and Arc-enabled kubernetes.

```powershell
# installs AzCLI 
Initialize-AideArc
# connect both Arc-enabled server and kubernetes
Connect-AideArc
```

## Supported Functions

| Functions |
|:------------ |
|`Start-AideWorkflow -jsonFile (or) -jsonString`|
| Main funtion that validates the user config, installs AksEdge, creates switch, deploys and provisions VM |
|`Connect-AideArc`|
| Connects Arc-enabled server and Arc-enabled kubernetes|
|`Disconnect-AideArc`|
| Disconnects Arc-enabled server and Arc-enabled kubernetes|
</details>
<details><summary>User Config Functions</summary>

| |
|:------------ |
|`Get-AideUserConfig`|
| Returns the json object that is cached |
|`Set-AideUserConfig -jsonFile (or) -jsonString`|
| Sets the user config and reads the config into the cache |
|`Read-AideUserConfig`|
|Reads the json file into the cache |
|`Test-AideUserConfig`|
| Tests the User Config json for parameter correctness |
</details>
<details><summary>VM Switch Functions</summary>

| |
|:------------ |
|`New-AideVmSwitch`|
| Creates an new VM switch based on user config. |
|`Test-AideVmSwitch -Create`|
| Tests if the VM switch is present, `Create` flag invokes New-AideVmSwitch if switch is not present |
|`Remove-AideVmSwitch`|
| Removes the VM switch if present. Also removes the Nat if created (for internal switch) |

</details>
<details><summary>Deployment functions</summary>

| |
|:------------ |
|`Invoke-AideDeployment`|
| Validates the deployment parameters in user json and deploys AKS edge VM|
|`Test-AideDeployment`|
| Tests if the AKS edge VM is deployed (present) |
|`Remove-AideDeployment`|
| Removes the existing deployment |
|`Test-AideLinuxVmRun`|
| Tests if the AKS edge VM is running in the machine |
</details>
<details><summary>AksEdge MSI Install functions</summary>

| |
|:------------ |
|`Get-AideMsiVersion`|
| Returns the installed product name and version (PSCustom object with Name,Version) or Null if none found|
|`Install-AideMsi`|
| Installs the requested product from the aksedgeProductUrl if specified, otherwise it installs the latest (default)|
|`Test-AideMsiInstall -Install`|
| Tests if AKS edge is installed and `Install` switch is specified, it installs when not found|
|`Remove-AideMsi`|
| Removes the installed AKS edge product|
|`Get-AideHostPcInfo`|
| Gets the PC information such as OS version etc|
</details>
<details><summary>Azure Arc Install functions</summary>

| |
|:------------ |
|`Install-AideAzCli` |
| Installs Azure CLI |
|`Initialize-AideArc`|
| Main funtion that checks and installs required software, validates if the Auth parameters are good for Azure login  |
|`Enter-AideArcSession`|
| Logs in to Azure using the service principal credentials|
|`Exit-AideArcSession`|
| Logs out from the Azure CLI session|
</details>
<details><summary>Azure Arc-enabled Server Functions</summary>

| |
|:------------ |
|`Install-AideArcServer`|
| Installs Azure Connected Machine Agent |
|`Test-AideArcServer`|
| Tests ConnectedMachine Agent status (returns true if connected) |
|`Connect-AideArcServer`|
| Connects the machine to Arc-enabled server |
|`Disconnect-AideArcServer`|
| Removes the Arc-enabled server connection |
|`Get-AideArcServerInfo`|
| Returns the HIMDS info (name,subscriptionid,resourcegroupname and location) from Connected machine agent |
|`Get-AideArcServerSMI`|
| Retrieves the system assigned managed identity for Arc-enabled server|
</details>
<details><summary>Azure Arc-enabled Kubernetes Functions</summary>

| |
|:------------ |
|`Test-AideArcKubernetes`|
| Tests if the kubernetes cluster is connected to Arc |
|`Connect-AideArcKubernetes`|
| Connects the kubernetes cluster to Arc using the default kubeconfig files |
|`Disconnect-AideArcKubernetes`|
| Deletes the kubernetes cluster resource in Arc |
|`Get-AideArcKubernetesServiceToken`|
| Retrieves the service token for admin-user in the kubernetes cluster |
|`Get-AideArcClusterName`|
| Retrieves the cluster name used for Arc connection |
</details>
