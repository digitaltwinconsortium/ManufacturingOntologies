<#
  Sample script to setup Azure subscription for Arc for Kubernetes Connection
#>
Param(
    [String]$jsonFile,
    [switch]$spContributorRole,
    [switch]$spCredReset
)

#Requires -RunAsAdministrator
New-Variable -Name gAksEdgeAzureSetup -Value "1.0.221208.0900" -Option Constant -ErrorAction SilentlyContinue
New-Variable -Option Constant -ErrorAction SilentlyContinue -Name cliMinVersions -Value @{
    "azure-cli"        = "2.41.0"
    "azure-cli-core"   = "2.41.0"
}
function Test-AzVersions {
    #Function to check if the installed az versions are greater or equal to minVersions
    $retval = $true
    $curVersion = (az version) | ConvertFrom-Json
    if (-not $curVersion) { return $false }
    foreach ($item in $cliMinVersions.Keys ) {
        Write-Host " Checking $item minVersion $($cliMinVersions.$item).." -NoNewline
        $fgcolor = 'Green'
        if ($curVersion.$item) {
            Write-Verbose " Comparing $($curVersion.$item) -lt $($cliMinVersions.$item)."
            if ([version]$($curVersion.$item) -lt [version]$($cliMinVersions.$item)) {
                $retval = $false
                $fgcolor = 'Red'
            }
            Write-Host "found $($curVersion.$item)" -ForegroundColor $fgcolor
        }
    }
    return $retval
}
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
    if (-not (Test-AzVersions)) {
        Write-Host "> Required Az versions are not installed. Attempting az upgrade. This may take a while."
        az upgrade --all --yes
        if (-not (Test-AzVersions)) {
            Write-Host "Error: Required versions not found after az upgrade. Please try uninstalling and reinstalling" -ForegroundColor Red
        }
    }
}
# Formats JSON in a nicer format than the built-in ConvertTo-Json does.
#  https://github.com/PowerShell/PowerShell/issues/2736
function Format-Json([Parameter(Mandatory, ValueFromPipeline)][String] $json) {
    $indent = 0;
    ($json -Split '\n' |
    ForEach-Object {
        if ($_ -match '[\}\]]') {
            # This line contains  ] or }, decrement the indentation level
            $indent--
        }
        $line = (' ' * $indent * 2) + $_.TrimStart().Replace(':  ', ': ')
        if ($_ -match '[\{\[]') {
            # This line contains [ or {, increment the indentation level
            $indent++
        }
        $line
    }) -Join "`n"
}
###
# Main
###
Write-Host "AksEdgeAzureSetup version  `t: $gAksEdgeAzureSetup"
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
# Install Cli
Install-AzCli
Write-Host "$aicfg"
Write-Host "> az login to create/update service principal" -ForegroundColor Cyan
$loginparams = @("--scope", "https://graph.microsoft.com//.default" )
if ($($aicfg.TenantId)) {
    $loginparams += @("--tenant", $($aicfg.TenantId))
}
$session = (az login @loginparams) | ConvertFrom-Json
if (-not $session) {
    Write-Host "Error: Login failed. See error above and if required specify the tenantId in the input json file." -ForegroundColor Red
    exit -1
}

if ($($aicfg.SubscriptionId)) {
    #If SubscriptionId is specified, look for that in the session
    $reqSession = $session | Where-Object { ($_.id -eq $aicfg.SubscriptionId) -and ($_.state -eq 'Enabled') }
    if (!$reqSession) {
        Write-Host "Error: [$($aicfg.SubscriptionId)] not found or not enabled." -ForegroundColor Red
        Write-Host "Available subscription ids with state :" -ForegroundColor Cyan
        $subinfo = $session | Select-Object name, id, state
        Write-Host ($subinfo | Out-String)
        #Write-Host ($($session.id) -join "`n") -ForegroundColor Cyan
        az logout
        exit -1
    }
    (az account set --subscription $($aicfg.SubscriptionId)) | Out-Null
} elseif ($($aicfg.SubscriptionName)) {
    #If SubscriptionName is specified, look for that in the session
    $reqSession = $session | Where-Object { ($_.name -eq $aicfg.SubscriptionName) -and ($_.state -eq 'Enabled') }
    if (!$reqSession) {
        Write-Host "Error: [$($aicfg.SubscriptionName)] not found or not enabled." -ForegroundColor Red
        Write-Host "Available subscription names with state :" -ForegroundColor Cyan
        $subinfo = $session | Select-Object name, id, state
        Write-Host ($subinfo | Out-String)
        az logout
        exit -1
    }
    (az account set --subscription $($reqSession.id)) | Out-Null
} else {
    #nothing specified. So use the default subscription and continue
    if ($session.Count -gt 1) {
        Write-Host ">>> Multiple subscriptions found :"
        $subinfo = $session | Select-Object name, id , state
        Write-Host ($subinfo | Out-String)
        $sub = $session | Where-Object { $_.IsDefault -eq $true }
    } else { $sub = $session }
    Write-Host ">>> Default subscription is $($sub.name)[$($sub.id)]" -ForegroundColor Cyan
}

