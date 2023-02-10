function SchemaValidator {
    <#
    .DESCRIPTION
        Validates the json configuration against defined schema
    #>
    param (
        [String]$schmeaPath,
        [String]$UserConfig
    )
    
    Add-Type -Path "$PSScriptRoot\Newtonsoft\Newtonsoft.Json.dll"
    Add-Type -Path "$PSScriptRoot\Newtonsoft\Newtonsoft.Json.Schema.dll" 

    $jsonString = $UserConfig | ConvertTo-Json
    $schemaString = Get-Content -Raw $schmeaPath

    $errorMessages = New-Object System.Collections.Generic.List[string]

    $retval = [Newtonsoft.Json.Schema.SchemaExtensions]::isValid([Newtonsoft.Json.Linq.JToken]::Parse($jsonString), [Newtonsoft.Json.Schema.JSchema]::Parse($schemaString), [ref]$errorMessages)
    if(-not $retval) {
        Write-Host $errorMessages
    }
    return $retval
}