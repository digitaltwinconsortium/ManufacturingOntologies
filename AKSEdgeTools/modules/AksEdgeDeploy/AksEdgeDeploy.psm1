<#
    .DESCRIPTION
        This module contains the functions related to AksEdge setup on a PC
#>
#Requires -RunAsAdministrator
if (! [Environment]::Is64BitProcess) {
    Write-Host "Error: Run this in 64bit Powershell session" -ForegroundColor Red
    exit -1
}
# dot source the arc module
. $PSScriptRoot\AksEdge-Arc.ps1

#Hashtable to store session information
$aideSession = @{
    HostPC         = @{"FreeMem" = 0; "TotalMem" = 0; "FreeDisk" = 0; "TotalDisk" = 0; "TotalCPU" = 0; "Name" = $null }
    HostOS         = @{"OSName" = $null; "Name" = $null; "BuildNr" = $null; "Version" = $null; "IsServerSKU" = $false; "IsVM" = $false; "IsAzureVM" = $false }
    AKSEdge        = @{"Product" = $null; "Version" = $null }
    UserConfig     = $null
    UserConfigFile = $null
    ReadFromFile = $false
}
New-Variable -Option Constant -ErrorAction SilentlyContinue -Name aksedgeProductPrefix -Value "AKS Edge Essentials"
New-Variable -Option Constant -ErrorAction SilentlyContinue -Name aksedgeProducts -Value @{
    "AKS Edge Essentials - K8s (Public Preview)" = "https://aka.ms/aks-edge/k8s-msi"
    "AKS Edge Essentials - K3s (Public Preview)" = "https://aka.ms/aks-edge/k3s-msi"
}
New-Variable -Option Constant -ErrorAction SilentlyContinue -Name WindowsInstallUrl -Value "https://aka.ms/aks-edge/windows-node-zip"
New-Variable -Option Constant -ErrorAction SilentlyContinue -Name aksedgeValueSet -Value @{
    NodeType  = @("Linux", "LinuxAndWindows","Windows")
    NetworkPlugin = @("calico", "flannel")
}

New-Variable -Option Constant -ErrorAction SilentlyContinue -Name WindowsInstallFiles -Value @("AksEdgeWindows-v1.7z.001", "AksEdgeWindows-v1.7z.002", "AksEdgeWindows-v1.7z.003", "AksEdgeWindows-v1.exe")
function Get-AideHostPcInfo {
    <#
    .SYNOPSIS
        Prints the relevant HostPC information on the console output.

    .DESCRIPTION
        Prints the relevant HostPC information such as OS information, available Free/Total CPU/Memory on the console output.

    .OUTPUTS
        None

    .EXAMPLE
        Get-AideHostPcInfo
    #>
    Test-HyperVStatus -Enable | Out-Null
    $pOS = Get-CimInstance Win32_OperatingSystem
    $UBR = (Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name UBR)
    $aideSession.HostOS.OSName = $pOS.Caption
    $aideSession.HostOS.BuildNr = $pOS.BuildNumber
    $aideSession.HostOS.Version = "$($pOS.Version).$UBR"
    Write-Host "HostOS`t: $($pOS.Caption)($($pOS.OperatingSystemSKU)) `nVersion`t: $($aideSession.HostOS.Version) `nLang`t: $($pOS.MUILanguages) `nName`t: $($pOS.CSName)"
    #ProductTypeDomainController -Value 2 , #ProductTypeServer -Value 3
    $aideSession.HostPC.Name = $pOS.CSName
    $aideSession.HostOS.IsServerSKU = ($pOS.ProductType -eq 2 -or $pOS.ProductType -eq 3)
    $aideSession.HostPC.FreeMem = [Math]::Round($pOS.FreePhysicalMemory / 1MB) # convert kilo bytes to GB
    $pCS = Get-CimInstance -class Win32_ComputerSystem
    $aideSession.HostPC.TotalMem = [Math]::Round($pCS.TotalPhysicalMemory / 1GB)
    $aideSession.HostPC.TotalCPU = $pCS.numberoflogicalprocessors
    Write-Host "Total CPUs`t`t: $($aideSession.HostPC.TotalCPU)"
    Write-Host "Free RAM / Total RAM`t: $($aideSession.HostPC.FreeMem) GB / $($aideSession.HostPC.TotalMem) GB"
    $disk = Get-CimInstance Win32_LogicalDisk -Filter $("DeviceID='C:'") | Select-Object Size, FreeSpace
    $aideSession.HostPC.FreeDisk = [Math]::Round($disk.Freespace / 1GB) # convert bytes into GB
    $aideSession.HostPC.TotalDisk = [Math]::Round($disk.Size / 1GB) # convert bytes into GB
    Write-Host "Free Disk / Total Disk`t: $($aideSession.HostPC.FreeDisk) GB / $($aideSession.HostPC.TotalDisk) GB"
    if ((Get-CimInstance Win32_BaseBoard).Product -eq 'Virtual Machine') {
        $aideSession.HostOS.IsVM = $true
        Write-Host "Running as a virtual machine " -NoNewline
        if (Get-Service WindowsAzureGuestAgent -ErrorAction SilentlyContinue) {
            $aideSession.HostOS.IsAzureVM = $true
            Write-Host "in Azure environment " -NoNewline
            $vmInfo = Get-AzureVMInfo
            Write-Host "(Name= $($vmInfo.name)" -NoNewline
            Write-Host "vmSize= $($vmInfo.vmSize)" -NoNewline
            Write-Host "offer= $($vmInfo.offer)" -NoNewline
            Write-Host "sku= $($vmInfo.sku) )" -NoNewline
        }
        if ($pCS.HypervisorPresent) {
            Write-Host "with Nested Hyper-V enabled"
            #(Get-VMProcessor -VM $vm).ExposeVirtualizationExtensions
        } else {
            Write-Host "without Nested Hyper-V" -ForegroundColor Red
        }
    }
}
function Get-AideInfra {
    <#
    .SYNOPSIS
        Returns a coded string for the host OS information.

    .DESCRIPTION
        Returns a coded string for the host OS information including whether its Azure VM or regular VM

    .OUTPUTS
        String

    .EXAMPLE
        Get-AideInfra
    #>
    $replacements = [ordered]@{
        "Microsoft Windows" = "Win"
        "IoT Enterprise"    = "IoT"
        "Enterprise"        = "Ent"
        "Server"             = "Ser"
        "Datacenter"         = "DC"
        "Standard"           = ""
        "Evaluation"         = ""
        "2019"               = ""
        "2022"               = ""
        " "                  = ""
    }
    $Name = $aideSession.HostOS.OSName
    foreach ($key in $replacements.Keys) {
        $Name = $Name -replace $key, $replacements[$key]
    }
    $Name += "-$($aideSession.HostOS.BuildNr)"
    if ($aideSession.HostOS.IsAzureVM) {
        $Name += "-AVM"
    } elseif ($aideSession.HostOS.IsVM) {
        $Name += "-VM"
    }
    return $Name
}
function Get-AideUserConfig {
    <#
    .SYNOPSIS
        Returns the PSCustomObject of the UserConfig Json.

    .DESCRIPTION
        Returns the PSCustomObject of the UserConfig Json including the embedded AksEdge config data.

    .OUTPUTS
        PSCustomObject

    .EXAMPLE
        Get-AideUserConfig
    #>
    if ($null -eq $aideSession.UserConfig) {
        Write-Host "Error: Aide UserConfig is not set." -ForegroundColor Red
    }
    return $aideSession.UserConfig
}