$session = (az account show | ConvertFrom-Json -ErrorAction SilentlyContinue)
$aicfg.SubscriptionId = $session.id
$aicfg.SubscriptionName = $session.name
$aicfg.TenantId = $session.tenantId

Write-Host "Logged in $($session.name) subscription as $($session.user.name) ($($session.user.type))" -ForegroundColor Cyan
Write-Host "TenantID       : $($aicfg.TenantId)" -ForegroundColor Cyan
Write-Host "SubscriptionId : $($aicfg.SubscriptionId)" -ForegroundColor Cyan
$hasRights = $false
$userinfo = (az ad signed-in-user show) | ConvertFrom-Json
Write-Host "User Principal Name : $($userinfo.userPrincipalName)"
Write-Host "Looking for Azure RBAC roles"
$adminroles = (az role assignment list --all --assignee $userinfo.userPrincipalName --include-inherited) | ConvertFrom-Json
if ($adminroles) {
    $reqRoles = @("Owner", "Contributor")
    Write-Host "Roles enabled for this account are:" -ForegroundColor Cyan
    foreach ($role in $adminroles) {
        Write-Host "$($role.roleDefinitionName) for scope $($role.scope)" -ForegroundColor Cyan
        if ($($role.scope) -eq "/subscriptions/$($aicfg.SubscriptionId)") {
            if ( $reqRoles -contains $($role.roleDefinitionName)) {
                Write-Host "* You have sufficient privileges" -ForegroundColor Green
                $hasRights = $true
            }
        }
    }
}

if (-not $hasRights) {
    # two stage call to work around issue reported here : https://github.com/Azure/azure-powershell/issues/15261 which occurs for CSP subscriptions
    # look for classic administrators only when there is no Azure RBAC roles defined
    Write-Host "Looking for classic administrator roles"
    $adminroles = (az role assignment list --include-classic-administrators) | ConvertFrom-Json
    $adminrole = $adminroles | Where-Object { $_.principalName -ieq $($session.user.name) }
    if ($adminrole) {
        Write-Host "Roles enabled for this account are:" -ForegroundColor Cyan
        foreach ($role in $adminrole) {
            Write-Host "$($role.roleDefinitionName) for scope $($role.scope)" -ForegroundColor Cyan
            if (($($role.scope) -eq "/subscriptions/$($aicfg.SubscriptionId)") -and (( $role.roleDefinitionName -match 'Administrator'))) {
                Write-Host "* You have sufficient privileges" -ForegroundColor Green
                $hasRights = $true
            }
        }
   }
}
if (-not $hasRights) {
    Write-Host "Error: You do not have sufficient privileges for this subscription $($aicfg.SubscriptionId)." -ForegroundColor Red
    az logout
    exit -1
}
# Resource group
$rgname = $aicfg.ResourceGroupName
Write-Host "Checking $rgname..."
$rgexists = az group exists --name $rgname
if ($rgexists -ieq 'true') {
    Write-Host "* $rgname exists" -ForegroundColor Green
} else {
    Write-Host "Creating $rgname resource group"
    $rg = (az group create --resource-group $rgname -l $aicfg.Location | ConvertFrom-Json -ErrorAction SilentlyContinue)
    if ($rg) {
        Write-Host "$($rg.name) resource group created" -ForegroundColor Green
    } else { 
        Write-Host "Error: Failed to create $rgname resource group" -ForegroundColor Red
        az logout
        exit -1
    }
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
        Write-Host "Registering $namespace provider. This can take some time. Please wait..." -ForegroundColor Yellow
        $provider = (az provider register -n $namespace --wait | ConvertFrom-Json -ErrorAction SilentlyContinue)
        Write-Host "$namespace provider registered successfully." -ForegroundColor Green
    }
}
# Create Service Principal

