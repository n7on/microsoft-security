function Get-MsecDefenderAlert {
    <#
    .SYNOPSIS
        One row per Defender XDR alert across every workload - endpoint, Office 365,
        identity, cloud apps and DLP - with the incident it belongs to.

    .DESCRIPTION
        Alerts are the detections; incidents are the groupings Defender builds from them.
        Get-MsecDefenderIncident answers "what is being investigated"; this answers "what
        actually fired", which is the level at which a noisy detector or an unworked queue
        becomes visible.

        SERVICESOURCE IS OFTEN 'unknownFutureValue', AND THAT IS THE API, NOT THE DATA. Graph
        returns that placeholder for a source the API version does not have a name for yet.
        Measured on a live tenant, 231 of 569 alerts in ninety days - 40% - came back that
        way. It is reported verbatim rather than guessed at or folded into 'other', because
        the alternative is inventing a source attribution that Microsoft did not make.
        ProductName and DetectionSource are carried alongside and are often populated when
        ServiceSource is not.

        STATUS VOCABULARY DIFFERS FROM INCIDENTS. An alert is 'new', 'inProgress' or
        'resolved'; an incident is 'active', 'inProgress', 'resolved' or 'redirected'. An
        alert is never 'active'. Filtering both with the same string finds nothing in one of
        them, silently.

        RESOLVEDAYS IS $null WHILE AN ALERT IS OPEN, never 0 - the same reasoning as the
        incident command. Here it is computed from ResolvedUtc, which Graph populates
        properly, rather than inferred from the last update.

        EVIDENCE IS NOT FLATTENED. Every alert carries an evidence array - devices, users,
        files, IP addresses, mailboxes - with a different shape per entity type. Flattening it
        would either lose most of it or produce a column set that changes per row, so the
        count is reported and the array stays on Raw.evidence for anything that needs it.

    .PARAMETER Days
        How far back to look at CREATION time. Default 30.

    .PARAMETER Severity
        Only these severities: informational, low, medium, high.

    .PARAMETER Status
        Only these statuses: new, inProgress, resolved.

    .PARAMETER ServiceSource
        Only alerts from these workloads, matched case-insensitively against ServiceSource -
        e.g. microsoftDefenderForEndpoint, microsoftDefenderForOffice365, dataLossPrevention.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecDefenderAlert -Days 90 -Severity high | Sort-Object CreatedUtc -Descending

    .EXAMPLE
        # The unworked queue: high-severity alerts nobody has picked up.
        Get-MsecDefenderAlert -Days 90 -Severity high -Status new |
            Format-Table CreatedUtc, Title, ServiceSource, IncidentId

    .EXAMPLE
        # Which detectors produce the most noise.
        Get-MsecDefenderAlert -Days 90 | Group-Object Title |
            Sort-Object Count -Descending | Select-Object -First 15

    .OUTPUTS
        One PSCustomObject per alert, PSTypeName 'MsecDefenderAlert'.

    .NOTES
        Needs Connect-Msec. Documented as 'SecurityAlert.Read.All'; measured on a live tenant
        the endpoint also answers for an app holding SecurityIncident.Read.All and
        SecurityEvents.Read.All, both of which New-MsecApp grants - so it works today without
        an extra consent. If a tenant answers 403, that permission is the one to add.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateRange(1, 365)]
        [int] $Days = 30,

        [ValidateSet('informational', 'low', 'medium', 'high')]
        [string[]] $Severity,

        # NOT the incident vocabulary - see the note in the description.
        [ValidateSet('new', 'inProgress', 'resolved')]
        [string[]] $Status,

        [string[]] $ServiceSource
    )

    Assert-MsecSession

    $startStr = (Get-Date).ToUniversalTime().AddDays(-$Days).ToString('yyyy-MM-ddTHH:mm:ssZ')

    try {
        $alerts = @(Invoke-MsecGraphRequest -Path "/v1.0/security/alerts_v2?`$filter=createdDateTime ge $startStr" -All)
    }
    catch {
        if ($_.Exception.Message -match '403|Forbidden') {
            throw "Forbidden when calling /security/alerts_v2. The msec app needs the 'SecurityAlert.Read.All' application permission (admin consent required). Original error: $($_.Exception.Message)"
        }
        throw
    }

    $parse = {
        param($value)
        if ($value) { [datetime]::Parse($value, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } else { $null }
    }

    foreach ($a in $alerts) {
        if ($Severity      -and [string]$a.severity      -notin $Severity) { continue }
        if ($Status        -and [string]$a.status        -notin $Status)   { continue }
        if ($ServiceSource -and [string]$a.serviceSource -notin $ServiceSource) { continue }

        $created  = & $parse $a.createdDateTime
        $resolved = & $parse $a.resolvedDateTime

        [PSCustomObject]@{
            PSTypeName        = 'MsecDefenderAlert'
            Id                = [string] $a.id
            # The alert's id in the product that raised it. For endpoint alerts this is the key
            # into the Defender for Endpoint API, which is the only place a comment can be
            # written - Graph has no writable comment on an alert. See Set-MsecDefenderAlert.
            ProviderAlertId   = [string] $a.providerAlertId
            Title             = [string] $a.title
            Severity          = [string] $a.severity
            Status            = [string] $a.status
            Category          = [string] $a.category
            # 'unknownFutureValue' is Graph's placeholder, not a workload - see the help.
            ServiceSource     = [string] $a.serviceSource
            DetectionSource   = [string] $a.detectionSource
            ProductName       = [string] $a.productName
            IncidentId        = [string] $a.incidentId
            AssignedTo        = [string] $a.assignedTo
            Classification    = [string] $a.classification
            Determination     = [string] $a.determination
            CreatedUtc        = $created
            FirstActivityUtc  = & $parse $a.firstActivityDateTime
            LastActivityUtc   = & $parse $a.lastActivityDateTime
            ResolvedUtc       = $resolved
            # $null while open, never 0.
            ResolveDays       = if ($created -and $resolved) { [math]::Round(($resolved - $created).TotalDays, 1) } else { $null }
            # Counted, not flattened - the shape differs per entity type. Raw.evidence has it.
            EvidenceCount     = @($a.evidence).Count
            MitreTechniques   = (@($a.mitreTechniques) -join '; ')
            ThreatDisplayName = [string] $a.threatDisplayName
            AlertWebUrl       = [string] $a.alertWebUrl
            Raw               = $a
        }
    }
}
