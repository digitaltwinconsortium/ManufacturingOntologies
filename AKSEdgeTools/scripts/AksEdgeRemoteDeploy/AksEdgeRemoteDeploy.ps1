<#
  Sample script to deploy AksEdge via Intune
#>
param(
    [Switch] $UseK8s,
    [Switch] $UseMain
)
#Requires -RunAsAdministrator
New-Variable -Name gAksEdgeRemoteDeployVersion -Value "1.0.230203.1200" -Option Constant -ErrorAction SilentlyContinue
if (! [Environment]::Is64BitProcess) {
    Write-Host "Error: Run this in 64bit Powershell session" -ForegroundColor Red
    exit -1
}
Push-Location $PSScriptRoot
$installDir = "C:\AksEdgeScript"
$productName = "AKS Edge Essentials - K3s (Public Preview)"
$networkplugin = "flannel"
if ($UseK8s) {
    $productName ="AKS Edge Essentials - K8s (Public Preview)"
    $networkplugin = "calico"
}

# Here string for the json content
$jsonContent = @"
{
    "SchemaVersion": "1.1",
    "Version": "1.0",
    "AksEdgeProduct": "$productName",
    "AksEdgeProductUrl": "",
    "Azure": {
        "SubscriptionName": "Visual Studio Enterprise",
        "SubscriptionId": "",
        "TenantId": "",
        "ResourceGroupName": "aksedgepreview-rg",
        "ServicePrincipalName": "aksedge-sp",
        "Location": "EastUS",
        "CustomLocationOID":"",
        "Auth":{
            "ServicePrincipalId":"",
            "Password":""
        }
    },
    "AksEdgeConfig":{
        "SchemaVersion": "1.5",
        "Version": "1.0",
        "DeploymentType": "SingleMachineCluster",
        "Init": {
            "ServiceIPRangeSize": 0
        },
        "Network": {
            "NetworkPlugin": "$networkplugin",
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
    }
}
"@

###
# Main
###

#Download the AutoDeploy script
$starttime = Get-Date
$starttimeString = $($starttime.ToString("yyMMdd-HHmm"))
$transcriptFile = "$PSScriptRoot\aksedgedlog-$starttimeString.txt"
Start-Transcript -Path $transcriptFile

Set-ExecutionPolicy Bypass -Scope Process -Force
# Download the AksEdgeDeploy modules from Azure/AksEdge
$url = "https://github.com/Azure/AKS-Edge/archive/refs/tags/1.0.266.0.zip"
$zipFile = "1.0.266.0.zip"
if ($UseMain) {
    $url = "https://github.com/Azure/AKS-Edge/archive/main.zip"
    $zipFile = "main-$starttimeString.zip"
}

if (-not (Test-Path -Path $installDir)) {
    Write-Host "Creating $installDir..."
    New-Item -Path "$installDir" -ItemType Directory | Out-Null
}

if (!(Test-Path -Path "$installDir\$zipFile")) {
    try {
        Invoke-WebRequest -Uri $url -OutFile $installDir\$zipFile
    } catch {
        Write-Host "Error: Downloading Aide Powershell Modules failed" -ForegroundColor Red
        Stop-Transcript | Out-Null
        Pop-Location
        exit -1
    }
}

Expand-Archive -Path $installDir\$zipFile -DestinationPath "$installDir" -Force
$aidejson = (Get-ChildItem -Path "$installDir" -Filter aide-userconfig.json -Recurse).FullName
Set-Content -Path $aidejson -Value $jsonContent -Force

$aksedgeShell = (Get-ChildItem -Path "$installDir" -Filter AksEdgeShell.ps1 -Recurse).FullName
. $aksedgeShell

# invoke the workflow, the json file already stored above.
$retval = Start-AideWorkflow
# report error via Write-Error for Intune to show proper status
if ($retval) {
    Write-Host "Deployment Successful. "
} else {
    Write-Error -Message "Deployment failed" -Category OperationStopped
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1
}

$azConfig = (Get-AideUserConfig).Azure
if ($azConfig.Auth.ServicePrincipalId -and $azConfig.Auth.Password -and $azConfig.TenantId){
    #we have ServicePrincipalId, Password and TenantId
    $retval = Enter-AideArcSession
    if (!$retval) {
        Write-Error -Message "Azure login failed." -Category OperationStopped
        Stop-Transcript | Out-Null
        Pop-Location
        exit -1
    }
    # Arc for Servers
    Write-Host "Connecting to Azure Arc"
    $retval = Connect-AideArc
    Exit-AideArcSession
    if ($retval) {
        Write-Host "Arc connection successful. "
    } else {
        Write-Error -Message "Arc connection failed" -Category OperationStopped
        Stop-Transcript | Out-Null
        Pop-Location
        exit -1
    }
} else { Write-Host "No Auth info available. Skipping Arc Connection" }
# Arc for Kubernetes
$endtime = Get-Date
$duration = ($endtime - $starttime)
Write-Host "Duration: $($duration.Hours) hrs $($duration.Minutes) mins $($duration.Seconds) seconds"
Stop-Transcript | Out-Null
Pop-Location
exit 0
