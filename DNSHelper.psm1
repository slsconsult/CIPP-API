function Resolve-DnsHttpsQuery {
    <#
    .SYNOPSIS
    Resolves DNS record using DoH JSON query
    
    .DESCRIPTION
    This function uses Google or Cloudflare DoH REST APIs to resolve DNS records
    
    .PARAMETER Domain
    Domain to query
    
    .PARAMETER RecordType
    Type of record - Examples: A, CNAME, MX, TXT
    
    .PARAMETER FullResultRecord
    Return the entire response instead of just the answer - True, False
    
    .PARAMETER Resolver
    Resolver to query - Options: Google, Cloudflare
    
    .EXAMPLE
    PS> Resolve-DnsHttpsQuery -Domain google.com -RecordType A
    
    name        type TTL data
    ----        ---- --- ----
    google.com.    1  30 142.250.80.110
    
    #>
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Domain,
        
        [Parameter()]
        [string]$RecordType = 'A',

        [Parameter()]
        [switch]$FullResultRecord,

        [Parameter()]
        [ValidateSet('Google', 'Cloudflare')]
        [string]$Resolver = 'Google'
    )

    switch ($Resolver) {
        'Google' {
            $BaseUri = 'https://dns.google/resolve'
            $QueryTemplate = '{0}?name={1}&type={2}'
        }
        'CloudFlare' {
            $BaseUri = 'https://cloudflare-dns.com/dns-query'
            $QueryTemplate = '{0}?name={1}&type={2}'
        }
    }

    $Headers = @{
        'accept' = 'application/dns-json'
    }

    $Uri = $QueryTemplate -f $BaseUri, $Domain, $RecordType

    try {
        $Results = Invoke-RestMethod -Uri $Uri -Headers $Headers
    }
    catch {
        Write-Verbose "$Resolver DoH Query Exception - $($_.Exception.Message)" 
        return $null
    }

    # Domain does not exist
    if ($Results.Status -ne 0) {
        return $Results
    }
    
    if (($Results.Answer | Measure-Object | Select-Object -ExpandProperty Count) -eq 0) {
        return $null
    }
    elseif (!$FullResultRecord) {
        if ($RecordType -eq 'MX') {
            $FinalClean = $Results.Answer | ForEach-Object { $_.Data.Split(' ')[1] }
            return $FinalClean
        }
        else {
            return $Results.Answer
        }
    }
    else {
        return $Results
    }
}

function Test-DNSSEC {
    <#
    .SYNOPSIS
    Test Domain for DNSSEC validation
    
    .DESCRIPTION
    Requests dnskey record from DNS and checks response validation (AD=True)
    
    .PARAMETER Domain
    Domain to check
    
    .EXAMPLE
    PS> Test-DNSSEC -Domain example.com
    
    Domain           : example.com
    ValidationPasses : {PASS: example.com - DNSSEC enabled and validated}
    ValidationFails  : {}
    Keys             : {...}

    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Domain
    )
    $DSResults = [PSCustomObject]@{
        Domain           = $Domain
        ValidationPasses = New-Object System.Collections.ArrayList
        ValidationWarns  = New-Object System.Collections.ArrayList
        ValidationFails  = New-Object System.Collections.ArrayList
        Keys             = New-Object System.Collections.ArrayList
    }
    $ValidationPasses = New-Object System.Collections.ArrayList
    $ValidationFails = New-Object System.Collections.ArrayList

    if (Test-Path -Path 'Config\DnsConfig.json') {
        $Config = Get-Content 'Config\DnsConfig.json' | ConvertFrom-Json 
        $DnsQuery = @{
            RecordType       = 'dnskey'
            Domain           = $Domain
            Resolver         = $Config.Resolver
            FullResultRecord = $true
        }
    }
    else {
        $DnsQuery = @{
            RecordType       = 'dnskey'
            Domain           = $Domain
            FullResultRecord = $true
        }
    }

    $Result = Resolve-DnsHttpsQuery @DnsQuery
    $RecordCount = ($Result.Answer.data | Measure-Object).Count
    if ($null -eq $Result) {
        $ValidationFails.Add('FAIL: DNSSEC validation failed, no dnskey record found') | Out-Null
    }
    else {
        if ($Result.Status -eq 2) {
            if ($Result.AD -eq $false) {
                $ValidationFails.Add("FAIL: $($Result.Comment)") | Out-Null
            }
        }
        elseif ($Result.Status -eq 3) {
            $ValidationFails.Add('FAIL: Record does not exist (NXDOMAIN)') | Out-Null
        }
        elseif ($RecordCount -gt 0) {
            if ($Result.AD -eq $false) {
                $ValidationFails.Add('FAIL: DNSSEC enabled, but response was not validated. Ensure DNSSEC has been enabled at your registrar') | Out-Null
            }
            else {
                $ValidationPasses.Add('PASS: DNSSEC enabled and validated for this domain') | Out-Null
            }
            $DSResults.Keys = $Result.answer.data
        }
    }

    $DSResults.ValidationPasses = $ValidationPasses
    $DSResults.ValidationFails = $ValidationFails
    $DSResults
}

