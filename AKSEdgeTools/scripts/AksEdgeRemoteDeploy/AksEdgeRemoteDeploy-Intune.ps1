<#
  Sample script to deploy AksEdge via Intune
  In Intune, set the following for the return values
  -1 : Retry
   2 : Hard reboot
   0 : Success
#>
param(
    [Switch] $RunToComplete,
    [Switch] $UseK8s
)
#Requires -RunAsAdministrator
New-Variable -Name gAksEdgeRemoteDeployVersion -Value "1.0.221208.0900" -Option Constant -ErrorAction SilentlyContinue
if (! [Environment]::Is64BitProcess) {
    Write-Host "Error: Run this in 64bit Powershell session" -ForegroundColor Red
    exit -1
}
# Here string for the json content
$installDir = "C:\AksEdgeScript"
$productName = "AKS Edge Essentials - K3s (Public Preview)"
if ($UseK8s) {
    $productName ="AKS Edge Essentials - K8s (Public Preview)"
}
$aksjson = "$installDir\Scripts\aide-userconfig.json"

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
        "Auth":{
            "ServicePrincipalId":"",
            "Password":""
        }
    },
    "AksEdgeConfig": {
        "DeployOptions": {
            "SingleMachineCluster": true,
            "NodeType": "Linux",
            "NetworkPlugin": "flannel",
            "Headless": true
        },
        "EndUser": {
            "AcceptEula": true,
            "AcceptOptionalTelemetry": true
        },
        "LinuxVm": {
            "CpuCount": 4,
            "MemoryInMB": 4096,
            "DataSizeinGB": 20
        }
    }
}
"@
$blobJson = @"
{
    "Storage": {
        "ConnectionString": "",
        "ContainerName": "",
        "BlobNames":["aks-edge-utils.zip"]
    }
}
"@

function Install-AzCli {
    #Check if Az CLI is installed. If not install it.
    $AzCommand = Get-Command -Name az -ErrorAction SilentlyContinue
    if (!$AzCommand) {
        Write-Host "> Installing AzCLI..."
        Push-Location $env:TEMP
        $progressPreference = 'silentlyContinue'
        Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi
        $progressPreference = 'Continue'
        Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /passive'
        Remove-Item .\AzureCLI.msi
        Pop-Location
        #Refresh the env variables to include path from installed MSI
        $Env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine")
        az config set core.disable_confirm_prompt=yes
        az config set core.only_show_errors=yes
        #az config set auto-upgrade.enable=yes
    }
    Write-Host "> Azure CLI installed" -ForegroundColor Green
    $extlist = (az extension list --query [].name | ConvertFrom-Json -ErrorAction SilentlyContinue)
    $reqExts = @("connectedmachine", "connectedk8s", "customlocation")
    foreach ($ext in $reqExts) {
        if ($extlist -and $extlist.Contains($ext)) {
            Write-Host "> az extension $ext installed" -ForegroundColor Green
        } else {
            Write-Host "Installing az extension $ext"
            az extension add --name $ext
        }
    }
}

function DownloadFromBlobStorage {
    param (
        [string]
        $downloadPath = "$(Get-Location)"
    )
    if (-not (Test-Path "$downloadPath")) {
        Write-Host "Creating $downloadPath..."
        New-Item -Path "$downloadPath\Scripts" -ItemType Directory | Out-Null
    }
    Push-Location "$downloadPath"
    $store = $Script:blobJson | ConvertFrom-Json
    Write-Host "Download from Azure blob storage..."
    $files = $store.Storage.BlobNames
    foreach ($file in $files) {
        if (-not (Test-Path -Path ".\$file")) {
            Write-Host "Downloading $file" -NoNewline
            $res = az storage blob download --connection-string $($store.Storage.ConnectionString) --container-name $($store.Storage.ContainerName) --file $file --name $file
            if ($res) { Write-Host " success.." }
            if (($file.contains('.zip')) -and (Test-Path -Path ".\$file")) {
                Write-Host "Expanding $file"
                Expand-Archive -Path "$file" -DestinationPath "$downloadPath\Scripts" -Force
            }
        } else { Write-Host "$file found. Skipping download."}
    }
    Pop-Location
}