function Get-AideAksEdgeConfig {
    if ($null -eq $aideSession.UserConfig) {
        Write-Host "Error: Aide UserConfig is not set." -ForegroundColor Red
    }
    return $aideSession.UserConfig.AksEdgeConfig
}
function Read-AideUserConfig {
    <#
    .SYNOPSIS
        Reads from the User Config json file and updates the PSCustomObject cache.

    .DESCRIPTION
        Reads from the User Config json file and updates the PSCustomObject cache. It also refreshes the AksEdge config data if it was read from AksEdgeConfigFile.

    .OUTPUTS
        Boolean
        True if successfully read.

    .EXAMPLE
        Read-AideUserConfig
    #>
    if ($aideSession.UserConfigFile) {
        $jsonContent = Get-Content "$($aideSession.UserConfigFile)" | ConvertFrom-Json
        $upgraded = UpgradeJsonFormat $jsonContent
        if ($jsonContent.AksEdgeProduct) {
            $aideSession.UserConfig = $jsonContent
            if ($upgraded) { Save-AideUserConfig }
            #if there is no AksEdgeConfig object or if it was previously read, re-read from file
            if ((-not $jsonContent.AksEdgeConfig) -or (($jsonContent.AksEdgeConfig)-and ($aideSession.ReadFromFile))) {
                #there is no embedded aksedge config, so read it from file
                $aksfile = $jsonContent.AksEdgeConfigFile
                if (($aksfile) -and (Test-Path -Path $aksfile)) {
                    $aksconfig = Get-Content $aksfile | ConvertFrom-Json
                    $aideSession.UserConfig | Add-Member -MemberType NoteProperty -Name 'AksEdgeConfig' -Value $aksconfig -Force
                }
            }
            return $true
        } else {
            Write-Host "Error: Incorrect json content" -ForegroundColor Red
        }
    } else { Write-Host "Error: Aide UserConfigFile not configured" -ForegroundColor Red }
    return $false
}
function Set-AideUserConfig {
    <#
    .SYNOPSIS
        Sets the user config PSCustomObject with either jsonFile or jsonString parameter.

    .DESCRIPTION
        Validates and sets the user config PSCustomObject with either jsonFile or jsonString parameter. Either one must be specified.

    .OUTPUTS
        Boolean
        True if successfully set.

    .PARAMETER jsonFile
        File path for the json configuration file (aide-userconfig.json), based on the aide-ucschema.json schema.

    .PARAMETER jsonString
        Json herestring based on the aide-ucschema.json schema.

    .EXAMPLE
        Set-AideUserConfig -jsonFile .\aide-userconfig.json
    #>
    Param
    (
        [String]$jsonFile,
        [String]$jsonString
    )
    if (-not [string]::IsNullOrEmpty($jsonString)) {
        $jsonContent = $jsonString | ConvertFrom-Json
        if ($jsonContent.AksEdgeProduct) {
            $aideSession.UserConfig = $jsonContent
            UpgradeJsonFormat $jsonContent | Out-Null
            if (-not $jsonContent.AksEdgeConfig) {
                #there is no embedded aksedge config, so read it from file
                $aksfile = $jsonContent.AksEdgeConfigFile
                if (($aksfile) -and (Test-Path -Path $aksfile)) {
                    $aksconfig = Get-Content $aksfile | ConvertFrom-Json
                    $aideSession.UserConfig | Add-Member -MemberType NoteProperty -Name 'AksEdgeConfig' -Value $aksconfig -Force
                    $aideSession.ReadFromFile = $true
                }
            }
        } else {
            Write-Host "Error: Incorrect jsonString" -ForegroundColor Red
            return $false
        }
    } else {
        if (($jsonFile) -and -not(Test-Path -Path "$jsonFile" -PathType Leaf)) {
            Write-Host "Error: Incorrect jsonFile " -ForegroundColor Red
            return $false
        }
        Write-Verbose "Loading $jsonFile.."
        $aideSession.UserConfigFile = "$jsonFile"
        return Read-AideUserConfig
    }
    return $true
}