function Read-MXRecord {
    <#
    .SYNOPSIS
    Reads MX records for domain
    
    .DESCRIPTION
    Queries DNS servers to get MX records and returns in PSCustomObject list with Priority and Hostname
    
    .PARAMETER Domain
    Domain to query
    
    .EXAMPLE
    PS> Read-MXRecord -Domain gmail.com
    
    Priority Hostname
    -------- --------
       5 gmail-smtp-in.l.google.com.
      10 alt1.gmail-smtp-in.l.google.com.
      20 alt2.gmail-smtp-in.l.google.com.
      30 alt3.gmail-smtp-in.l.google.com.
      40 alt4.gmail-smtp-in.l.google.com.
    
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Domain
    )
    $MXResults = [PSCustomObject]@{
        Domain           = ''
        Records          = New-Object System.Collections.ArrayList
        ValidationPasses = New-Object System.Collections.ArrayList
        ValidationWarns  = New-Object System.Collections.ArrayList
        ValidationFails  = New-Object System.Collections.ArrayList
        MailProvider     = ''
        ExpectedInclude  = ''
        Selectors        = ''
    }
    $ValidationPasses = New-Object System.Collections.ArrayList
    $ValidationFails = New-Object System.Collections.ArrayList

    if (Test-Path -Path 'Config\DnsConfig.json') {
        $Config = Get-Content 'Config\DnsConfig.json' | ConvertFrom-Json 
        $DnsQuery = @{
            RecordType       = 'mx'
            Domain           = $Domain
            Resolver         = $Config.Resolver
            FullResultRecord = $true
        }
    }
    else {
        $DnsQuery = @{
            RecordType       = 'mx'
            Domain           = $Domain
            FullResultRecord = $true
        }
    }
 
    $MXResults.Domain = $Domain

    try {
        $Result = Resolve-DnsHttpsQuery @DnsQuery
    }
    catch { $Result = $null }
    if ($null -eq $Result -or $Result.Status -ne 0) {
        if ($Result.Status -eq 3) {
            $ValidationFails.Add('FAIL: Record does not exist (NXDOMAIN)') | Out-Null
        }
        else {
            $ValidationFails.Add("FAIL: $Domain - MX record does not exist") | Out-Null
        }
        $MXRecords = $null
    }
    else {
        $MXRecords = $Result.Answer | ForEach-Object { 
            $Priority, $Hostname = $_.Data.Split(' ')
            try {
                [PSCustomObject]@{
                    Priority = [int]$Priority
                    Hostname = $Hostname
                }
            }
            catch {}
        }
        $ValidationPasses.Add("PASS: $Domain - MX record is present") | Out-Null
        $MXRecords = $MXRecords | Sort-Object -Property Priority

        # Attempt to identify mail provider based on MX record
        if (Test-Path 'MailProviders') {
            Get-ChildItem 'MailProviders' -Exclude '_template.json' | ForEach-Object {
                try {
                    $Provider = Get-Content $_ | ConvertFrom-Json -ErrorAction Stop
                    $MXRecords.Hostname | ForEach-Object {
                        if ($_ -match $Provider.MxMatch) {
                            $MXResults.MailProvider = $Provider
                            if (($Provider.SpfReplace | Measure-Object | Select-Object -ExpandProperty Count) -gt 0) {
                                $Replace = foreach ($Var in $Provider.SpfReplace) { $Var }
                                $ExpectedInclude = $Provider.SpfInclude -f $Matches.$Replace
                            }
                            else {
                                $ExpectedInclude = $Provider.SpfInclude
                            }
                            # Set ExpectedInclude and Selector fields based on provider details
                            $MXResults.ExpectedInclude = $ExpectedInclude
                            $MXResults.Selectors = $Provider.Selectors
                        }
                    }
                }
                catch {
                    Write-Host "MailProvider - Error parsing json from $_"
                }
            }
        }
        $MXResults.Records = $MXRecords
    }
    $MXResults.ValidationPasses = $ValidationPasses
    $MXResults.ValidationFails = $ValidationFails
    $MXResults
}

