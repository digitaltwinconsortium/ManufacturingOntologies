param (
    [Parameter(Mandatory=$true)]
    [string]$dtName
)

az dt twin query -n $dtName -q "SELECT * FROM DIGITALTWINS WHERE IS_OF_MODEL('dtmi:digitaltwins:aas:AssetAdministrationShell;1')"