function UpgradeJsonFormat {
    Param(
        [PSCustomObject] $jsonObj
    )
    $retval = $false
    $azCfg = $jsonObj.Azure
    if ($azCfg.Auth.spId) {
        $newAuth = @{
            ServicePrincipalId = $azCfg.Auth.spId
            Password = $azCfg.Auth.password
        }
        $azCfg | Add-Member -MemberType NoteProperty -Name 'Auth' -Value $newAuth -Force
        $retval = $true
    }
    if (($jsonObj.AksEdgeConfig) -or ($jsonObj.AksEdgeConfigFile)) { return $retval }
    if ($jsonObj.DeployOptions) {
        $fieldsToCopy = @("DeployOptions","LinuxVm","WindowsVm","Network","EndUser")
        $jsonObj | Add-Member -MemberType NoteProperty -Name 'AksEdgeConfig' -Value @{"SchemaVersion"="1.1";"Version"="1.0"} -Force
        $edgeConfig = [PSCustomObject]$jsonObj.AksEdgeConfig
        foreach ($field in $fieldsToCopy) {
            if ($jsonObj.$field){
                $edgeConfig | Add-Member -MemberType NoteProperty -Name $field -Value $jsonObj.$field -Force
                $jsonObj.PSObject.properties.remove($field)
            }
        }
        $jsonObj | Add-Member -MemberType NoteProperty -Name 'AksEdgeConfig' -Value $edgeConfig -Force
        $retval = $true
    }
    return $retval
}
function Save-AideUserConfig {
    <#
    .DESCRIPTION
        Saves the configuration to the JSON file
    #>
    if ($aideSession.UserConfigFile) {
        $ObjToSave = $aideSession.UserConfig
        if ($aideSession.ReadFromFile) {
            #we dont expect programatic changes to the aide-userconfig. Only in AksEdgeConfig
            $ObjToSave.AksEdgeConfig | ConvertTo-Json -Depth 4 | Format-AideJson | Set-Content -Path "$($ObjToSave.AksEdgeConfigFile)" -Force
        } else {
            $ObjToSave | ConvertTo-Json -Depth 4 | Format-AideJson | Set-Content -Path "$($aideSession.UserConfigFile)" -Force
        }
    } else {
        Write-Verbose "Error: Aide UserConfigFile not configured"
    }
}
function Get-AzureVMInfo {
    if (!$aideSession.HostOS.IsAzureVM) {
        Write-Host "Error: Host is not an Azure VM" -ForegroundColor Red
        return $null
    }
    $vmInfo = @{}
    #from https://github.com/microsoft/azureimds/blob/master/IMDSSample.ps1
    $ImdsServer = "http://169.254.169.254"
    $apiVersion = "2021-02-01"
    $InstanceUri = $ImdsServer + "/metadata/instance?api-version=$apiVersion"
    $Proxy = New-Object System.Net.WebProxy
    $WebSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $WebSession.Proxy = $Proxy
    $response = (Invoke-RestMethod -Headers @{"Metadata" = "true"} -Method GET -Uri $InstanceUri -WebSession $WebSession)
    $vmInfo.Add("Name", $response.compute.name)
    $vmInfo.Add("vmSize", $response.compute.vmSize)
    $vmInfo.Add("offer", $response.compute.offer)
    $vmInfo.Add("sku", $response.compute.sku)
    return $vmInfo
}
function Test-AideUserConfigNetwork {
    <#
    .DESCRIPTION
        Checks the AksEdge user configuration needed for AksEdge Network setup
    #>
    $errCnt = 0
    $aideConfig = Get-AideAksEdgeConfig

    $retval = Test-AksEdgeNetworkParameters -JsonConfigString ($aideConfig | ConvertTo-Json -Depth 4)
    if (!$retval) {
        $errCnt +=1
    }
    # 1) Check the virtual switch name
    $nwCfg = $aideConfig.Network
    if ($aideConfig.DeployOptions.SingleMachineCluster) {
        Write-Host "Checking Network configuration for SingleMachine Cluster"
        if ($nwCfg.ServiceIPRangeSize) {
            if (($nwCfg.ServiceIPRangeSize -ge 0) -and ($nwCfg.ServiceIPRangeSize -le 127)) {
                Write-Host "* ServiceIPRangeSize ok" -ForegroundColor Green
            } else {
                Write-Host "Error: ServiceIPRangeSize should be [0-127]" -ForegroundColor Red
                $errCnt += 1
            }
        }
        # Remove all other settings that are not relevant for single machine cluster
        $nwcfgToRemove = @("VSwitch", "ControlPlaneEndpointIp", "Ip4GatewayAddress",
            "Ip4PrefixLength", "ServiceIPRangeStart", "ServiceIPRangeEnd", "DnsServers")
        $nwitems = $nwCfg.PSObject.properties.Name
        foreach ($item in $nwitems) {
            if ($nwcfgToRemove -contains $item) {
                Write-Host "$item is redundant. Will be ignored" -ForegroundColor DarkGray
                $nwCfg.PSObject.properties.remove($item)
            }
        }
        if (($nwCfg) -and ($nwCfg.PSObject.properties.match('*').count -eq 0)) {
            $aideConfig.PSObject.properties.remove('Network')
        }
        if ($aideConfig.LinuxVm.Ip4Address) {
            Write-Host "Ignoring LinuxVm Ip4Address" -ForegroundColor DarkGray
            $aideConfig.LinuxVm.PSObject.properties.remove('Ip4Address')
        }
        if ($aideConfig.WindowsVm.Ip4Address) {
            Write-Host "Ignoring WindowsVm Ip4Address" -ForegroundColor DarkGray
            $aideConfig.WindowsVm.PSObject.properties.remove('Ip4Address')
        }
        return $errCnt
    }
    #Scalable Cluster type from here on. Check required parameters for Scalable
    if ($nwCfg.VSwitch.Type -ine 'External') {
        Write-Host "Error: VSwitch.Type should be External." -ForegroundColor Red
        $errCnt += 1
    }
    if ([string]::IsNullOrEmpty($nwCfg.VSwitch.Name)) {
        Write-Host "Error: VSwitch.Name is required." -ForegroundColor Red
        $errCnt += 1
    }
    if ([string]::IsNullOrEmpty($nwCfg.VSwitch.AdapterName)) {
        Write-Host "Error: VSwitch.AdapterName is required for External switch" -ForegroundColor Red
        $errCnt += 1
    } else {
        $nwadapters = (Get-NetAdapter -Physical) | Where-Object { $_.Status -eq "Up" }
        if ($nwadapters.Name -notcontains ($nwCfg.VSwitch.AdapterName)) {
            Write-Host "Error: $($nwCfg.VSwitch.AdapterName) not found. External switch creation will fail." -ForegroundColor Red
            Write-Host "Available NetAdapters : ($nwadapters | Out-String)"
            $errCnt += 1
        }
    }

    # 3) Check the virtual switch IP address allocation
    if (($nwCfg.Ip4PrefixLength -lt 0) -or ($nwCfg.Ip4PrefixLength -ge 32)) {
        Write-Host "Error: Invalid IP4PrefixLength $($nwCfg.Ip4PrefixLength). Should be [0-32]" -ForegroundColor Red
        $errCnt += 1
    } else { Write-Host "* IP4PrefixLength ok" -ForegroundColor Green }
    Write-Host "--- Verifying virtual switch IP address allocation..."
    [IPAddress]$mask = "255.255.255.0"
    $gwMask = ([IPAddress]$nwCfg.Ip4GatewayAddress).Address -band $mask.Address
    $errCnt += Test-IPAddress -ipAddress $nwCfg.Ip4GatewayAddress -paramName 'Ip4GatewayAddress' -isReachable
    $errCnt += Test-IPAddress -ipAddress $aideConfig.LinuxVm.Ip4Address -paramName 'LinuxVm.Ip4Address' -gatewayMask $gwMask
    if ($aideConfig.WindowsVm.Ip4Address) {
        $errCnt += Test-IPAddress -ipAddress $aideConfig.WindowsVm.Ip4Address -paramName 'WindowsVm.Ip4Address' -gatewayMask $gwMask
    }
    $errCnt += Test-IPAddress -ipAddress $nwCfg.ControlPlaneEndpointIp -paramName 'ControlPlaneEndpointIp' -gatewayMask $gwMask
    $errCnt += Test-IPAddress -ipAddress $nwCfg.ServiceIPRangeStart -paramName 'ServiceIPRangeStart' -gatewayMask $gwMask
    $errCnt += Test-IPAddress -ipAddress $nwCfg.ServiceIPRangeEnd -paramName 'ServiceIPRangeEnd' -gatewayMask $gwMask
    #TODO : Ping DnsServers for reachability. No Tests for http proxies
    Write-Host "--- Checking proxy settings..."
    if (![string]::IsNullOrEmpty($nwCfg.Proxy.Http) -and ($nwCfg.Proxy.Http -NotLike "http://*")) {
        Write-Host "Warning: The httpProxy address does not start with http://, $($nwCfg.Proxy.Http) may not valid." -ForegroundColor Yellow
        #$errCnt += 1
    }
    if (![string]::IsNullOrEmpty($nwCfg.Proxy.Https) -and ($nwCfg.Proxy.Https -NotLike "https://*")) {
        Write-Host "Warning: The httpsProxy address does not start with https://, $($nwCfg.Proxy.Https) may not valid." -ForegroundColor Yellow
        #$errCnt += 1
    }
    return $errCnt
}