function Read-SpfRecord {
    <#
    .SYNOPSIS
    Reads SPF record for specified domain
    
    .DESCRIPTION
    Uses Get-GoogleDNSQuery to obtain TXT records for domain, searching for v=spf1 at the beginning of the record
    Also parses include records and obtains their SPF as well
    
    .PARAMETER Domain
    Domain to obtain SPF record for
    
    .EXAMPLE
    PS> Read-SpfRecord -Domain gmail.com

    Domain           : gmail.com
    Record           : v=spf1 redirect=_spf.google.com
    RecordCount      : 1
    LookupCount      : 4
    AllMechanism     : ~
    ValidationPasses : {PASS: Expected SPF record was included, PASS: No PermError detected in SPF record}
    ValidationWarns  : {}
    ValidationFails  : {FAIL: SPF record should end in -all to prevent spamming}
    RecordList       : {@{Domain=_spf.google.com; Record=v=spf1 include:_netblocks.google.com include:_netblocks2.google.com include:_netblocks3.google.com ~all;           RecordCount=1; LookupCount=4; AllMechanism=~; ValidationPasses=System.Collections.ArrayList; ValidationWarns=System.Collections.ArrayList; ValidationFails=System.Collections.ArrayList; RecordList=System.Collections.ArrayList; TypeLookups=System.Collections.ArrayList; IPAddresses=System.Collections.ArrayList; PermError=False}}
    TypeLookups      : {}
    IPAddresses      : {}
    PermError        : False

    .NOTES
    Author: John Duprey
    #>
    [CmdletBinding(DefaultParameterSetName = 'Lookup')]
    Param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Lookup')]
        [Parameter(ParameterSetName = 'Manual')]
        [string]$Domain,

        [Parameter(Mandatory = $true, ParameterSetName = 'Manual')]
        [string]$Record,

        [Parameter(ParameterSetName = 'Lookup')]
        [Parameter(ParameterSetName = 'Manual')]
        [string]$Level = 'Parent',

        [Parameter(ParameterSetName = 'Lookup')]
        [Parameter(ParameterSetName = 'Manual')]
        [string]$ExpectedInclude = ''
    )
    $SPFResults = [PSCustomObject]@{
        Domain           = ''
        Record           = ''
        RecordCount      = 0
        LookupCount      = 0
        AllMechanism     = ''
        ValidationPasses = New-Object System.Collections.ArrayList
        ValidationWarns  = New-Object System.Collections.ArrayList
        ValidationFails  = New-Object System.Collections.ArrayList
        RecordList       = New-Object System.Collections.ArrayList   
        TypeLookups      = New-Object System.Collections.ArrayList
        IPAddresses      = New-Object System.Collections.ArrayList
        MailProvider     = ''
        PermError        = $false     
    }

    # Initialize lists to hold all records
    $RecordList = New-Object System.Collections.ArrayList
    $ValidationFails = New-Object System.Collections.ArrayList
    $ValidationPasses = New-Object System.Collections.ArrayList
    $ValidationWarns = New-Object System.Collections.ArrayList
    $LookupCount = 0
    $IsRedirected = $false
    $AllMechanism = ''
    $PermError = $false

    $IncludeList = New-Object System.Collections.ArrayList
    $TypeLookups = New-Object System.Collections.ArrayList
    $IPAddresses = New-Object System.Collections.ArrayList

    if (Test-Path -Path 'Config/DnsConfig.json') {
        $Config = Get-Content 'Config/DnsConfig.json' | ConvertFrom-Json
            
        $DnsQuery = @{
            RecordType       = 'TXT'
            Domain           = $Domain
            Resolver         = $Config.Resolver
            FullResultRecord = $true
        }
    }
    else {
        $DnsQuery = @{
            RecordType       = 'TXT'
            Domain           = $Domain
            FullResultRecord = $true
        }
    }

    # Query DNS for SPF Record
    try {
        switch ($PSCmdlet.ParameterSetName) {
            'Lookup' {
                if ($Domain -eq 'Not Specified') {
                    # don't perform lookup if domain is not specified
                }
                else {
                    $Query = Resolve-DnsHttpsQuery @DnsQuery
                    if ($null -ne $Query -and $Query.Status -ne 0) {
                        if ($Query.Status -eq 3) {
                            $ValidationFails.Add('FAIL: Record does not exist (NXDOMAIN)') | Out-Null
                        }
                        else {
                            $ValidationFails.Add("FAIL: $Domain does not resolve an SPF record.") | Out-Null
                        }
                        $PermError = $true
                    }
                    else {
                        $Record = $Query.answer | Select-Object -ExpandProperty data | Where-Object { $_ -match '^v=spf1' }
                        $RecordCount = ($Record | Measure-Object).Count
                        if ($RecordCount -eq 0) { 
                            $ValidationFails.Add("FAIL: $Domain does not resolve an SPF record.") | Out-Null
                            $PermError = $true 
                        }
                    }
                }
                if ($level -ne 'Parent') {
                    $LookupCount++
                }
            }
            'Manual' {
                if ([string]::IsNullOrEmpty($Domain)) { $Domain = 'Not Specified' }
                $RecordCount = 1
            }
        }
        $SPFResults.Domain = $Domain

        if ($Record -ne '' -and $RecordCount -gt 0) {
            # Split records and parse
            $RecordEntries = $Record -split '\s+'

            $RecordEntries | ForEach-Object {
                if ($_ -match 'v=spf1') {}
            
                # Look for redirect modifier
                elseif ($_ -match 'redirect=(?<Domain>.+)') {
                    if ($Record -match 'all$') {
                        $ValidationFails.Add("FAIL: $Domain - Redirect modifier should not contain all mechanism, SPF record invalid") | Out-Null
                        $PermError = $true
                    }
                    else {
                        $IsRedirected = $true
                        $Domain = $Matches.Domain
                    }
                }
            
                # Don't increment for include, this will be done in a recursive call
                elseif ($_ -match '(?<Qualifier>[+-~?])?include:(?<Value>.+)') {
                    $IncludeList.Add($Matches.Value) | Out-Null
                }

                # Increment lookup count for exists mechanism
                elseif ($_ -match '(?<Qualifier>[+-~?])?exists:(?<Value>.+)') {
                    $LookupCount++
                }

                # Collect explicit IP addresses
                elseif ($_ -match '(?<Qualifier>[+-~?])?ip[4,6]:(?<Value>.+)') {
                    if ($Matches.PSObject.Properties.Name -notcontains 'Qualifier' -or $Matches.Qualifier -eq '+') {
                        $IPAddresses.Add($Matches.Value) | Out-Null
                    }
                }

                # Get all mechanism
                elseif ($_ -match 'all') {
                    if ($Record -match '(?<Mechanism>[+-~?])all$') {
                        $AllMechanism = $Matches.Mechanism
                    }
                    else {
                        $AllMechanism = ''
                    }
                }
                # Get any type specific mechanism
                elseif ($_ -match '^(?<Qualifier>[+-~?])?(?<RecordType>(?:a|mx|ptr))(?:[:](?<TypeDomain>.+))?') {
                    $LookupCount++
                    
                    if ($Matches.TypeDomain) {
                        $TypeDomain = $Matches.TypeDomain
                    }
                    else {
                        $TypeDomain = $Domain
                    }
                    $TypeQuery = @{Domain = $TypeDomain; RecordType = $Matches.RecordType; FullResultRecord = $true }      
                    
                    if ($TypeQuery.Domain -ne 'Not Specified') {
                        try {
                            Write-Verbose "Looking up $($TypeQuery.Domain)"
                            $TypeResult = Resolve-DnsHttpsQuery @TypeQuery
                            Write-Verbose ($TypeResult | Format-Table | Out-String)
                        }
                        catch { $TypeResult = $null }
                        if ($null -eq $TypeResult -or $TypeResult.Status -ne 0) {
                            $ValidationFails.Add("FAIL: $Domain - Type lookup for mechanism '$($TypeQuery.RecordType)' did not return any results, PermError") | Out-Null
                            $PermError = $true
                            $Result = $false
                        }
                        else {
                            if ($TypeQuery.RecordType -eq 'mx') {
                                $Result = $TypeResult.Answer | ForEach-Object { $_.Data.Split(' ')[1] }
                            }
                            else {
                                $Result = $TypeResult.answer.data
                            }
                        }
                        $TypeLookups.Add(
                            [PSCustomObject]@{
                                Domain     = $TypeQuery.Domain 
                                RecordType = $TypeQuery.RecordType
                                Result     = $Result
                            }
                        ) | Out-Null

                    }
                    else {
                        $ValidationWarns.Add("WARN: No domain specified and mechanism '$_' does not have one defined. Specify a domain to perform a lookup on this record.") | Out-Null
                    }
                    
                }
                else {
                    $ValidationFails.Add("FAIL: $Domain - Unknown mechanism or modifier specified '$_'") | Out-Null
                    $PermError = $true
                }
            }
        }
    }
    catch {
        # DNS Resolver exception
    }

    # Follow redirect modifier
    if ($IsRedirected) {
        $RedirectedLookup = Read-SpfRecord -Domain $Domain -Level 'Redirect'
        if (($RedirectedLookup | Measure-Object).Count -eq 0) {
            $ValidationFails.Add("FAIL: $Domain Redirected lookup does not contain a SPF record, permerror") | Out-Null
            $PermError = $true
        }
        $RecordList.Add($RedirectedLookup) | Out-Null
        $AllMechanism = $RedirectedLookup.AllMechanism
        $ValidationFails.AddRange($RedirectedLookup.ValidationFails) | Out-Null
        $ValidationWarns.AddRange($RedirectedLookup.ValidationWarns) | Out-Null
        $ValidationPasses.AddRange($RedirectedLookup.ValidationPasses) | Out-Null
    }

    # Loop through includes and perform recursive lookup
    $IncludeHosts = $IncludeList | Sort-Object -Unique
    if (($IncludeHosts | Measure-Object).Count -gt 0) {
        foreach ($Include in $IncludeHosts) {
            # Verify we have not performed a lookup for this nested SPF record
            if ($RecordList.Domain -notcontains $Include) {
                $IncludeRecord = Read-SpfRecord -Domain $Include -Level 'Include'
                $RecordList.Add($IncludeRecord) | Out-Null
                $ValidationFails.AddRange($IncludeRecord.ValidationFails) | Out-Null
                $ValidationWarns.AddRange($IncludeRecord.ValidationWarns) | Out-Null
                $ValidationPasses.AddRange($IncludeRecord.ValidationPasses) | Out-Null
                $IPAddresses.AddRange($IncludeRecord.IPAddresses) | Out-Null
                if ($IncludeRecord.PermError -eq $true) {
                    $PermError = $true
                }
            }
        }
    }

    # Lookup MX record for expected include information if not supplied
    if ($Level -eq 'Parent' -and $ExpectedInclude -eq '') {
        $MXRecord = Read-MXRecord -Domain $Domain
        $SPFResults.MailProvider = $MXRecord.MailProvider
        if ($MXRecord.ExpectedInclude -ne '') {
            $ExpectedInclude = $MXRecord.ExpectedInclude
        }
    }
        
    # Look for expected include record and report pass or fail
    if ($ExpectedInclude -ne '') {
        if ($RecordList.Domain -notcontains $ExpectedInclude) {
            $ExpectedIncludeSpf = Read-SpfRecord -Domain $ExpectedInclude
            $ExpectedIPCount = $ExpectedIncludeSpf.IPAddresses | Measure-Object | Select-Object -ExpandProperty Count
            $FoundIPCount = Compare-Object $IPAddresses $ExpectedIncludeSpf.IPAddresses -IncludeEqual | Where-Object -Property SideIndicator -EQ '==' | Measure-Object | Select-Object -ExpandProperty Count
            if ($ExpectedIPCount -eq $FoundIPCount) {
                $ValidationPasses.Add("PASS: Expected SPF ($ExpectedInclude) IP addresses were found") | Out-Null
            }
            else {
                $ValidationFails.Add("FAIL: Expected SPF include of '$ExpectedInclude' was not found in the SPF record") | Out-Null
            }
        }
        else {
            $ValidationPasses.Add("PASS: Expected SPF record ($ExpectedInclude) was included") | Out-Null
        }
    }

    # Count total lookups
    $LookupCount = $LookupCount + ($RecordList | Measure-Object -Property LookupCount -Sum).Sum
        
    if ($Domain -ne 'Not Specified') {
        # Check legacy SPF type
        $LegacySpfType = Resolve-DnsHttpsQuery -Domain $Domain -RecordType 'SPF' -FullResultRecord
        if ($null -ne $LegacySpfType -and $LegacySpfType -eq 0) {
            $ValidationWarns.Add("WARN: Domain: $Domain Record Type SPF detected, this is legacy and should not be used. It is recommeded to delete this record.") | Out-Null
        }
    }
    if ($Level -eq 'Parent' -and $RecordCount -gt 0) {
        # Check for the correct number of records
        if ($RecordCount -gt 1) {
            $ValidationFails.Add("FAIL: There should only be one SPF record, $RecordCount detected") | Out-Null 
            $PermError = $true
        }

        # Report pass if no PermErrors are found
        if ($PermError -eq $false) {
            $ValidationPasses.Add('PASS: No PermError detected in SPF record') | Out-Null
        }

        # Check for the correct all mechanism
        if ($AllMechanism -eq '' -and $Record -ne '') { 
            $ValidationFails.Add('FAIL: All mechanism is missing from SPF record, defaulting to +all') | Out-Null
            $AllMechanism = '+' 
        }
        if ($AllMechanism -eq '-') {
            $ValidationPasses.Add('PASS: SPF record ends in -all') | Out-Null
        }
        elseif ($Record -ne '') {
            $ValidationFails.Add('FAIL: SPF record should end in -all to prevent spamming') | Out-Null 
        }

        # SPF lookup count
        if ($LookupCount -gt 10) { 
            $ValidationFails.Add("FAIL: SPF record exceeded 10 lookups, found $LookupCount") | Out-Null 
            $PermError = $true
        }
        elseif ($LookupCount -ge 9 -and $LookupCount -lt 10) {
            $ValidationWarns.Add("WARN: SPF lookup count is close to the limit of 10, found $LookupCount") | Out-Null
        }

        # Report pass if no errors are found
        if (($ValidationFails | Measure-Object | Select-Object -ExpandProperty Count) -eq 0) {
            $ValidationPasses.Add('PASS: All validation succeeded. No errors detected with SPF record') | Out-Null
        }
    }

    $SpfResults.Record = $Record
    $SpfResults.RecordCount = $RecordCount
    $SpfResults.LookupCount = $LookupCount
    $SpfResults.AllMechanism = $AllMechanism
    $SpfResults.ValidationPasses = $ValidationPasses
    $SpfResults.ValidationWarns = $ValidationWarns
    $SpfResults.ValidationFails = $ValidationFails
    $SpfResults.RecordList = $RecordList
    $SPFResults.TypeLookups = $TypeLookups
    $SPFResults.IPAddresses = $IPAddresses
    $SPFResults.PermError = $PermError
            
    # Output SpfResults object
    $SpfResults
    
}

