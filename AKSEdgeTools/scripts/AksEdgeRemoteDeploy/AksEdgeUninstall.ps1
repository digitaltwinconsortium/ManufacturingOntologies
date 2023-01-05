<#
  Sample script to setup Azure subscription for Arc for Kubernetes Connection
#>
#Requires -RunAsAdministrator

if (! [Environment]::Is64BitProcess) {
    Write-Host "Error: Run this in 64bit Powershell session" -ForegroundColor Red
    exit -1
}
# Here string for the json content
$installDir = "C:\AksEdgeScript"

if (-not (Test-Path "$installDir\Scripts")) {
    Write-Host "Error: $installDir\Scripts not found." -ForegroundColor Red
    exit -1
}

$aksjson = (Get-ChildItem -Path "$installDir\Scripts" -Filter aide-userconfig.json -Recurse).FullName
$starttime = Get-Date
$transcriptFile = "$PSScriptRoot\aksedgedlog-uninstall-$($starttime.ToString("yyMMdd-HHmm")).txt"
Start-Transcript -Path $transcriptFile
# Load the modules
$modulePath = (Get-ChildItem -Path "$installDir\Scripts" -Filter AksEdgeDeploy -Recurse).FullName | Split-Path -Parent
if (!(($env:PSModulePath).Contains($modulePath))) {
    $env:PSModulePath = "$modulePath;$env:PSModulePath"
}
Write-Host "Loading AksEdgeDeploy module.."
Import-Module AksEdgeDeploy.psd1 -Force
Set-AideUserConfig $aksjson
Write-Host ">> Disconnecting from Arc"
Disconnect-AideArcServer
Disconnect-AideArcKubernetes
Write-Host ">> Removing cluster deployment"
Remove-AideDeployment
Write-Host ">> Removing external switches if any"
Remove-AideVmSwitch
Write-Host ">> Removing AksEdge installation"
Remove-AideMsi
$regkeyentry = Get-Item -Path HKLM:\SOFTWARE\AksEdgeScript
if ($regkeyentry) {
    Write-Host ">> Removing reg keys"
    Remove-Item -Path HKLM:\SOFTWARE\AksEdgeScript -Recurse -Force | Out-Null
}
$endtime = Get-Date
$duration = ($endtime - $starttime)
Write-Host "Duration: $($duration.Hours) hrs $($duration.Minutes) mins $($duration.Seconds) seconds"
Stop-Transcript  | Out-Null
exit 0