function UploadToBlobStorage {
    param (
        [System.Array]
        $filesToUpload = $null
    )
    if (!$filesToUpload) { Write-Host "Nothing to upload"; return $false }
    $store = $Script:blobJson | ConvertFrom-Json
    foreach ($file in $filesToUpload){
        if (Test-Path "$file" -PathType Leaf) {
            Write-Host "Uploading $file..."
            $res = az storage blob upload --connection-string $store.Storage.ConnectionString --container-name $store.Storage.ContainerName --file $file
            if ($res) { Write-Host "Upload success.."}
        }
    }
}

function Import-AksEdgeModule {
    if (Get-Command New-AksEdgeDeployment -ErrorAction SilentlyContinue) { return }
    # Load the modules
    $aksjson = (Get-ChildItem -Path "$installDir\Scripts" -Filter aide-userconfig.json -Recurse).FullName
    $modulePath = Split-Path -Path $aksjson -Parent
    if (!(($env:PSModulePath).Contains($modulePath))) {
        $env:PSModulePath = "$modulePath;$env:PSModulePath"
    }
    Write-Host "Loading AksEdgeDeploy module.." -ForegroundColor Cyan
    Import-Module AksEdgeDeploy.psd1 -Force
    Set-AideUserConfig $aksjson
}
###
# Main
###

#Download the AutoDeploy script
Set-ExecutionPolicy Bypass -Scope Process -Force