function Read-DmarcPolicy {
    <#
    .SYNOPSIS
    Resolve and validate DMARC policy
    
    .DESCRIPTION
    Query domain for DMARC policy (_dmarc.domain.com) and parse results. Record is checked for issues.
    
    .PARAMETER Domain
    Domain to process DMARC policy
    
    .EXAMPLE
    PS> Read-DmarcPolicy -Domain gmail.com

    Domain           : gmail.com
    Record           : v=DMARC1; p=none; sp=quarantine; rua=mailto:mailauth-reports@google.com
    Version          : DMARC1
    Policy           : none
    SubdomainPolicy  : quarantine
    Percent          : 100
    DkimAlignment    : r
    SpfAlignment     : r
    ReportFormat     : afrf
    ReportInterval   : 86400
    ReportingEmails  : {mailauth-reports@google.com}
    ForensicEmails   : {}
    FailureReport    : 0
    ValidationPasses : {PASS: Aggregate reports are being sent}
    ValidationWarns  : {FAIL: Policy is not being enforced, WARN: Subdomain policy is only partially enforced with quarantine, WARN: Failure report option 0 will only generate a report on both SPF and DKIM misalignment. It is recommended to set this value to 1}
    ValidationFails  : {}
    
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Domain
    )

    # Initialize object
    $DmarcAnalysis = [PSCustomObject]@{
        Domain           = $Domain
        Record           = ''
        Version          = ''
        Policy           = ''
        SubdomainPolicy  = ''
        Percent          = 100
        DkimAlignment    = 'r'
        SpfAlignment     = 'r'
        ReportFormat     = 'afrf'
        ReportInterval   = 86400
        ReportingEmails  = New-Object System.Collections.ArrayList
        ForensicEmails   = New-Object System.Collections.ArrayList
        FailureReport    = ''
        ValidationPasses = New-Object System.Collections.ArrayList
        ValidationWarns  = New-Object System.Collections.ArrayList
        ValidationFails  = New-Object System.Collections.ArrayList
    }

    # Validation lists
    $ValidationPasses = New-Object System.Collections.ArrayList
    $ValidationWarns = New-Object System.Collections.ArrayList
    $ValidationFails = New-Object System.Collections.ArrayList

    # Email report domains
    $ReportDomains = New-Object System.Collections.ArrayList

    # Validation ranges
    $PolicyValues = @('none', 'quarantine', 'reject')
    $FailureReportValues = @('0', '1', 'd', 's')
    $ReportFormatValues = @('afrf')

    $RecordCount = 0

    # Check for DnsConfig file and set DNS resolver
    if (Test-Path -Path 'Config/DnsConfig.json') {
        $Config = Get-Content 'Config/DnsConfig.json' | ConvertFrom-Json
        $DnsQuery = @{
            RecordType       = 'TXT'
            Domain           = "_dmarc.$Domain"
            Resolver         = $Config.Resolver
            FullResultRecord = $true
        }
    }
    else {
        $DnsQuery = @{
            RecordType       = 'TXT'
            Domain           = "_dmarc.$Domain"
            FullResultRecord = $true
        }
    }
    
    # Resolve DMARC record
    $Query = Resolve-DnsHttpsQuery @DnsQuery
    if (($null -ne $Query -and $Query.Status -ne 0) -or $null -eq $Query.Answer.data) {
        if ($Query.Status -eq 3) {
            $ValidationFails.Add('FAIL: Record does not exist (NXDOMAIN)') | Out-Null
        }
        else {
            $ValidationFails.Add("FAIL: $Domain does not have a DMARC record") | Out-Null
        }
    }
    else {
        $DmarcRecord = ($Query.Answer | Where-Object -Property type -EQ 16).data
        $DmarcAnalysis.Record = $DmarcRecord
        $RecordCount = ($DmarcRecord | Measure-Object).Count   
    }

    # Split DMARC record into name/value pairs
    $TagList = New-Object System.Collections.ArrayList
    Foreach ($Element in ($DmarcRecord -split ';').trim()) {
        $Name, $Value = $Element -split '='
        $TagList.Add(
            [PSCustomObject]@{
                Name  = $Name
                Value = $Value
            }
        ) | Out-Null
    }

    # Loop through name/value pairs and set object properties
    $x = 0
    foreach ($Tag in $TagList) {
        switch ($Tag.Name) {
            'v' {
                # REQUIRED: Version
                if ($x -ne 0) { $ValidationFails.Add('FAIL: v=DMARC1 must be at the beginning of the record') | Out-Null }
                if ($Tag.Value -ne 'DMARC1') { $ValidationFails.Add("FAIL: Version must be DMARC1 - found $($Tag.Value)") | Out-Null }
                $DmarcAnalysis.Version = $Tag.Value
            }
            'p' {
                # REQUIRED: Policy
                $DmarcAnalysis.Policy = $Tag.Value
            }
            'sp' {
                # Subdomain policy, defaults to policy record 
                $DmarcAnalysis.SubdomainPolicy = $Tag.Value
            }
            'rua' {
                # Aggregate report emails
                $ReportingEmails = $Tag.Value -split ', '
                $ReportEmailsSet = $false
                foreach ($MailTo in $ReportingEmails) {
                    if ($MailTo -notmatch '^mailto:') { $ValidationFails.Add("FAIL: Aggregate report email must begin with 'mailto:', multiple addresses must be separated by commas - found $($Tag.Value)") | Out-Null }
                    else {
                        $ReportEmailsSet = $true
                        if ($MailTo -match '^mailto:(?<Email>.+@(?<Domain>.+))$') {
                            if ($ReportDomains -notcontains $Matches.Domain -and $Matches.Domain -ne $Domain) {
                                $ReportDomains.Add($Matches.Domain) | Out-Null
                            }
                            $DmarcAnalysis.ReportingEmails.Add($Matches.Email) | Out-Null
                        }
                    }
                }
                if ($ReportEmailsSet) {
                    $ValidationPasses.Add('PASS: Aggregate reports are being sent') | Out-Null
                }
                else {
                    $ValidationWarns.Add('WARN: Aggregate reports are not being sent') | Out-Null
                }
            }
            'ruf' {
                # Forensic reporting emails
                foreach ($MailTo in ($Tag.Value -split ', ')) {
                    if ($MailTo -notmatch '^mailto:') { $ValidationFails.Add("FAIL: Forensic report email must begin with 'mailto:', multiple addresses must be separated by commas - found $($Tag.Value)") | Out-Null }
                    else {
                        if ($MailTo -match '^mailto:(?<Email>.+@(?<Domain>.+))$') {
                            if ($ReportDomains -notcontains $Matches.Domain -and $Matches.Domain -ne $Domain) {
                                $ReportDomains.Add($Matches.Domain) | Out-Null
                            }
                            $DmarcAnalysis.ForensicEmails.Add($Matches.Email) | Out-Null
                        }
                    }
                }
            }
            'fo' {
                # Failure reporting options
                $DmarcAnalysis.FailureReport = $Tag.Value
            } 
            'pct' {
                # Percentage of email to check
                $DmarcAnalysis.Percent = $Tag.Value
            }
            'adkim' {
                # DKIM Alignmenet
                $DmarcAnalysis.DkimAlignment = $Tag.Value
            }
            'aspf' {
                # SPF Alignment
                $DmarcAnalysis.SpfAlignment = $Tag.Value
            }
            'rf' {
                # Report Format
                $DmarcAnalysis.ReportFormat = $Tag.Value
            }
            'ri' {
                # Report Interval
                $DmarcAnalysis.ReportInterval = $Tag.Value
            }
        }
        $x++
    }

    if ($RecordCount -gt 0) {
        # Check report domains for DMARC reporting record
        $ReportDomainCount = $ReportDomains | Measure-Object | Select-Object -ExpandProperty Count
        if ($ReportDomainCount -gt 0) {
            $ReportDomainsPass = $true
            foreach ($ReportDomain in $ReportDomains) {
                $ReportDomainQuery = "$Domain._report._dmarc.$ReportDomain"
                $DnsQuery['Domain'] = $ReportDomainQuery
                $ReportDmarcQuery = Resolve-DnsHttpsQuery @DnsQuery
                $ReportDmarcRecord = $ReportDmarcQuery.Answer.data
                if ($null -eq $ReportDmarcQuery -or $ReportDmarcQuery.Status -ne 0) {
                    $ValidationWarns.Add("WARN: Report DMARC policy for $Domain is missing from $ReportDomain, reports will not be delivered. Expected record: $Domain._report._dmarc.$ReportDomain - Expected value: v=DMARC1; ") | Out-Null
                    $ReportDomainsPass = $false
                }
                elseif ($ReportDmarcRecord -notmatch '^v=DMARC1') {
                    $ValidationWarns.Add("WARN: Report DMARC policy for $Domain is missing from $ReportDomain, reports will not be delivered. Expected record: $Domain._report._dmarc.$ReportDomain - Expected value: v=DMARC1; ") | Out-Null
                    $ReportDomainsPass = $false
                }
            }

            if ($ReportDomainsPass) {
                $ValidationPasses.Add("PASS: All external reporting domains ($($ReportDomains -join ', ')) allow $Domain to send DMARC reports") | Out-Null
            }

        }
        # Check for missing record tags and set defaults
        if ($DmarcAnalysis.Policy -eq '') { $ValidationFails.Add('FAIL: Policy record is missing') | Out-Null }
        if ($DmarcAnalysis.SubdomainPolicy -eq '') { $DmarcAnalysis.SubdomainPolicy = $DmarcAnalysis.Policy }

        # Check policy for errors and best practice
        if ($PolicyValues -notcontains $DmarcAnalysis.Policy) { $ValidationFails.Add("FAIL: Policy must be one of the following - none, quarantine, reject. Found $($Tag.Value)") | Out-Null }
        if ($DmarcAnalysis.Policy -eq 'reject') { $ValidationPasses.Add('PASS: Policy is sufficiently strict') | Out-Null }
        if ($DmarcAnalysis.Policy -eq 'quarantine') { $ValidationWarns.Add('WARN: Policy is only partially enforced with quarantine') | Out-Null }
        if ($DmarcAnalysis.Policy -eq 'none') { $ValidationWarns.Add('FAIL: Policy is not being enforced') | Out-Null }

        # Check subdomain policy
        if ($PolicyValues -notcontains $DmarcAnalysis.SubdomainPolicy) { $ValidationFails.Add("FAIL: Subdomain policy must be one of the following - none, quarantine, reject. Found $($DmarcAnalysis.SubdomainPolicy)") | Out-Null }
        if ($DmarcAnalysis.SubdomainPolicy -eq 'reject') { $ValidationPasses.Add('PASS: Subdomain policy is sufficiently strict') | Out-Null }
        if ($DmarcAnalysis.SubdomainPolicy -eq 'quarantine') { $ValidationWarns.Add('WARN: Subdomain policy is only partially enforced with quarantine') | Out-Null }
        if ($DmarcAnalysis.SubdomainPolicy -eq 'none') { $ValidationWarns.Add('FAIL: Subdomain policy is not being enforced') | Out-Null }

        # Check percentage - validate range and ensure 100%
        if ($DmarcAnalysis.Percent -lt 100 -and $DmarcAnalysis.Percent -gt 0) { $ValidationWarns.Add('WARN: Not all emails will be processed by the DMARC policy') | Out-Null }
        if ($DmarcAnalysis.Percent -gt 100 -or $DmarcAnalysis.Percent -le 0) { $ValidationFails.Add('FAIL: Percentage must be between 1 and 100') | Out-Null }

        # Check report format
        if ($ReportFormatValues -notcontains $DmarcAnalysis.ReportFormat) { $ValidationFails.Add("FAIL: The report format '$($DmarcAnalysis.ReportFormat)' is not supported") | Out-Null }
 
        # Check forensic reports and failure options
        $ForensicCount = ($DmarcAnalysis.ForensicEmails | Measure-Object | Select-Object -ExpandProperty Count)
        if ($ForensicCount -eq 0 -and $DmarcAnalysis.FailureReport -ne '') { $ValidationWarns.Add('WARN: Forensic email reports recipients are not defined and failure report options are set. No reports will be sent.') | Out-Null }
        if ($DmarcAnalysis.FailureReport -eq '' -and $null -ne $DmarcRecord) { $DmarcAnalysis.FailureReport = '0' }
        if ($ForensicCount -gt 0) {
            if ($FailureReportValues -notcontains $DmarcAnalysis.FailureReport) { $ValidationFails.Add('FAIL: Failure reporting options must be 0, 1, d or s') | Out-Null }
            if ($DmarcAnalysis.FailureReport -eq '1') { $ValidationPasses.Add('PASS: Failure report option 1 generates forensic reports on SPF or DKIM misalignment') | Out-Null }
            if ($DmarcAnalysis.FailureReport -eq '0') { $ValidationWarns.Add('WARN: Failure report option 0 will only generate a forensic report on both SPF and DKIM misalignment. It is recommended to set this value to 1') | Out-Null }
            if ($DmarcAnalysis.FailureReport -eq 'd') { $ValidationWarns.Add('WARN: Failure report option d will only generate a forensic report on failed DKIM evaluation. It is recommended to set this value to 1') | Out-Null }
            if ($DmarcAnalysis.FailureReport -eq 's') { $ValidationWarns.Add('WARN: Failure report option s will only generate a forensic report on failed SPF evaluation. It is recommended to set this value to 1') | Out-Null }
        }
    }
    
    if ($RecordCount -gt 1) {
        $ValidationWarns.Add('WARN: Multiple DMARC records detected, this may cause unexpected behavior.') | Out-Null
    }

    # Add the validation lists
    $DmarcAnalysis.ValidationPasses = $ValidationPasses
    $DmarcAnalysis.ValidationWarns = $ValidationWarns
    $DmarcAnalysis.ValidationFails = $ValidationFails

    # Return DMARC analysis
    $DmarcAnalysis
}