$spName = $aicfg.ServicePrincipalName
$spApp = (az ad sp list --display-name $spName | ConvertFrom-Json -ErrorAction SilentlyContinue)
$servicePrincipal = $null
if ($spApp -is [Array]) {$spApp = $spApp | Where-Object {$_.displayName -ieq $spName}; }
if ($spApp) {
    Write-Host "$spName is already present."
    #TODO : Check Roles for the spName
    $spRoles = (az role assignment list --all --assignee $($spApp.appId)) | ConvertFrom-Json
    $enableContributor = $false
    if ($spRoles) {
        Write-Host "Roles enabled for this account are:" -ForegroundColor Cyan
        foreach ($role in $spRoles){
            Write-Host "$($role.roleDefinitionName) for scope $($role.scope)" -ForegroundColor Cyan
            if ($($role.scope) -eq "/subscriptions/$($aicfg.SubscriptionId)/resourceGroups/$($aicfg.ResourceGroupName)") {
                if ($($role.roleDefinitionName) -ieq 'Contributor' ){
                    if ($spContributorRole) {
                        Write-Host "* Contributor role already enabled" -ForegroundColor Green
                    } else { $enableContributor = $true }
                }
            }
        }
    }
    if ($enableContributor) {
        Write-Host "Contributor role not found. Assigning Contributor role..."
        $roleparams = @(
            "--assignee", "$($spApp.appId)",
            "--role", "Contributor",
            "--scope", "/subscriptions/$($aicfg.SubscriptionId)/resourceGroups/$($aicfg.ResourceGroupName)"
        )
        $res = (az role assignment create @roleparams ) | ConvertFrom-Json
        if (!$res) { Write-Host " Error in assigning Contributor role " -ForegroundColor Red }
    }
    if ($spCredReset) {
        Write-Host "Resetting credentials.."
        $servicePrincipal = (az ad sp credential reset --id $spApp.appId | ConvertFrom-Json)
        if ($servicePrincipal) {
            Write-Host "ServicePrincipal credentials reset successfully"
        } else {
            Write-Host "ServicePrincipal reset failed"
            az logout
            exit -1
        }
    } else {
        $xml = "$env:USERPROFILE\.arciot\$($spName).xml"
        $backupxml = "$env:USERPROFILE\.arciot\$($spName)-backup.xml"
        if (!(Test-Path -Path $xml )) {
            Write-Host "Use existing password for $spName in Auth.Password field"
            Write-Host "ServicePrincipalId for $spName is $($spApp.appId)"
            az logout
            exit -1
        }
        Write-Host "Importing creds from $xml"
        $credinfo = Import-Clixml -Path $xml
        $servicePrincipal = @{
            "appId" = $credinfo.Credential.Username
            "password" = $credinfo.Credential.GetNetworkCredential().Password
        }
        Rename-Item -Path $xml -NewName $backupxml -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "$spName not found. Creating.."
    $spparams = @(
        "--name", "$spName",
        "--scopes", "/subscriptions/$($aicfg.SubscriptionId)/resourceGroups/$($aicfg.ResourceGroupName)"
    )
    if ($spContributorRole) {
        $spparams += @("--role", "Contributor")
    } else {
        $spparams += @("--role", "Azure Connected Machine Onboarding")
    }
    $servicePrincipal = (az ad sp create-for-RBAC @spparams | ConvertFrom-Json)
    if (!$servicePrincipal) {
        Write-Host "Error: ServicePrincipal creation failed" -ForegroundColor Red
        az logout
        exit -1
    }
    if (-not $spContributorRole) {
        #Assign the Kubernetes Cluster - Azure Arc Onboarding role to serviceprincipal too
        $roleparams = @(
            "--assignee", "$($servicePrincipal.appId)",
            "--role", "Kubernetes Cluster - Azure Arc Onboarding",
            "--scope", "/subscriptions/$($aicfg.SubscriptionId)/resourceGroups/$($aicfg.ResourceGroupName)"
        )
        $res = (az role assignment create @roleparams ) | ConvertFrom-Json
        if (!$res) { Write-Host " Error in assigning Kubernetes Cluster - Azure Arc Onboarding role " -ForegroundColor Red }
    }
}
Write-Host "$($servicePrincipal.appId)"
$ServicePrincipalId = $($servicePrincipal.appId)
$password = $($servicePrincipal.password)
if (!($aicfg.Auth)) {
    $aicfg | Add-Member -MemberType NoteProperty -Name 'Auth' -Value @{"ServicePrincipalId" = "$ServicePrincipalId"; "Password" = "$password"} -Force
} else {
    $aicfg.Auth.ServicePrincipalId = $ServicePrincipalId
    $aicfg.Auth.Password = $password
}
Write-Host "WARNING: The Service Principal password is stored in clear at $jsonFile" -ForegroundColor Yellow
$jsonContent | ConvertTo-Json | Format-Json | Set-Content -Path "$jsonFile" -Force
az logout
exit 0