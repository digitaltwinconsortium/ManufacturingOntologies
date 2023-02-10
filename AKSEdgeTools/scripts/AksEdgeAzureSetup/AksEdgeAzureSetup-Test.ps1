<#
  Sample script to setup Azure subscription for Arc for Kubernetes Connection
#>
Param(
    [String]$jsonFile
)

#Requires -RunAsAdministrator
New-Variable -Name gAksEdgeAzureSetupTest -Value "1.0.230109.1600" -Option Constant -ErrorAction SilentlyContinue

function Install-AzCli {
    #Check if Az CLI is installed. If not install it.
    $AzCommand = Get-Command -Name az -ErrorAction SilentlyContinue
    if (!$AzCommand) {
        $CLIPath = "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin"
        Write-Host "> Installing AzCLI..."
        Push-Location $env:TEMP
        $progressPreference = 'silentlyContinue'
        Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi
        $progressPreference = 'Continue'
        Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /passive'
        Remove-Item .\AzureCLI.msi
        Pop-Location
        [System.Environment]::SetEnvironmentVariable("Path", "$($CLIPath);$env:Path")
        az config set core.disable_confirm_prompt=yes
        az config set core.only_show_errors=yes
        #az config set auto-upgrade.enable=yes
    }
    Write-Host "> Azure CLI installed" -ForegroundColor Green
    <# Dont need extensions here.
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
    #>
}

###
# Main
###
Write-Host "gAksEdgeAzureSetupTest version  `t: $gAksEdgeAzureSetupTest"
if (($jsonFile) -and -not(Test-Path -Path "$jsonFile" -PathType Leaf)) {
    Write-Host "Error: Incorrect input. Enter valid jsonFile path or jsonString" -ForegroundColor Red
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
# Install Cli
Install-AzCli
Write-Host "$aicfg"
Write-Host ">> Testing the serviceprincpal access"
$session = (az login --service-principal -u $($aicfg.Auth.ServicePrincipalId) -p $($aicfg.Auth.Password) --tenant $aicfg.TenantId) | ConvertFrom-Json
if (-not $session){
    Write-Host "Error: Auth credentials are invalid" -ForegroundColor Red
    exit -1
}
(az account set --subscription $($aicfg.SubscriptionId)) | Out-Null
$session = (az account show | ConvertFrom-Json -ErrorAction SilentlyContinue)
Write-Host "Logged in $($session.name) subscription as $($session.user.name) ($($session.user.type))"
$rgname = $aicfg.ResourceGroupName
$rguri = "/subscriptions/$($aicfg.SubscriptionId)/resourceGroups/$rgname"
$roles = (az role assignment list --all --assignee $($session.user.name)) | ConvertFrom-Json
$reqRoles = @("Owner","Contributor")
$onbRoles = @("Azure Connected Machine Onboarding","Kubernetes Cluster - Azure Arc Onboarding")
$rolecnt = 0
if ($roles) {
    Write-Host "Roles enabled for this account are:" -ForegroundColor Cyan
    foreach ($role in $roles){
        $roledef = $($role.roleDefinitionName)
        Write-Host "$roledef for scope $($role.scope)" -ForegroundColor Cyan
        if ($($role.scope) -eq $rguri) {
            if ($reqRoles -contains $roledef ){
                $reqRoleFound = $true
            } elseif ($onbRoles -contains $roledef) {
                $rolecnt +=1
                if($rolecnt -eq 2) {$reqRoleFound = $true}
            }
        }
    }
}
if ($reqRoleFound){
    Write-Host "* You have sufficient privileges" -ForegroundColor Green
} else {
    Write-Host "x You do not have sufficient privileges for this service principal" -ForegroundColor Red
}
# Resource group
Write-Host "Checking $rgname..."
$rgexists = az group exists --name $rgname
if ($rgexists -ieq 'true') {
    Write-Host "* $rgname exists" -ForegroundColor Green
} else {
    Write-Host "$rgname not found" -ForegroundColor Red
}

# Check and enable namespaces
$namespaces = @("Microsoft.HybridCompute", "Microsoft.GuestConfiguration", "Microsoft.HybridConnectivity",
    "Microsoft.Kubernetes", "Microsoft.KubernetesConfiguration", "Microsoft.ExtendedLocation")
foreach ($namespace in $namespaces) {
    Write-Host "Checking $namespace..."
    $provider = (az provider show -n $namespace | ConvertFrom-Json -ErrorAction SilentlyContinue)
    if ($provider.registrationState -ieq "Registered") {
        Write-Host "* $namespace provider registered" -ForegroundColor Green
    } else {
        Write-Host "$namespace provider not registered." -ForegroundColor Red
    }
}
Write-Host "Setup test completed."
Write-Host "Logging out."
az logout
exit 0