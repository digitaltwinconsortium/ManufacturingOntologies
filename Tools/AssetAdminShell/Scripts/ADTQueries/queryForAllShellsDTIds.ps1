param (
    [Parameter(Mandatory=$true)]
    [string]$dtName
)

az dt twin query -n $dtName -q "SELECT T.$dtId FROM DIGITALTWINS T WHERE IS_OF_MODEL(T, 'dtmi:digitaltwins:aas:AssetAdministrationShell;1')"