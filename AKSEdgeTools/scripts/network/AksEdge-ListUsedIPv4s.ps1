function Convert-IPtoInt64 ($ip) { 
    $octets = $ip.split(".") 
    [int64]([int64]$octets[0] * 16777216 + [int64]$octets[1] * 65536 + [int64]$octets[2] * 256 + [int64]$octets[3]) 
}

function Convert-Int64toIP ([int64]$int) { 
    (([math]::truncate($int / 16777216)).tostring() + "." + ([math]::truncate(($int % 16777216) / 65536)).tostring() + "." + ([math]::truncate(($int % 65536) / 256)).tostring() + "." + ([math]::truncate($int % 256)).tostring() )
}

function Get-Subnet {
    <#
        .SYNOPSIS
            Code forked from https://www.powershellgallery.com/packages/Subnet/1.0.9/Content/Public%5CGet-Subnet.ps1
    #>
    Param ( 
        [string]
        $IP,

        [ValidateRange(0, 32)]
        [int]
        $MaskBits,

        [switch]
        $Force
    )
    Process {

        If ($PSBoundParameters.ContainsKey('MaskBits')) { 
            $Mask = $MaskBits 
        }

        If (-not $IP) { 
            $LocalIP = (Get-NetIPAddress | Where-Object { $_.AddressFamily -eq 'IPv4' -and $_.PrefixOrigin -ne 'WellKnown' })

            $IP = $LocalIP.IPAddress
            If ($Mask -notin 0..32) { $Mask = $LocalIP.PrefixLength }
        }

        If ($IP -match '/\d') { 
            $IPandMask = $IP -Split '/' 
            $IP = $IPandMask[0]
            $Mask = $IPandMask[1]
        }
        
        $IPAddr = [Net.IPAddress]::Parse($IP)

        $Class = Switch ($IP.Split('.')[0]) {
            { $_ -in 0..127 } { 'A' }
            { $_ -in 128..191 } { 'B' }
            { $_ -in 192..223 } { 'C' }
            { $_ -in 224..239 } { 'D' }
            { $_ -in 240..255 } { 'E' }
            
        }

        If ($Mask -notin 0..32) {
            $Mask = Switch ($Class) {
                'A' { 8 }
                'B' { 16 }
                'C' { 24 }
                default { Throw "Subnet mask size was not specified and could not be inferred because the address is Class $Class." }
            }

            Write-Host "Subnet mask size was not specified. Using default subnet size for a Class $Class network of /$Mask." -ForegroundColor Yellow
        }

        $MaskAddr = [IPAddress]::Parse((Convert-Int64toIP -int ([convert]::ToInt64(("1" * $Mask + "0" * (32 - $Mask)), 2))))        
        $NetworkAddr = [IPAddress]($MaskAddr.address -band $IPAddr.address) 
        $BroadcastAddr = [IPAddress](([IPAddress]::parse("255.255.255.255").address -bxor $MaskAddr.address -bor $NetworkAddr.address))
        
        $HostStartAddr = (Convert-IPtoInt64 -ip $NetworkAddr.ipaddresstostring) + 1
        $HostEndAddr = (Convert-IPtoInt64 -ip $broadcastaddr.ipaddresstostring) - 1

        $HostAddressCount = ($HostEndAddr - $HostStartAddr) + 1
        
        If ($Mask -ge 16 -or $Force) {
            
            Write-Host "`n5. Calcualting host addresses for $NetworkAddr/$Mask.." -ForegroundColor Green

            $HostAddresses = for ($i = $HostStartAddr; $i -le $HostEndAddr; $i++) {
                Convert-Int64toIP -int $i
            }
        }
        Else {
            Write-Host "Host address calculation was not performed because it would take some time for a /$Mask subnet. `nUse -Force if you want it to occur."
        }

        return $HostAddresses
    }
}

<#
    .DESCRIPTION
        This function uses Ping requests (ICMP) to discover devices on the network. Each Ping traffic is used to generate the arp-cache table. 
#>

Write-Host "WARNING: This tool uses ICMP & ARP requests to discover free network IP addresses. Firewalls may block these requests, limiting the use of the tool. If possible, please do a manual network check of your DHCP server or IP address allocation table." -ForegroundColor Yellow
Write-Host "`n1. Listing network adapters..." -ForegroundColor Green

# Print all the network adapters
Get-NetAdapter

do 
{
  Write-Host "`n2. Select ifIndex of desired network adapter scan:" -ForegroundColor Green
  $inputString = Read-Host
  $ifIndex = $inputString -as [Int]
  $ifIndexOk = $ifIndex -ne $NULL -and (Get-NetAdapter -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue) -ne $NULL
  if ( -not $ifIndexOk ) { Write-Host "Error: You must enter a valid ifIndex" -ForegroundColor Red }
}
until ( $ifIndexOk )

Write-Host "`n3. Selected adapter:  $($(Get-NetAdapter -InterfaceIndex $ifIndex).Name)" -ForegroundColor Green

# Ensure the adapter has a valid IP address and network range
$netIpConfig =  Get-NetIPConfiguration | Where-Object {$_.InterfaceIndex -eq $ifIndex}
if(!$netIpConfig)
{
    Write-Host "Error: $($(Get-NetAdapter -InterfaceIndex $ifIndex).Name) does not have a valid IP address. Please try again with another network adapter, or check your networking configurations." -ForegroundColor Red
    # Display message for 10s and then close
    Start-Sleep -Seconds 10
    return
}

# Get the IP Prefix length of the network
do 
{
  Write-Host "`n4. Select IP Prefix Length of the network:" -ForegroundColor Green
  $inputString = Read-Host
  $ipPrefix = $inputString -as [Int]
  $ipPrefixOk = $ipPrefix -ne $NULL -and $ipPrefix -gt 0 -and $ipPrefix -lt 33
  if ( -not $ipPrefixOk ) { Write-Host "Error: You must enter a valid IP Prefix Length between 1 and 32" -ForegroundColor Red }
}
until ( $ipPrefixOk )

$gatewayIp = $netIpConfig.IPv4DefaultGateway.NextHop;

# Get all the IP addresses of this subnet
$addresses = Get-Subnet -IP $gatewayIp -MasKBits $ipPrefix -Force

# Ping all the addresses
Write-Host "`n6. Ping Subnet..." -ForegroundColor Green
foreach ($address in $addresses)
{
  (New-Object System.Net.NetworkInformation.Ping).SendPingAsync("$address","1000") | Out-Null
}

# Wait until arp-cache: complete
while ($(Get-NetNeighbor).state -eq "incomplete") {
	Write-host "   Waiting..." -ForegroundColor Yellow
	timeout 1 | Out-Null
}

# Print all the arp-cache entries
Get-NetNeighbor -AddressFamily IPv4 -InterfaceIndex $ifIndex | Where-Object -Property state -ne Unreachable | select IPaddress,LinkLayerAddress,State, @{n="Hostname"; e={(Resolve-DnsName $_.IPaddress).NameHost}} | Out-GridView

if ($Host.Name -eq "ConsoleHost")
{
    Write-Host "`n4. Press any key to continue..." -ForegroundColor Green
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyUp") > $null
}
