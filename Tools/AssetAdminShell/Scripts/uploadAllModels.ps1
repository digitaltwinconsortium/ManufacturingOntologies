param (
    [Parameter(Mandatory=$true)]
    [string]$dtName
)

az dt model create --dt-name $dtName --from-directory "..\..\Ontology\metamodel"