function Read-DkimRecord {
    <#
    .SYNOPSIS
    Read DKIM record from DNS
    
    .DESCRIPTION
    Validates DKIM records on a domain a selector
    
    .PARAMETER Domain
    Domain to check
    
    .PARAMETER Selectors
    Selector records to check
    
    .PARAMETER MxLookup
    Lookup record based on MX
    
    .EXAMPLE
    PS> Read-DkimRecord -Domain example.com -Selector test

    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Domain,

        [Parameter()]
        [string[]]$Selectors = @()
    )

    $MXRecord = $null

    $DkimAnalysis = [PSCustomObject]@{
        Domain           = $Domain
        MailProvider     = ''
        Records          = New-Object System.Collections.ArrayList
        ValidationPasses = New-Object System.Collections.ArrayList
        ValidationWarns  = New-Object System.Collections.ArrayList
        ValidationFails  = New-Object System.Collections.ArrayList
    }

    $ValidationPasses = New-Object System.Collections.ArrayList
    $ValidationWarns = New-Object System.Collections.ArrayList
    $ValidationFails = New-Object System.Collections.ArrayList

    if (($Selectors | Measure-Object | Select-Object -ExpandProperty Count) -eq 0) {
        $MXRecord = Read-MXRecord -Domain $Domain 
        $Selectors = $MXRecord.Selectors
        $DkimAnalysis.MailProvider = $MXRecord.MailProvider
        if (($Selectors | Measure-Object | Select-Object -ExpandProperty Count) -eq 0) {
            $ValidationFails.Add("FAIL: $Domain - No selectors found from MX record") | Out-Null
        }
    }
    
    if (($Selectors | Measure-Object | Select-Object -ExpandProperty Count) -gt 0 -and $Selectors -notcontains '') {
        foreach ($Selector in $Selectors) {
            # Initialize object
            $DkimRecord = [PSCustomObject]@{
                Record           = ''
                Version          = ''
                PublicKey        = ''
                PublicKeyInfo    = ''
                KeyType          = ''
                Flags            = ''
                Notes            = ''
                HashAlgorithms   = ''
                ServiceType      = ''
                Granularity      = ''
                UnrecognizedTags = New-Object System.Collections.ArrayList
            }

            # Check for DnsConfig file and set DNS resolver
            if (Test-Path -Path 'Config/DnsConfig.json') {
                $Config = Get-Content 'Config/DnsConfig.json' | ConvertFrom-Json
                $DnsQuery = @{
                    RecordType       = 'TXT'
                    Domain           = "$Selector._domainkey.$Domain"
                    Resolver         = $Config.Resolver
                    FullResultRecord = $true
                }
            }
            else {
                $DnsQuery = @{
                    RecordType       = 'TXT'
                    Domain           = "$Selector._domainkey.$Domain"
                    FullResultRecord = $true
                }
            }
            $QueryResults = Resolve-DnsHttpsQuery @DnsQuery

            if ($QueryResults -eq '' -or $QueryResults.Status -ne 0) {
                if ($QueryResults.Status -eq 3) {
                    $ValidationFails.Add("FAIL: $Selector - Selector record does not exist (NXDOMAIN)") | Out-Null
                }
                else {
                    $ValidationFails.Add("FAIL: $Selector - DKIM record is missing, check the selector and try again") | Out-Null
                }
                $Record = ''
            }
            else {
                $QueryData = ($QueryResults.Answer).data
                if (( $QueryData | Measure-Object).Count -gt 1) {
                    $Record = $QueryData[-1]
                }
                else {
                    $Record = $QueryData
                }
            }
            $DkimRecord.Record = $Record

            # Split DKIM record into name/value pairs
            $TagList = New-Object System.Collections.ArrayList
            Foreach ($Element in ($Record -split ';').trim()) {
                $Name, $Value = $Element -split '='
                $TagList.Add(
                    [PSCustomObject]@{
                        Name  = $Name
                        Value = $Value
                    }
                ) | Out-Null
            }
            

            # Loop through name/value pairs and set object properties
            $x = 0
            foreach ($Tag in $TagList) {
                switch ($Tag.Name) {
                    'v' {
                        # REQUIRED: Version
                        if ($x -ne 0) { $ValidationFails.Add("FAIL: $Selector - v=DKIM1 must be at the beginning of the record") | Out-Null }
                        if ($Tag.Value -ne 'DKIM1') { $ValidationFails.Add("FAIL: $Selector - Version must be DKIM1 - found $($Tag.Value)") | Out-Null }
                        $DkimRecord.Version = $Tag.Value
                    }
                    'p' {
                        # REQUIRED: Public Key
                        if ($Tag.Value -ne '') {
                            $DkimRecord.PublicKey = "-----BEGIN PUBLIC KEY-----`n {0}`n-----END PUBLIC KEY-----" -f $Tag.Value
                            $DkimRecord.PublicKeyInfo = Get-RsaPublicKeyInfo -EncodedString $Tag.Value
                        }
                        else {
                            $ValidationFails.Add("FAIL: $Selector - No public key specified for DKIM record") | Out-Null 
                        }
                    }
                    'k' {
                        $DkimRecord.KeyType = $Tag.Value
                    }
                    't' {
                        $DkimRecord.Flags = $Tag.Value
                    }
                    'n' {
                        $DkimRecord.Notes = $Tag.Value
                    }
                    'h' {
                        $DkimRecord.HashAlgorithms = $Tag.Value
                    }
                    's' {
                        $DkimRecord.ServiceType = $Tag.Value
                    }
                    'g' {
                        $DkimRecord.Granularity = $Tag.Value
                    }
                    default {
                        $DkimRecord.UnrecognizedTags.Add($Tag) | Out-Null
                    }
                }
                $x++
            }

            if ($Record -ne '') {
                if ($DkimRecord.KeyType -eq '') { $DkimRecord.KeyType = 'rsa' }

                if ($DkimRecord.HashAlgorithms -eq '') { $DkimRecord.HashAlgorithms = 'all' }

                $UnrecognizedTagCount = $UnrecognizedTags | Measure-Object | Select-Object -ExpandProperty Count
                if ($UnrecognizedTagCount -gt 0) {
                    $TagString = ($UnrecognizedTags | ForEach-Object { '{0}={1}' -f $_.Tag, $_.Value }) -join ', '
                    $ValidationWarns.Add("WARN: $Selector - $UnrecognizedTagCount tag(s) detected in DKIM record. This can cause issues with some mailbox providers. Tags: $TagString")
                }
                if ($DkimRecord.Flags -eq 'y') {
                    $ValidationWarns.Add("WARN: $Selector - This flag 't=y' indicates that this domain is testing mode currently. If DKIM is fully deployed, this flag should be changed to t=s unless subdomaining is required.") | Out-Null
                }

                if ($DkimRecord.PublicKeyInfo.SignatureAlgorithm -ne $DkimRecord.KeyType) {
                    $ValidationWarns.Add("WARN: $Selector - Key signature algorithm $($DkimRecord.PublicKeyInfo.SignatureAlgorithm) does not match $($DkimRecord.KeyType)") | Out-Null
                }

                if ($DkimRecord.PublicKeyInfo.KeySize -lt 1024) {
                    $ValidationFails.Add("FAIL: $Selector - Key size is less than 1024 bit, found $($DkimRecord.PublicKeyInfo.KeySize)") | Out-Null
                }
                else {
                    $ValidationPasses.Add("PASS: $Selector - DKIM key validation succeeded") | Out-Null
                }
                ($DkimAnalysis.Records).Add($DkimRecord) | Out-Null
            }

            if (($ValidationFails | Measure-Object | Select-Object -ExpandProperty Count) -eq 0) {
                $ValidationPasses.Add("PASS: $Selector - No errors detected with DKIM record") | Out-Null
            }
        }
    }
    else {
        $ValidationFails.Add('FAIL: No DKIM selectors provided') | Out-Null
    }

    # Collect validation results
    $DkimAnalysis.ValidationPasses = $ValidationPasses
    $DkimAnalysis.ValidationWarns = $ValidationWarns
    $DkimAnalysis.ValidationFails = $ValidationFails

    # Return analysis
    $DkimAnalysis
}

