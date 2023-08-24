param (
    [Parameter(Mandatory=$true)]
    [string]$subscriptionID,
    
    [Parameter(Mandatory=$true)]
    [string]$tenantID
)

Install-Module -Name AksHci -Force -AllowClobber -ErrorAction Stop
Connect-AzAccount -tenant $tenantID
Set-AzContext -Subscription $subscriptionID
Get-AzContext
$sp = New-AzADServicePrincipal -role "Owner" -scope /subscriptions/$subscriptionID
$secret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sp.Secret))
Write-Host "ClientId: $($sp.ApplicationId)"
Write-Host "ClientSecret: $secret"
