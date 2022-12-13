<#
  Script to install and connect Arc for Server based on json input file
#>
Param(
    [String]$jsonFile
)

#Requires -RunAsAdministrator
New-Variable -Option Constant -ErrorAction SilentlyContinue -Name azcmagentexe -Value "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe"

function Install-AideArcServer {
    if (Test-Path -Path $azcmagentexe -PathType Leaf) {
        Write-Host "> ConnectedMachineAgent is already installed" -ForegroundColor Green
        & $azcmagentexe version
        return
    }
    Write-Host "> Installing ConnectedMachineAgent..."
    Push-Location $env:TEMP
    # Download the installation package
    Invoke-WebRequest -Uri "https://aka.ms/azcmagent-windows" -TimeoutSec 30 -OutFile "$env:TEMP\install_windows_azcmagent.ps1"
    # Install the hybrid agent
    & "$env:TEMP\install_windows_azcmagent.ps1"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Failed to install the ConnectedMachineAgent agent : $LASTEXITCODE" -ForegroundColor Red
    } else {
        Write-Host "Setting up auto update via Microsoft Update"
        $ServiceManager = (New-Object -com "Microsoft.Update.ServiceManager")
        $ServiceID = "7971f918-a847-4430-9279-4a52d1efe18d"
        $ServiceManager.AddService2($ServiceId, 7, "") | Out-Null
    }
    Remove-Item .\AzureConnectedMachineAgent.msi
    Pop-Location
}

function Get-AideArcServerInfo {
    $vmInfo = @{}
    $apiVersion = "2020-06-01"
    $InstanceUri = $env:IMDS_ENDPOINT + "/metadata/instance?api-version=$apiVersion"
    $Proxy = New-Object System.Net.WebProxy
    $WebSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $WebSession.Proxy = $Proxy
    $response = (Invoke-RestMethod -Headers @{"Metadata" = "true"} -Method GET -Uri $InstanceUri -WebSession $WebSession) 
    $vmInfo.Add("Name", $response.compute.name)
    $vmInfo.Add("ResourceGroupName", $response.compute.resourceGroupName)
    $vmInfo.Add("SubscriptionId", $response.compute.subscriptionId)
    $vmInfo.Add("Location", $response.compute.location)
    return $vmInfo
}

###
# Main
###
if (-not $jsonFile) {
    $jsonFile = "$PSScriptRoot\AzureConfig.json"
}
if (-not(Test-Path -Path "$jsonFile" -PathType Leaf)) {
    Write-Host "Error: Incorrect input. Enter valid jsonFile path" -ForegroundColor Red
    exit -1
}
Write-Verbose "Loading $jsonFile.."
$jsonContent = Get-Content "$jsonFile" | ConvertFrom-Json

if ($jsonContent.Azure) {
    $aicfg = $jsonContent.Azure
} elseif ($jsonContent.SubscriptionId) {
    $aicfg = $jsonContent
} else {
    Write-Host "Error: Incorrect json content" -ForegroundColor Red
    exit -1
}
Write-Host "$aicfg"
if (!(Test-Path -Path $azcmagentexe -PathType Leaf)) {
    Write-Host "ConnectedMachineAgent is not installed. Installing now.." -ForegroundColor Gray
    Install-AideArcServer
}
$agentstatus = (& $azcmagentexe show)
if (!($($agentstatus | Select-String -Pattern 'Agent Status') -like '*Disconnected')) {
    Write-Host "ConnectedMachineAgent is connected." -ForegroundColor Green
    Get-AideArcServerInfo
    exit 0
}
Write-Host "ConnectedMachineAgent is disconnected." -ForegroundColor Yellow
Write-Host "Connecting now"
$connectargs = @( "--resource-group", "$($aicfg.ResourceGroupName)",
    "--tenant-id", "$($aicfg.TenantId)",
    "--location", "$($aicfg.Location)",
    "--subscription-id", "$($aicfg.SubscriptionId)",
    "--tags", "owner=AksEdge"
    "--cloud", "AzureCloud",
    "--service-principal-id", "$($aicfg.Auth.ServicePrincipalId)",
    "--service-principal-secret", "$($aicfg.Auth.Password)"
)
$hostSettings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select-Object ProxyServer, ProxyEnable
if ($hostSettings.ProxyEnable) {
    & $azcmagentexe config set proxy.url $($hostSettings.ProxyServer)
}
& $azcmagentexe connect @connectargs
if ($LastExitCode -eq 0) {
    Write-Host "ConnectedMachineAgent connected." -ForegroundColor Green
    Get-AideArcServerInfo
} else {
    Write-Host "Error in connecting to Azure: $LastExitCode" -ForegroundColor Red
}
exit 0