function Test-IPAddress {
    Param([string]$ipAddress, [string]$paramName, [int]$gatewayMask, [Switch]$isReachable)
    $errCnt = 0
    if (-not ($ipAddress -as [IPAddress] -as [Bool])) {
        Write-Host "Error: $paramName Invalid IP4Address $ipAddress" -ForegroundColor Red
        $errCnt += 1
    } else {
        #Ping IP to ensure it is free
        $status = Test-Connection $ipAddress -Count 1 -Quiet
        if ($status) {
            if (!$isReachable) {
                Write-Host "Error: $paramName $ipAddress in use" -ForegroundColor Red
                $errCnt += 1
            }
        } else {
            if ($isReachable) {
                Write-Host "Error: $paramName $ipAddress is not reachable" -ForegroundColor Red
                $errCnt += 1
            }
        }
        [IPAddress]$mask = "255.255.255.0"
        if ( $gatewayMask -and ((([IPAddress]$ipAddress).Address -band $mask.Address ) -ne $gatewayMask)) {
            Write-Host "Error: Ip4GatewayAddress and $paramName $ipAddress are not in the same subnet" -ForegroundColor Red
            $errCnt += 1
        }
    }
    if (!$errCnt) {
        Write-Host "* $paramName ok" -ForegroundColor Green
    }
    return $errCnt
}
function Test-AideUserConfigInstall {
    $errCnt = 0
    $aideConfig = Get-AideUserConfig
    Write-Host "`n--- Verifying AksEdge Install Configuration..."

    # 1) Check the product requested is valid
    if ($aksedgeProducts.ContainsKey($aideConfig.AksEdgeProduct)) {
        if ($aideSession.AKSEdge.Product) {
            #if already installed, check if they match
            if ($aideSession.AKSEdge.Product -ne $aideConfig.AksEdgeProduct) {
                Write-Host "Error: Installed product $($aideSession.AKSEdge.Product) does not match requested product $($aideConfig.AksEdgeProduct)." -ForegroundColor Red
                $errCnt += 1
            } else { Write-Host "* $($aideConfig.AksEdgeProduct) is installed" -ForegroundColor Green }
        } else { Write-Host "* $($aideConfig.AksEdgeProduct) to be installed" -ForegroundColor Green }
    } else {
        Write-Host "Error: Incorrect aksedgeProduct." -ForegroundColor Red
        Write-Host "Supported products: [$($aksedgeProducts.Keys -join ',' )]"
        $errCnt += 1
    }
    $windowsRequired = $aideConfig.AksEdgeConfig.DeployOptions.NodeType -ilike '*Windows'
    # 2) Check if ProductUrl is valid if specified
    if (-not [string]::IsNullOrEmpty($aideConfig.AksEdgeProductUrl)) {
        if (Test-Path -Path $aideConfig.AksEdgeProductUrl) {
            $isOk = $true
            if($windowsRequired) {
                $filepath = (Resolve-Path -Path $aideConfig.AksEdgeProductUrl).Path | Split-Path -Parent
                foreach ($file in $WindowsInstallFiles) {
                    if (!(Test-Path -Path "$filepath\$file")) {
                        Write-Host "Error: $filepath\$file not found. Cannot deploy Windows Node." -ForegroundColor Red
                        $errCnt += 1; $isOk = $false
                    }
                }
            }
            if ($isOk) { Write-Host "Installing from local path - Ok" }
        } else {
            if (-not ([system.uri]::IsWellFormedUriString($aideConfig.AksEdgeProductUrl, [System.UriKind]::Absolute))) {
                Write-Host "Error: aksedgeProductUrl is incorrect. $($aideConfig.AksEdgeProductUrl)." -ForegroundColor Red
                $errCnt += 1
            }
        }
    }
    # 3) Check if the install options are proper
    $InstallOptions = $aideConfig.InstallOptions
    if ($InstallOptions) {
        $installOptItems = @("InstallPath", "VhdxPath")
        foreach ($item in $installOptItems) {
            $path = $InstallOptions[$item]
            if (-not [string]::IsNullOrEmpty($path) -and
            (-not (Test-Path -Path $path -IsValid))) {
                Write-Host "Error: Incorrect item. : $path" -ForegroundColor Red
                $errCnt += 1
            }
        }
    }

    if ($errCnt) {
        Write-Host "$errCnt errors found in the Install Configuration. Fix errors before Install" -ForegroundColor Red
    } else {
        Write-Host "*** No errors found in the Install Configuration." -ForegroundColor Green
    }
    return ($errCnt -eq 0)
}

