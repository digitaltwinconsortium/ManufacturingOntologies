
# Create log dir and start logging
New-Item -Path "C:\Temp" -ItemType directory -Force
Start-Transcript "C:\Temp\Bootstrap.log"

$ErrorActionPreference = "SilentlyContinue"

# Installing tools
workflow ClientTools_01
{
    $chocolateyAppList = 'azure-cli'
    #Run commands in parallel.
    Parallel {
            InlineScript {
                param (
                    [string]$chocolateyAppList
                )
                if ([string]::IsNullOrWhiteSpace($using:chocolateyAppList) -eq $false)
                {
                    try{
                        choco config get cacheLocation
                    }catch{
                        Write-Output "Chocolatey not detected, trying to install now"
                        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
                    }
                }
                if ([string]::IsNullOrWhiteSpace($using:chocolateyAppList) -eq $false){
                    Write-Host "Chocolatey Apps Specified"

                    $appsToInstall = $using:chocolateyAppList -split "," | ForEach-Object { "$($_.Trim())" }

                    foreach ($app in $appsToInstall)
                    {
                        Write-Host "Installing $app"
                        & choco install $app /y -Force| Write-Output
                    }
                }
            }
    }
}
ClientTools_01 | Format-Table

# Enable VirtualMachinePlatform feature, the vm reboot will be done in DSC extension
Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart

# Disable Microsoft Edge sidebar
$RegistryPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$Name         = 'HubsSidebarEnabled'
$Value        = '00000000'
# Create the key if it does not exist
If (-NOT (Test-Path $RegistryPath)) {
  New-Item -Path $RegistryPath -Force | Out-Null
}
New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType DWORD -Force

# Disable Microsoft Edge first-run Welcome screen
$RegistryPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$Name         = 'HideFirstRunExperience'
$Value        = '00000001'
# Create the key if it does not exist
If (-NOT (Test-Path $RegistryPath)) {
  New-Item -Path $RegistryPath -Force | Out-Null
}
New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType DWORD -Force

Stop-Transcript