if (-not (Test-Path "$installDir")) {
    Write-Host "Creating $installDir..."
    New-Item -Path "$installDir\Scripts" -ItemType Directory | Out-Null
}
$loop = $RunToComplete
do {
    $step = Get-ItemPropertyValue -Path HKLM:\SOFTWARE\AksEdgeScript -Name InstallStep -ErrorAction SilentlyContinue

    if (!$step) {
        New-Item -Path HKLM:\SOFTWARE\AksEdgeScript | Out-Null
        New-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name InstallStep -PropertyType String -Value "CheckHyperV" | Out-Null
        $step = "CheckHyperV"
    }
    
    $errCode = 1
    switch ($step) {
        "CheckHyperV" {
            $starttime = Get-Date
            $transcriptFile = "$installDir\aksedgedlog-hyperv-$($starttime.ToString("yyMMdd-HHmm")).txt"
            Start-Transcript -Path $transcriptFile
            $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V
            if ($feature.State -ne "Enabled") {
                Write-Host "Hyper-V is disabled" -ForegroundColor Red
                Write-Host "Enabling Hyper-V"
                Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart
                if ($aideSession.HostOS.IsServerSKU) {
                    Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-Management-PowerShell'
                    #Install-WindowsFeature -Name RSAT-Hyper-V-Tools -IncludeAllSubFeature
                }
                Write-Host "Reboot machine for enabling Hyper-V" -ForegroundColor Yellow
                $loop = $false
                $errCode = 2
                shutdown /r /t 30
            } else {
                Write-Host "Hyper-V is enabled" -ForegroundColor Green
                Set-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name InstallStep -Value "init"
                New-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name HyperVEnabled -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Stop-Transcript | Out-Null
            break;
        }
        "init" { # download bits
            $starttime = Get-Date
            $transcriptFile = "$installDir\aksedgedlog-init-$($starttime.ToString("yyMMdd-HHmm")).txt"
            Start-Transcript -Path $transcriptFile
            # Install Cli so that download from blob storage can be done
            Install-AzCli
            # Download the files from the azure blob storage
            DownloadFromBlobStorage $installDir
            if (!(Test-Path -Path "$installDir\Scripts")) {
                Write-Host "Error: Download stage failed" -ForegroundColor Red
                Stop-Transcript | Out-Null
                exit -1
            }
            $aksjson = (Get-ChildItem -Path "$installDir\Scripts" -Filter aide-userconfig.json -Recurse).FullName
            $jsonContent | Set-Content -Path $aksjson -Force
            Set-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name InstallStep -Value "DownloadDone"
            New-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name DownloadDone -PropertyType DWord -Value 1 | Out-Null
            $endtime = Get-Date
            $duration = ($endtime - $starttime)
            Write-Host "Duration: $($duration.Hours) hrs $($duration.Minutes) mins $($duration.Seconds) seconds"
            Stop-Transcript | Out-Null
            break;
        }
        "DownloadDone" {
            $starttime = Get-Date
            $transcriptFile = "$installDir\aksedgedlog-download-$($starttime.ToString("yyMMdd-HHmm")).txt"
            Start-Transcript -Path $transcriptFile
            Import-AksEdgeModule
            $aideVersion = (Get-Module -Name AksEdgeDeploy).Version.ToString()
            Write-Host "AksEdgeRemoteDeploy version  `t: $gAksEdgeRemoteDeployVersion"
            Write-Host "AksEdgeDeploy       version  `t: $aideVersion"
            Get-AideHostPcInfo
            if (!(Test-AideMsiInstall -Install)) {
                Write-Host "Error: Install stage failed" -ForegroundColor Red
                Stop-Transcript | Out-Null
                exit -1
            }
            Set-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name InstallStep -Value "InstallDone"
            New-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name InstallDone -PropertyType DWord -Value 1 | Out-Null
            $endtime = Get-Date
            $duration = ($endtime - $starttime)
            Write-Host "Duration: $($duration.Hours) hrs $($duration.Minutes) mins $($duration.Seconds) seconds"
            Stop-Transcript | Out-Null
            break;
        }
        "InstallDone" {
            $starttime = Get-Date
            $transcriptFile = "$installDir\aksedgedlog-install-$($starttime.ToString("yyMMdd-HHmm")).txt"
            Start-Transcript -Path $transcriptFile
            Import-AksEdgeModule
            if (Test-AideDeployment) {
                Write-Host "AKS edge VM is already deployed." -ForegroundColor Yellow
            } else {
                if (!(Test-AideVmSwitch -Create)) { 
                    Write-Host "Error: switch creation failed" -ForegroundColor Red
                    Stop-Transcript | Out-Null
                    exit -1
                } #create switch if specified
                # We are here.. all is good so far. Validate and deploy aksedge
                if (!(Invoke-AideDeployment)) {
                    Write-Host "Error: deployment failed" -ForegroundColor Red
                    Stop-Transcript | Out-Null
                    exit -1
                }
            }
            Set-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name InstallStep -Value "DeployDone"
            New-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name DeployDone -PropertyType DWord -Value 1 | Out-Null
            $endtime = Get-Date
            $duration = ($endtime - $starttime)
            Write-Host "Duration: $($duration.Hours) hrs $($duration.Minutes) mins $($duration.Seconds) seconds"
            Stop-Transcript  | Out-Null
            break;
        }
        "DeployDone" {
            $starttime = Get-Date
            $transcriptFile = "$installDir\aksedgedlog-deploy-$($starttime.ToString("yyMMdd-HHmm")).txt"
            Start-Transcript -Path $transcriptFile
            Import-AksEdgeModule
            $azConfig = (Get-AideUserConfig).Azure
            if ($azConfig.Auth.ServicePrincipalId -and $azConfig.Auth.Password -and $azConfig.TenantId){
                #we have ServicePrincipalId, Password and TenantId
                $retval = Enter-AideArcSession
                if (!$retval) {
                    Write-Error -Message "Azure login failed." -Category OperationStopped
                    Stop-Transcript | Out-Null
                    exit -1
                }
                Write-Host "Connecting to Azure Arc"
                $retval = Connect-AideArcKubernetes
                Exit-AideArcSession
                if ($retval) {
                    Write-Host "Arc connection successful. "
                } else {
                    Write-Error -Message "Arc connection failed" -Category OperationStopped
                    Stop-Transcript | Out-Null
                    exit -1
                }
            } else { Write-Host "No Auth info available. Skipping Arc Connection" }
            Set-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name InstallStep -Value "AllDone"
            New-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name AllDone -PropertyType DWord -Value 1 | Out-Null
            $endtime = Get-Date
            $duration = ($endtime - $starttime)
            Write-Host "Duration: $($duration.Hours) hrs $($duration.Minutes) mins $($duration.Seconds) seconds"
            Stop-Transcript  | Out-Null
            $errCode = 0
            $loop = $false
            break;
        }
        default {
            Write-Host "AKS edge is installed, deployed and connected to Arc"
            $errCode = 0
            $loop = $false
            break;
        }
    }
} While ($loop)

exit $errCode
