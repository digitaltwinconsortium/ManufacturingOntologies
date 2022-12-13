# AksEdge Azure Setup

AksEdgeAzureSetup enables you to configure your Azure subscription for the use of Arc for Servers and Arc for Kubernetes for AKS-Lite.

Run the script `AksEdgeAzureSetup.ps1` in the `tools\scripts\AksEdgeAzureSetup` directory to

* setup your Azure subscription
* create the resource group
* setup the required extensions and
* create the service principal with minimal privileges listed below
  * `Azure Connected Machine Onboarding`
  * `Kubernetes Cluster - Azure Arc Onboarding`

You will need to login for Azure CLI interactively for the first time to create the service principal. This step is required to be run only once per subscription.

```powershell
# prompts for interactive login for serviceprincipal creation with minimal privileges
.\AksEdgeAzureSetup.ps1 .\AzureConfig.json
```

If you require to create the service principal with `Contributor` role at the resource group level, you can add the `-spContributorRole` switch.

```powershell
# creates service principal with Contributor role at resource group level
.\AksEdgeAzureSetup.ps1 .\AzureConfig.json -spContributorRole
```

To, reset an already existing service principal, use `-spCredReset`. Reset should be used cautiously.

```powershell
# resets the existing service principal
.\AksEdgeAzureSetup.ps1 .\AzureConfig.json -spCredReset
```

Test the credentials with

```powershell
# you can test the creds with 
.\AksEdgeAzureSetup-Test.ps1 .\AzureConfig.json
```
