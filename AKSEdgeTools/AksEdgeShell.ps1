<#
  AksEdgeShell.ps1
  Validates and loads the config file and imports the bootstrap scripts
#>
#Requires -RunAsAdministrator
New-Variable -Name gAksEdgeShellVersion -Value "1.0.230203.1200" -Option Constant -ErrorAction SilentlyContinue
if (! [Environment]::Is64BitProcess) {
    Write-Host "Error: Run this in 64bit Powershell session" -ForegroundColor Red
    exit -1
}

$aksjson = "$PSScriptRoot\aide-userconfig.json"
$aksjson = (Resolve-Path -Path $aksjson).Path
Push-Location $PSScriptRoot
$aksedgemodule = (Get-Module -Name AksIot -ListAvailable)
if ($aksedgemodule -and $aksedgemodule.Version.Minor -lt 7) {
    Write-Host "Older version of AKS edge found. Please uninstall.Press any key to exit." -ForegroundColor Red
    pause
    return
}

$modulePath = Split-Path -Path $((Get-ChildItem $PSScriptRoot -recurse -Filter AksEdgeDeploy).FullName) -Parent
if (!(($env:PSModulePath).Contains($modulePath))) {
    $env:PSModulePath = "$modulePath;$env:PSModulePath"
}

#remove AksEdgeDeploy module if already loaded
if (Get-Module -Name AksEdgeDeploy -ErrorAction SilentlyContinue) {
    Remove-Module -Name AksEdgeDeploy -Force -ErrorAction SilentlyContinue
}

Write-Host "Loading AksEdgeDeploy module from $modulePath.." -ForegroundColor Cyan
Import-Module AksEdgeDeploy.psd1 -Force
$aideVersion = (Get-Module -Name AksEdgeDeploy).Version.ToString()
Get-AideHostPcInfo

$retval = Test-AideMsiInstall
Write-Host "AksEdgeShell  version  `t: $gAksEdgeShellVersion"
Write-Host "AksEdgeDeploy version  `t: $aideVersion"

$feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V
if ($feature.State -ne "Enabled") {
    Write-Host "Hyper-V is disabled." -ForegroundColor Red
    if ($retval) {
        Write-Host "Running Install-AksEdgeHostFeatures (may reboot to enable Hyper-V)" -ForegroundColor Cyan
        if (!(Install-AksEdgeHostFeatures)) { return $false }
    }
} else {
    Write-Host "Hyper-V is enabled" -ForegroundColor Green
}


Set-AideUserConfig $aksjson | Out-Null
if (Test-AideDeployment) {
    Write-Host "AksEdge Cluster is already deployed" -ForegroundColor Green
    $wssdStatus = (Get-Service -Name WssdAgent).Status
    if ($wssdStatus -ne 'Running') {
        Write-Host "Error: WssdAgent is not running" -ForegroundColor Red
        Write-Host "Attempting to start wssdagent"
        Start-Service -Name WssdAgent
    }
}