function Test-AideUserConfigVMConfig {
    Param
    (
        [Parameter(Position = 0, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [PSCustomObject]$vmCfg
    )
    $errCnt = 0
    if ($vmCfg.CpuCount -gt 1) {
        Write-Host "* Virtual machine will be created with $($vmCfg.CpuCount) vCPUs."
    } else {
        Write-Host "* 0 or 1 vCPU specified - Using default configuration, virtual machine will be created with 2 vCPUs."
        if ($vmCfg) { $vmCfg.PSObject.properties.remove('CpuCount') }
    }
    if ($vmCfg.MemoryInMB -gt 0) {
        Write-Host "* Virtual machine will be created with $($vmCfg.MemoryInMB) MB of memory."
    } else {
        Write-Host "* No custom memory used - Using default configuration, virtual machine will be created with 2048 MB of memory."
        if ($vmCfg) { $vmCfg.PSObject.properties.remove('MemoryInMB') }
    }
    if ($vmCfg.DataSizeInGB) {
        if (($vmCfg.DataSizeInGB -ge 2) -and ($vmCfg.DataSizeInGB -le 2048)) {
            #Between 2 GB and 2 TB
            Write-Host "* Virtual machine VHDX will be created with $($vmCfg.DataSizeInGB) GB of data size."
        } else {
            Write-Host "Error: VmDataSizeInGB should be between 2 GB and 2048 GB(2TB)" -ForegroundColor Red
            $errCnt += 1
        }
    } else {
        Write-Host "* No custom data size used - Using default configuration, virtual machine VHDX will be created with 2 GB of data size."
        if ($vmCfg) { $vmCfg.PSObject.properties.remove('DataSizeInGB') }
    }
    return $errCnt
}
function Test-AideUserConfigDeploy {
    <#
    .DESCRIPTION
        Checks the AksEdge user configuration needed for AksEdge VM deployment
        Return $true if no blocking errors are found, and $false otherwise
    #>
    $errCnt = 0
    $aideConfig = Get-AideAksEdgeConfig
    $euCfg = $aideConfig.EndUser
    Write-Host "`n--- Verifying AksEdge VM Deployment Configuration..."
    # 1) Check Mandatory configuration EULA
    Write-Host "--- Verifying EULA..."
    if ($euCfg.AcceptEula) {
        Write-Host "* EULA accepted." -ForegroundColor Green
    } else {
        Write-Host "Error: Missing/incorrect mandatory EULA acceptance. Set AcceptEula true for remote deployment" -ForegroundColor Red
        $errCnt += 1
    }

    if ($euCfg.AcceptOptionalTelemetry) {
        Write-Host "* Optional telemetry accepted." -ForegroundColor Green
    }
    <# if this is set to false, currently it queries during deployment.
    else {
        Write-Host "- Optional telemetry not accepted. Basic telemetry will be sent." -ForegroundColor Yellow
        if ($euCfg) { $euCfg.PSObject.properties.remove('AcceptOptionalTelemetry') }
    }#>

    $doCfg = $aideConfig.DeployOptions
    foreach ($key in $aksedgeValueSet.Keys) {
        if ($($doCfg.$key)) {
            if ($aksedgeValueSet[$key] -icontains $($doCfg.$key)) {
                Write-Host "* DeployOptions $key ok." -ForegroundColor Green
            } else {
                Write-Host "Error: DeployOptions ($key : $($doCfg.$key)) is incorrect." -ForegroundColor Red
                $errCnt += 1
            }
        }
    }

    #Check for mutually exclusive flags
    if (($doCfg.JoinCluster) -and ($doCfg.SingleMachineCluster)) {
        Write-Host "Error: JoinCluster and SingleMachineCluster are both specified" -ForegroundColor Red
        $errCnt += 1
    }

    # 2) Check the virtual switch specified
    if (-not (Test-AideVmSwitch)) {
        $errCnt += 1
    }

    # 3) Check the virtual switch memory, cpu, and storage
    Write-Host "--- Verifying linux virtual machine resources..."
    if ($aideConfig.LinuxVm) {
        $errCnt += Test-AideUserConfigVMConfig $aideConfig.LinuxVm
    }
    Write-Host "--- Verifying windows virtual machine resources..."
    if ($aideConfig.WindowsVm) {
        $errCnt += Test-AideUserConfigVMConfig $aideConfig.WindowsVm
    }

    if ($errCnt) {
        Write-Host "$errCnt errors found in the Deployment Configuration. Fix errors before deployment" -ForegroundColor Red
    } else {
        Write-Host "*** No errors found in the Deployment Configuration." -ForegroundColor Green
    }
    return ($errCnt -eq 0)
}
function Test-AideUserConfig {
    <#
    .SYNOPSIS
        Validates the user config PSCustomObject for correctness and completeness.

    .DESCRIPTION
        Validates the user config PSCustomObject for correctness and completeness. Also validates if the required virtual switch is available.

    .OUTPUTS
        Boolean
        True if successfull.

    .EXAMPLE
        Test-AideUserConfig
    #>

    $installResult = Test-AideUserConfigInstall
    $deployResult = Test-AideUserConfigDeploy
    $arcResult = Test-AideArcUserConfig

    return ($installResult -and $deployResult -and $arcResult)

}
function Test-AideMsiInstall {
    <#
    .SYNOPSIS
        Validates if the requested AksEdge Msi flavour is installed.

    .DESCRIPTION
        Validates if the requested AksEdge Msi flavour is installed. The Switch -Install when specified will install the Msi if not found.
        It will also load the AksEdge module into the active PowerShell session.

    .OUTPUTS
        Boolean
        True if successfull.

    .PARAMETER Install
        Switch parameter , to install the Msi if not found.

    .EXAMPLE
        Test-AideMsiInstall
    #>
    Param
    (
        [Switch] $Install
    )

    $aksedgeVersion = Get-AideMsiVersion

    if ($null -eq $aksedgeVersion) {
        if (!$Install) { return $false }
        if (-not (Install-AideMsi)) { return $false }
    }

    $mod = Get-Module -Name AksEdge
    #check if module is loaded
    if (!$mod) {
        Write-Host "Loading AksEdge module.." -ForegroundColor Cyan
        Import-Module -Name AksEdge -Force -Global
    }
    $version = (Get-Module -Name AksEdge).Version.ToString()
    Write-Host "AksEdge version        `t: $version"
    return $true
}
function Test-HyperVStatus {
    Param
    (
        [Switch] $Enable
    )
    $retval = $true
    #Enable HyperV
    $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V
    if ($feature.State -ne "Enabled") {
        $retval = $false
        Write-Host "Hyper-V is disabled" -ForegroundColor Red
        if ($Enable) {
            Write-Host "Enabling Hyper-V"
            if ($aideSession.HostOS.IsServerSKU) {
                Install-WindowsFeature -Name Hyper-V -IncludeAllSubFeature -IncludeManagementTools
            } else {
                Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart
            }
            Write-Host "Rebooting machine for enabling Hyper-V" -ForegroundColor Yellow
            Restart-Computer -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "Hyper-V is enabled" -ForegroundColor Green
    }
    return $retval
}

function Test-AideLinuxVmRun {
    <#
    .SYNOPSIS
        Tests if the AksEdge Linux VM is running.

    .DESCRIPTION
        Tests if the AksEdge Linux VM is running.

    .OUTPUTS
        Boolean
        True if the VM is running.

    .EXAMPLE
        Test-AideLinuxVmRun
    #>
    $retval = $false
    if ($aideSession.HostOS.IsServerSKU) {
        $vm = Get-VM | Where-Object { $_.Name -like '*ledge' }
        if ($vm -and ($vm.State -ieq 'Running')) { $retval = $true }

    } else {
        $retval = (hcsdiag list) | ConvertFrom-String -Delimiter "," -PropertyNames Type, State, Id, Name
        $wssd = $retval | Where-Object { $_.Name.Trim() -ieq 'wssdagent' }
        if ($wssd -and ($wssd.State.Trim() -ieq 'Running')) { $retval = $true }
    }
    return $retval
}

New-Alias -Name mars -Value Invoke-AideLinuxVmShell
New-Alias -Name mars-read -Value Get-AideLinuxVmFile
New-Alias -Name mars-copy -Value Copy-AideLinuxVmFile

function Invoke-AideLinuxVmShell {
    <#
    .SYNOPSIS
        Invokes the AksEdge Linux VM Shell

    .DESCRIPTION
        Invokes the AksEdge Linux VM Shell

    .OUTPUTS
        None
        Launches into the Shell

    .EXAMPLE
        Invoke-AideLinuxVmShell
    #>
    if ($aideSession.HostOS.IsServerSKU) {
        Write-Host "Not supported yet"
        <#$vm = Get-VM | Where-Object { $_.Name -like '*edge' }
        if ($vm -and ($vm.State -ieq 'Running')) {
            $retval = $true }#>
    } else {
        $retval = (hcsdiag list) | ConvertFrom-String -Delimiter "," -PropertyNames Type, State, Id, Name
        $wssd = $retval | Where-Object { $_.Name.Trim() -ieq 'wssdagent' } | Select-Object -First 1
        if ($wssd -and ($wssd.State.Trim() -ieq 'Running')) {
            if ($args) {
                hcsdiag console $wssd.ID.Trim() $args
            } else {
                hcsdiag console $wssd.ID.Trim() su aksedge-user
            }
        } else {
            Write-Host "Error: VM is not deployed or VM is not running" -ForegroundColor Red
        }
    }
}

function Get-AideLinuxVmFile {
    <#
    .SYNOPSIS
        Invokes the AksEdge Linux VM Shell and reads file from the linux vm.

    .DESCRIPTION
        Invokes the AksEdge Linux VM Shell and reads file from the linux vm. This is not supported on ServerSKU.

    .OUTPUTS
        None

    .EXAMPLE
        Get-AideLinuxVmFile
    #>
    if ($aideSession.HostOS.IsServerSKU) {
        Write-Host "Not supported yet"
        <#$vm = Get-VM | Where-Object { $_.Name -like '*edge' }
        if ($vm -and ($vm.State -ieq 'Running')) {
            $retval = $true }#>
    } else {
        $retval = (hcsdiag list) | ConvertFrom-String -Delimiter "," -PropertyNames Type, State, Id, Name
        $wssd = $retval | Where-Object { $_.Name.Trim() -ieq 'wssdagent' } | Select-Object -First 1
        if ($wssd -and ($wssd.State.Trim() -ieq 'Running')) {
            hcsdiag read $wssd.ID.Trim() $args
        } else {
            Write-Host "Error: VM is not deployed or VM is not running" -ForegroundColor Red
        }
    }
}
function Copy-AideLinuxVmFile {
    <#
    .SYNOPSIS
        Invokes the AksEdge Linux VM Shell and copies file to the linux vm.

    .DESCRIPTION
        Invokes the AksEdge Linux VM Shell and copies file to the linux vm. This is not supported on ServerSKU.

    .ALIASES
        mars-copy

    .OUTPUTS
        None

    .EXAMPLE
        Get-AideLinuxVmFile
    #>
    if ($aideSession.HostOS.IsServerSKU) {
        Write-Host "Not supported yet"
        <#$vm = Get-VM | Where-Object { $_.Name -like '*edge' }
        if ($vm -and ($vm.State -ieq 'Running')) {
            $retval = $true }#>
    } else {
        $retval = (hcsdiag list) | ConvertFrom-String -Delimiter "," -PropertyNames Type, State, Id, Name
        $wssd = $retval | Where-Object { $_.Name.Trim() -ieq 'wssdagent' } | Select-Object -First 1
        if ($wssd -and ($wssd.State.Trim() -ieq 'Running')) {
            hcsdiag write $wssd.ID.Trim() $args
        } else {
            Write-Host "Error: VM is not deployed or VM is not running" -ForegroundColor Red
        }
    }
}

function Test-AideDeployment {
    <#
    .SYNOPSIS
        Checks if there is a AksEdge deployment on the machine.

    .DESCRIPTION
        Checks if there is a AksEdge deployment on the machine. It looks for the .vhdx files created for the Linux or Windows VMs.

    .OUTPUTS
        Boolean
        True if vhdx file is found.

    .EXAMPLE
        Test-AideDeployment
    #>

    $VhdxPath = "C:\\Program Files\\AksEdge"
    $aideConfig = Get-AideUserConfig
    if ($aideConfig.InstallOptions.VhdxPath) {
        $VhdxPath = $aideConfig.InstallOptions.VhdxPath
    }
    $retval = $false
    if (Get-ChildItem -Path $VhdxPath -Include *ledge.vhdx,*Image.vhdx -Recurse -ErrorAction SilentlyContinue)
    {
        $retval = $true
    }

    return $retval
}
function Install-AideMsi {
    <#
    .SYNOPSIS
        Checks and installs AksEdge Msi flavour specified in the aide-userconfig.json.

    .DESCRIPTION
        Checks and installs AksEdge Msi flavour specified in the aide-userconfig.json. When the AksEdgeProduct is specified, it installs the latest available version
        using the aka.ms links. When the AksEdgeProductUrl is specified, it installs from that specific Url. The Url can also be a network file share.

    .OUTPUTS
        Boolean
        True if installed successfully.

    .EXAMPLE
        Install-AideMsi
    #>
    #TODO : Add Force flag to uninstall and install req product
    if ($aideSession.AKSEdge.Version) {
        Write-Host "$($aideSession.AKSEdge.Product)-$($aideSession.AKSEdge.Version) is already installed"
        return $true
    }
    $aideConfig = Get-AideUserConfig
    if ($null -eq $aideConfig) { return $retval }
    if (-not (Test-AideUserConfigInstall)) { return $false } # bail if the validation failed
    $reqProduct = $aideConfig.AksEdgeProduct
    $url = $aksedgeProducts[$reqProduct]
    $winUrl = $WindowsInstallUrl
    $msiFile = ".\AksEdge.msi"
    $winFile = ".\AksEdgeWindows.zip"
    if ($aideConfig.AksEdgeProductUrl) {
        $url = $aideConfig.AksEdgeProductUrl
        $urlParent = Split-Path $url -Parent
        $winUrl = "$urlParent\AksEdgeWindows-*.zip"
    }
    Write-Host "Installing $reqProduct from $url"
    Push-Location $env:Temp
    $argList = '/I AksEdge.msi /qn '
    $windowsRequired = $aideConfig.DeployOptions.NodeType -ilike '*Windows'
    if (Test-Path -Path $url) {
        Copy-Item -Path $url -Destination $msiFile
        if($windowsRequired) {
            $filepath = (Resolve-Path -Path $url).Path | Split-Path -Parent
            foreach ($file in $WindowsInstallFiles) {
                Copy-Item -Path "$filepath\$file" -Destination .
            }
            $argList = '/I AksEdge.msi ADDLOCAL=CoreFeature,WindowsNodeFeature /passive '
        }
    } else {
        $ProgressPreference = 'SilentlyContinue'
        try {
            if (-not (Test-Path $msiFile)) {
                Invoke-WebRequest $url -OutFile $msiFile
            }
        } catch {
            Write-Host "failed to download from $url"
            Remove-Item $msiFile -Force -ErrorAction SilentlyContinue
            $ProgressPreference = 'Continue'
            Pop-Location
            return $false
        }
        if($windowsRequired) {
            $argList = '/I AksEdge.msi ADDLOCAL=CoreFeature,WindowsNodeFeature /passive '
            try {
                if (-not (Test-Path $winFile)) {
                    Invoke-WebRequest $winUrl -OutFile $winFile
                }
                if (Test-Path $winFile) {
                    Write-Host "Unzip WindowsInstallFiles.."
                    Expand-ArchiveLocal $winFile .
                }
            } catch {
                Write-Host "failed to download from $winUrl"
                Remove-Item $winFile -Force -ErrorAction SilentlyContinue
                $ProgressPreference = 'Continue'
                Pop-Location
                return $false
            }
        }
    }
    if ($aideConfig.InstallOptions) {
        $InstallPath = $aideConfig.InstallOptions.InstallPath
        if ($InstallPath) {
            $argList = $argList + "INSTALLDIR=""$($InstallPath)"" "
        }
        $VhdxPath = $aideConfig.InstallOptions.VhdxPath
        if ($VhdxPath) {
            $argList = $argList + "VHDXDIR=""$($VhdxPath)"" "
        }
    }
    Write-Verbose $argList
    Start-Process msiexec.exe -Wait -ArgumentList $argList
    #Refresh the env variables to include path from installed MSI
    $Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $retval = Test-AideMsiInstall
    if ($retval) {
        Remove-Item $msiFile
        if($windowsRequired) {
            foreach ($file in $WindowsInstallFiles) {
                Remove-Item ".\$file"
            }
            Remove-Item $winFile
        }
        Write-Host "$reqProduct successfully installed"
        $retval = $true
    } else {
        Write-Host "Error in install. Check installation" -ForegroundColor Red
        $retval = $false
    }
    Pop-Location
    $ProgressPreference = 'Continue'
    return $retval
}
function Expand-ArchiveLocal {
    Param(
        [string] $ZipFile,
        [string] $Destination
        )
    $Shell = New-Object -Comobject "Shell.Application"
    $zipContents = $Shell.Namespace((Convert-Path $ZipFile)).items()
    $DestinationFolder = $Shell.Namespace((Convert-Path $Destination))
    $DestinationFolder.CopyHere($zipContents)
}
function Remove-AideMsi {
    <#
    .SYNOPSIS
        Checks and removes the installed AksEdge Msi.

    .DESCRIPTION
        Checks and removes the installed AksEdge Msi. It also removes the AksEdge module from the active Powershell session, to avoid usage of the cached module after the msi is uninstalled.

    .OUTPUTS
        Boolean
        True if uninstalled successfully.

    .EXAMPLE
        Remove-AideMsi
    #>
    $aksedgeInfo = Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' | Get-ItemProperty |  Where-Object { $_.DisplayName -match "$aksedgeProductPrefix *" }
    if ($null -eq $aksedgeInfo) {
        Write-Host "$aksedgeProductPrefix is not installed."
    } else {
        Write-Host "$($aksedgeInfo.DisplayName) version $($aksedgeInfo.DisplayVersion) is installed. Removing..."
        Remove-AideDeployment | Out-Null
        Start-Process msiexec.exe -Wait -ArgumentList "/x $($aksedgeInfo.PSChildName) /passive /noreboot"
        # Remove the module from Powershell session as well
        Remove-Module -Name AksEdge -Force
        $aideSession.AKSEdge.Product = $null
        $aideSession.AKSEdge.Version = $null
        Write-Host "$($aksedgeInfo.DisplayName) successfully removed."
    }
}
function Get-AideMsiVersion {
    <#
    .SYNOPSIS
        Checks and returns the AksEdge Msi version.

    .DESCRIPTION
        Checks and returns the AksEdge Msi version. This is same as the AksEdge module version. (Get-Module AksEdge -ListAvailable).Version

    .OUTPUTS
        Hashtable with Name and Version keys.

    .EXAMPLE
        Get-AideMsiVersion
    #>
    $aksedgeInfo = Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' | Get-ItemProperty |  Where-Object { $_.DisplayName -match "$aksedgeProductPrefix *" }
    $retval = $null
    if ($null -eq $aksedgeInfo) {
        Write-Host "$aksedgeProductPrefix is not installed."
    } else {
        $retval = @{
            "Name"    = $($aksedgeInfo.DisplayName)
            "Version" = $($aksedgeInfo.DisplayVersion)
        }
        $aideSession.AKSEdge.Version = $aksedgeInfo.DisplayVersion
        $aideSession.AKSEdge.Product = $aksedgeInfo.DisplayName
        Write-Host "$($aksedgeInfo.DisplayName) $($aksedgeInfo.DisplayVersion) is installed." -ForegroundColor Green
    }
    return $retval
}

function Invoke-AideDeployment {
    <#
    .SYNOPSIS
        Checks the input json configuration and invokes the New-AksEdgeDeployment.

    .DESCRIPTION
        Checks the input json configuration and invokes the New-AksEdgeDeployment.

    .OUTPUTS
        Boolean
        True if deployment is successful.

    .EXAMPLE
        Invoke-AideDeployment
    #>
    if (Test-AideDeployment) {
        Write-Host "Error: AksEdge VM already deployed" -Foreground red
        return $false
    }
    if (-not (Test-AideUserConfigDeploy)) { return $false }
    $aideConfig = Get-AideAksEdgeConfig
    $aksedgeDeployParams = $aideConfig | ConvertTo-Json -Depth 4
    Write-Verbose "AksEdge VM deployment parameters for New-AksEdgeDeployment..."
    Write-Verbose "$aksedgeDeployParams"
    Write-Host "Starting AksEdge VM deployment..."
    $retval = New-AksEdgeDeployment -JsonConfigString $aksedgeDeployParams

    if ($retval -ieq "OK") {
        Write-Host "* AksEdge VM deployment successfull." -ForegroundColor Green
    } else {
        Write-Host "Error: AksEdge VM deployment failed with the below error message." -ForegroundColor Red
        Write-Host "Error message : $retval." -ForegroundColor Red
        return $false
    }

    return $true
}

function Remove-AideDeployment {
    <#
    .SYNOPSIS
        Invokes Remove-AksEdgeDeployment to remove the deployment.

    .DESCRIPTION
        Invokes Remove-AksEdgeDeployment to remove the deployment.

    .OUTPUTS
        Boolean
        True if deployment is successful.

    .EXAMPLE
        Remove-AideDeployment
    #>
    return Remove-AksEdgeDeployment
}
function Test-AideVmSwitch {
    <#
    .SYNOPSIS
        Tests if the specified VM Switch is available and the associated net adapter is connected.

    .DESCRIPTION
        Tests if the specified VM Switch is available and the associated net adapter is connected. If the -Create flag is specified, it attempts to create a VMMS switch.

    .OUTPUTS
        Boolean
        True if successfull.

    .PARAMETER Create
        Switch parameter , to create the switch if not found.

    .EXAMPLE
        Test-AideVmSwitch
    #>
    Param
    (
        [Switch] $Create
    )
    $retval = $true
    # Stubbed out for now
    $usrCfg = Get-AideAksEdgeConfig
    $vSwitch = $usrCfg.Network.VSwitch
    $switchName = $vSwitch.Name
    if (Test-AideUserConfigNetwork) { Write-Host "Errors in Network configuration." -ForegroundColor Red; return $false }

    if ($usrCfg.DeployOptions.SingleMachineCluster) {
        Write-Host "SingleMachine cluster uses internal switch. Nothing to test."
        return $true
    }
    # Scalable cluster - check if switch already present
    Write-Host "--- Verifying virtual switch..."
    if ([string]::IsNullOrEmpty($switchName)) { Write-Host "Switch name required" -ForegroundColor Red; return $false }
    $aksedgeSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue

    if ($aksedgeSwitch) {
        Write-Host "* Name:$($aksedgeSwitch.Name) - Type:$($aksedgeSwitch.SwitchType)" -ForegroundColor Green
        $netadapter = (Get-NetAdapter | Where-Object { $_.InstanceID -eq "{$($aksedgeSwitch.NetAdapterInterfaceGuid)}" } )
        if ($netadapter.Status -ieq 'Up') {
            Write-Host "* Name:$($netadapter.Name) is Up" -ForegroundColor Green
        } else {
            Write-Host "Error: NetAdapter $($netadapter.Name) is not Up.`nVMSwitch $name has not connectivity." -ForegroundColor Red
            $retval = $false
        }
    } else {
        # no switch found. Create if requested
        if ($Create) {
            $retval = New-AideVmSwitch
        } else {
            Write-Host "Error: VMSwitch $name not found." -ForegroundColor Red
            $retval = $false
        }
    }
    return $retval
}
function New-AideVmSwitch {
    <#
    .SYNOPSIS
        Creates the external VM Switch on the specified net adapter.

    .DESCRIPTION
        Creates the external VM Switch on the specified net adapter

    .OUTPUTS
        Boolean
        True if successfull.

    .EXAMPLE
        New-AideVmSwitch
    #>
    $usrCfg = Get-AideAksEdgeConfig
    $vSwitch = $usrCfg.Network.VSwitch

    $switchName = $vSwitch.Name
    $type = $vSwitch.Type
    $adapter = $vSwitch.AdapterName

    $aksedgeSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
    if ($aksedgeSwitch) {
        Write-Host "Error: Name:$($aksedgeSwitch.Name) - Type:$($aksedgeSwitch.SwitchType) already exists" -ForegroundColor Red
        return $false
    }
    # no switch found. Create now
    Write-Host "Creating VMSwitch $switchName - $type - $adapter..."
    $nwadapters = (Get-NetAdapter -Physical -ErrorAction SilentlyContinue) | Where-Object { $_.Status -eq "Up" }
    if ($nwadapters.Name -notcontains $adapter) {
        Write-Host "Error: $adapter not found or not connected. External switch not created." -ForegroundColor Red
        return $false
    }
    $aksedgeSwitch = New-VMSwitch -NetAdapterName $adapter -Name $switchName -ErrorAction SilentlyContinue
    # give some time for the switch creation to succeed
    Start-Sleep 10
    $aksedgeSwitchAdapter = Get-NetAdapter | Where-Object { $_.Name -eq "vEthernet ($switchName)" }
    if ($null -eq $aksedgeSwitchAdapter) {
        Write-Host "Error: [vEthernet ($switchName)] is not found. $switchName switch creation failed.  Please try switch creation again."
        return $false
    }
    return $true
}

function Remove-AideVmSwitch {
    <#
    .SYNOPSIS
        Removes the external VM Switch on the specified net adapter.

    .DESCRIPTION
        Removes the external VM Switch on the specified net adapter

    .OUTPUTS
        Boolean
        True if successfull.

    .EXAMPLE
        Remove-AideVmSwitch
    #>
    $usrCfg = Get-AideAksEdgeConfig
    $switchName = $($usrCfg.Network.VSwitch.Name)
    $aksedgeSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
    if ($aksedgeSwitch) {
        Write-Host "Removing $switchName"
        Remove-VMSwitch -Name $switchName
        if ($aksedgeSwitch.SwitchType -ieq "Internal") {
            $aksedgeNat = Get-NetNat -Name "$switchName-NAT"
            if ($aksedgeNat) {
                Write-Host "Removing $switchName-NAT"
                Remove-NetNat -Name "$switchName-NAT"
            }
        }
    }
}

# Main function for full functional path
function Start-AideWorkflow {
    <#
    .SYNOPSIS
        Runs the end to end workflow for AksEdgeDeploy. Based on the input jsonFile/jsonString, it installs required msi, creates switch and deploys the cluster.

    .DESCRIPTION
        Runs the end to end workflow for AksEdgeDeploy. Based on the input jsonFile/jsonString, it installs required msi, creates switch and deploys the cluster.
        This function also enables Hyper-V is it is not enabled and triggers a reboot. The function **doesnot resume** after reboot.

    .OUTPUTS
        Boolean
        True if successfully deployed.

    .PARAMETER jsonFile
        File path for the json configuration file (aide-userconfig.json), based on the aide-ucschema.json schema.

    .PARAMETER jsonString
        Json herestring based on the aide-ucschema.json schema.

    .EXAMPLE
        Start-AideWorkflow -jsonFile .\aide-userconfig.json
    #>
    Param
    (
        [String]$jsonFile,
        [String]$jsonString
    )
    $aideVersion = (Get-Module -Name AksEdgeDeploy).Version.ToString()
    Write-Host "AksEdgeDeploy version: $aideVersion"
    # Validate input parameter. Use default json in the same path if not specified
    if (-not [string]::IsNullOrEmpty($jsonString)) {
        $retval = Set-AideUserConfig -jsonString $jsonString
        if (!$retval) {
            Write-Host "Error: $jsonString incorrect" -ForegroundColor Red
            return $false
        }
    } else {
        if ([string]::IsNullOrEmpty($jsonFile)) {
            $jsonFile = "$PSScriptRoot\aide-userconfig.json"
        }
        if (!(Test-Path -Path "$jsonFile" -PathType Leaf)) {
            $aideConfig = Get-AideUserConfig
            if (!$aideConfig) {
                Write-Host "Error: $jsonFile not found" -ForegroundColor Red
                return $false
            }
        } else {
            $jsonFile = (Resolve-Path -Path $jsonFile).Path
            Set-AideUserConfig -jsonFile $jsonFile # validate later after creating the switch
        }
    }

    Get-AideHostPcInfo
    # Check PC prequisites (Hyper-V, AksEdge)
    if (!(Test-HyperVStatus -Enable)) { return $false } # todo resume after reboot. Intune will retry. Arc to be checked
    if (!(Test-AideMsiInstall -Install)) { return $false }

    # Check if AksEdge is deployed already and bail out
    if (Test-AideDeployment) {
        Write-Host "AksEdge VM is already deployed." -ForegroundColor Yellow
    } else {
        if (!(Test-AideVmSwitch -Create)) { return $false } #create switch if specified
        # We are here.. all is good so far. Validate and deploy aksedge
        if (!(Invoke-AideDeployment)) { return $false }
    }
    return $true
}
# Formats JSON in a nicer format than the built-in ConvertTo-Json does.
#  https://github.com/PowerShell/PowerShell/issues/2736
function Format-AideJson([Parameter(Mandatory, ValueFromPipeline)][String] $json) {
    <#
    .SYNOPSIS
        Pretty formats the input json.

    .DESCRIPTION
        Pretty formats the input json. Based on "https://github.com/PowerShell/PowerShell/issues/2736"

    .OUTPUTS
        String, formatted json string

    .PARAMETER json
        Input json string for formatting.

    .EXAMPLE
        Format-AideJson
    #>
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