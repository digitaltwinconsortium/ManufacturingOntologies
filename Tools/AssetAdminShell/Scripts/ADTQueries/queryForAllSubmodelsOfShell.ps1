param (
    [Parameter(Mandatory=$true)]
    [string]$dtName,
    [Parameter(Mandatory=$true)]
    [string]$shellDtId
)

$queryString = "SELECT submodel FROM DIGITALTWINS MATCH (shell)-[:submodel]->(submodel) WHERE IS_OF_MODEL(shell, 'dtmi:digitaltwins:aas:AssetAdministrationShell;1') AND shell.`$dtId = '$shellDtId'"

az dt twin query -n $dtName -q $queryString -o json --query "result[].submodel.idShort"