function Get-RsaPublicKeyInfo {
    <#
    .SYNOPSIS
    Gets RSA public key info from Base64 string
    
    .DESCRIPTION
    Decodes RSA public key information for validation. Uses a c# library to decode base64 data.
    
    .PARAMETER EncodedString
    Base64 encoded public key string
    
    .EXAMPLE
    PS> Get-RsaPublicKeyInfo -EncodedString <base64 string>
    
    LegalKeySizes                           KeyExchangeAlgorithm SignatureAlgorithm KeySize
    -------------                           -------------------- ------------------ -------
    {System.Security.Cryptography.KeySizes} RSA                  RSA                   2048
    
    .NOTES
    Obtained C# code from https://github.com/sevenTiny/Bamboo/blob/b5503b5597383ca6085ceb4aa5fa054918a4bd73/10-Code/SevenTiny.Bantina/Security/RSACommon.cs
    #>
    Param(
        [Parameter(Mandatory = $true)]
        $EncodedString
    )
    $source = @'
/*********************************************************
 * CopyRight: 7TINY CODE BUILDER. 
 * Version: 5.0.0
 * Author: 7tiny
 * Address: Earth
 * Create: 2018-04-08 21:54:19
 * Modify: 2018-04-08 21:54:19
 * E-mail: dong@7tiny.com | sevenTiny@foxmail.com 
 * GitHub: https://github.com/sevenTiny 
 * Personal web site: http://www.7tiny.com 
 * Technical WebSit: http://www.cnblogs.com/7tiny/ 
 * Description: 
 * Thx , Best Regards ~
 *********************************************************/
using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace SevenTiny.Bantina.Security {
    public static class RSACommon {
        public static RSA CreateRsaProviderFromPublicKey(string publicKeyString)
        {
            // encoded OID sequence for  PKCS #1 rsaEncryption szOID_RSA_RSA = "1.2.840.113549.1.1.1"
            byte[] seqOid = { 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00 };
            byte[] seq = new byte[15];

            var x509Key = Convert.FromBase64String(publicKeyString);

            // ---------  Set up stream to read the asn.1 encoded SubjectPublicKeyInfo blob  ------
            using (MemoryStream mem = new MemoryStream(x509Key))
            {
                using (BinaryReader binr = new BinaryReader(mem))  //wrap Memory Stream with BinaryReader for easy reading
                {
                    byte bt = 0;
                    ushort twobytes = 0;

                    twobytes = binr.ReadUInt16();
                    if (twobytes == 0x8130) //data read as little endian order (actual data order for Sequence is 30 81)
                        binr.ReadByte();    //advance 1 byte
                    else if (twobytes == 0x8230)
                        binr.ReadInt16();   //advance 2 bytes
                    else
                        return null;

                    seq = binr.ReadBytes(15);       //read the Sequence OID
                    if (!CompareBytearrays(seq, seqOid))    //make sure Sequence for OID is correct
                        return null;

                    twobytes = binr.ReadUInt16();
                    if (twobytes == 0x8103) //data read as little endian order (actual data order for Bit String is 03 81)
                        binr.ReadByte();    //advance 1 byte
                    else if (twobytes == 0x8203)
                        binr.ReadInt16();   //advance 2 bytes
                    else
                        return null;

                    bt = binr.ReadByte();
                    if (bt != 0x00)     //expect null byte next
                        return null;

                    twobytes = binr.ReadUInt16();
                    if (twobytes == 0x8130) //data read as little endian order (actual data order for Sequence is 30 81)
                        binr.ReadByte();    //advance 1 byte
                    else if (twobytes == 0x8230)
                        binr.ReadInt16();   //advance 2 bytes
                    else
                        return null;

                    twobytes = binr.ReadUInt16();
                    byte lowbyte = 0x00;
                    byte highbyte = 0x00;

                    if (twobytes == 0x8102) //data read as little endian order (actual data order for Integer is 02 81)
                        lowbyte = binr.ReadByte();  // read next bytes which is bytes in modulus
                    else if (twobytes == 0x8202)
                    {
                        highbyte = binr.ReadByte(); //advance 2 bytes
                        lowbyte = binr.ReadByte();
                    }
                    else
                        return null;
                    byte[] modint = { lowbyte, highbyte, 0x00, 0x00 };   //reverse byte order since asn.1 key uses big endian order
                    int modsize = BitConverter.ToInt32(modint, 0);

                    int firstbyte = binr.PeekChar();
                    if (firstbyte == 0x00)
                    {   //if first byte (highest order) of modulus is zero, don't include it
                        binr.ReadByte();    //skip this null byte
                        modsize -= 1;   //reduce modulus buffer size by 1
                    }

                    byte[] modulus = binr.ReadBytes(modsize);   //read the modulus bytes

                    if (binr.ReadByte() != 0x02)            //expect an Integer for the exponent data
                        return null;
                    int expbytes = (int)binr.ReadByte();        // should only need one byte for actual exponent data (for all useful values)
                    byte[] exponent = binr.ReadBytes(expbytes);

                    // ------- create RSACryptoServiceProvider instance and initialize with public key -----
                    var rsa = System.Security.Cryptography.RSA.Create();
                    RSAParameters rsaKeyInfo = new RSAParameters
                    {
                        Modulus = modulus,
                        Exponent = exponent
                    };
                    rsa.ImportParameters(rsaKeyInfo);

                    return rsa;
                }
            }
        }
        private static bool CompareBytearrays(byte[] a, byte[] b)
        {
            if (a.Length != b.Length)
                return false;
            int i = 0;
            foreach (byte c in a)
            {
                if (c != b[i])
                    return false;
                i++;
            }
            return true;
        }
    }
}
'@
    if (!('SevenTiny.Bantina.Security.RSACommon' -as [type])) {
        Add-Type -TypeDefinition $source -Language CSharp
    }

    # Return RSA Public Key information
    [SevenTiny.Bantina.Security.RSACommon]::CreateRsaProviderFromPublicKey($EncodedString)
}
