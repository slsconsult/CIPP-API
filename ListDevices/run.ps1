using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

$APIName = $TriggerMetadata.FunctionName
Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Accessed this API" -Sev "Debug"


# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Interact with query parameters or the body of the request.
$TenantFilter = $Request.Query.TenantFilter
try {
    $GraphRequest = New-GraphGetRequest -uri "https://graph.microsoft.com/beta/devices" -Tenantid $tenantfilter  | Select-Object @{ Name = 'ID'; Expression = { $_.'id' } },
    @{ Name = 'accountEnabled'; Expression = { $_.'accountEnabled' } },
    @{ Name = 'approximateLastSignInDateTime'; Expression = { ($_.'approximateLastSignInDateTime').ToString("yyyy-MM-dd HH:mm") } },
    @{ Name = 'createdDateTime'; Expression = { ($_.'createdDateTime').ToString("yyyy-MM-dd") } },
    @{ Name = 'deviceOwnership'; Expression = { $_.'deviceOwnership' } },
    @{ Name = 'displayName'; Expression = { $_.'displayName' } },
    @{ Name = 'enrollmentType'; Expression = { $_.'enrollmentType' } },
    @{ Name = 'isCompliant'; Expression = { $(if ([string]::IsNullOrEmpty($_.'isCompliant')) { $false }else { $true }) } },
    @{ Name = 'managementType'; Expression = { $_.'managementType' } },
    @{ Name = 'manufacturer'; Expression = { $_.'manufacturer' } },
    @{ Name = 'model'; Expression = { $_.'model' } },
    @{ Name = 'operatingSystem'; Expression = { $_.'operatingSystem' } },
    @{ Name = 'onPremisesSyncEnabled'; Expression = { $(if ([string]::IsNullOrEmpty($_.'onPremisesSyncEnabled')) { $false }else { $true }) } },
    @{ Name = 'operatingSystemVersion'; Expression = { $_.'operatingSystemVersion' } },
    @{ Name = 'trustType'; Expression = { $_.'trustType' } }
    $StatusCode = [HttpStatusCode]::OK
}
catch {
    $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
    $StatusCode = [HttpStatusCode]::Forbidden
    $GraphRequest = $ErrorMessage

}
# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Body       = @($GraphRequest)
    })
