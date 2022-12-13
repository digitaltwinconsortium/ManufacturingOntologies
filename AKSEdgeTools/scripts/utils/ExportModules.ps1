<#
  Sample script to export modules for remote deployment
#>
param(
    [String] $ExportDir = $((Get-Location).Path),
    [Switch] $AllTools,
    [Switch] $IncludeSamples
)# Here string for the json content

$RootDir = "$PSScriptRoot\..\..\.."
$RootDir = (Resolve-Path -Path $RootDir).Path
$filesToZip = @(
    "$RootDir\License"
)

$ziptime = Get-Date -Format "yyMMdd-HHmm"
if (-not (Test-Path "$ExportDir")) {
    Write-Host "Creating $ExportDir..."
    New-Item -Path "$ExportDir" -ItemType Directory | Out-Null
}
$suffix = $ziptime
if ($IncludeSamples) {
    $filesToZip += @("$RootDir\samples")
    $suffix = "Samples-$ziptime"
}
if ($AllTools) {
    $filesToZip += @("$RootDir\tools")
    $suffix = "Tools-$suffix"
} else {
    $filesToZip += @(
        "$RootDir\tools\modules\AksEdgeDeploy",
        "$RootDir\tools\*.*"
    )
}
$zipFileName = "$ExportDir\aks-edge-$suffix.zip"
Compress-Archive -Path $filesToZip -DestinationPath $zipFileName -Force
Write-Host "$zipFileName"
