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
New-Variable -Name gAksEdgeRemoteDeployVersion -Value "1.0.230203.1200" -Option Constant -ErrorAction SilentlyContinue
if (! [Environment]::Is64BitProcess) {
    Write-Host "Error: Run this in 64bit Powershell session" -ForegroundColor Red
    exit -1
}

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

function Import-AksEdgeModule {
    if (Get-Command New-AksEdgeDeployment -ErrorAction SilentlyContinue) { return }
    # Load the modules
    $aksedgeShell = (Get-ChildItem -Path "$installDir" -Filter AksEdgeShell.ps1 -Recurse).FullName
    . $aksedgeShell
}
###
# Main
###

#Download the AutoDeploy script
Set-ExecutionPolicy Bypass -Scope Process -Force

if (-not (Test-Path -Path $installDir)) {
    Write-Host "Creating $installDir..."
    New-Item -Path "$installDir" -ItemType Directory | Out-Null
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
            # Download the AksEdgeDeploy modules from Azure/AksEdge
            $url = "https://github.com/Azure/AKS-Edge/archive/refs/tags/1.0.266.0.zip"
            $zipFile = "1.0.266.0.zip"
            if (!(Test-Path -Path "$installDir\$zipFile")) {
                try {
                    Invoke-WebRequest -Uri $url -OutFile $installDir\$zipFile
                } catch {
                    Write-Host "Error: Downloading Aide Powershell Modules failed" -ForegroundColor Red
                    Stop-Transcript | Out-Null
                    exit -1
                }
            }
            Expand-Archive -Path $installDir\$zipFile -DestinationPath "$installDir" -Force
            $aksjson = (Get-ChildItem -Path "$installDir" -Filter aide-userconfig.json -Recurse).FullName
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
                $retval = Connect-AideArc
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
