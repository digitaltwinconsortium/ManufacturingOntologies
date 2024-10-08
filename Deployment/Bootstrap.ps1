
# Create log dir and start logging
New-Item -Path "C:\Temp" -ItemType directory -Force
Start-Transcript "C:\Temp\Bootstrap.log"

$ErrorActionPreference = "SilentlyContinue"

# Install AZ CLI and AKS-EE
msiexec /i https://aka.ms/installazurecliwindows /passive

# Download and expand Manufacturing Ontologies repo
invoke-webrequest -Uri https://github.com/digitaltwinconsortium/ManufacturingOntologies/archive/refs/heads/main.zip -OutFile C:\Manufacturing.zip
expand-archive -Path C:\Manufacturing.zip -DestinationPath C:\
del C:\Manufacturing.zip

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
