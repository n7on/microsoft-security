function Get-MsecDefenderIncident {
    <#
    .SYNOPSIS
        One row per Defender XDR incident - what it is, how severe, whether anyone has
        triaged it, and how long it took to resolve.

    .DESCRIPTION
        The row-level companion to Get-MsecDefenderIncidentStats, which answers the same
        questions as a single summary. Use this one to see WHICH incidents, and the stats
        command for a trend line.

        REDIRECTED INCIDENTS ARE NOT SEPARATE INCIDENTS. When Defender decides two incidents
        are the same attack it merges them, leaving the absorbed one with status 'redirected'
        and a RedirectedToIncidentId. Counting those as incidents double-counts the same
        activity - measured on a live tenant, 51 of 474 in ninety days. They are returned
        anyway, because an incident that vanished from a count needs to be explainable, and
        -ExcludeRedirected drops them when you want the deduplicated number.

        CLASSIFICATION AND DETERMINATION ARE ANALYST JUDGEMENTS, NOT DETECTIONS. They stay
        'unknown' until a human sets them, so they measure triage effort rather than truth.
        Measured live: all 474 incidents were 'unknown', which is a finding about the process
        rather than about the incidents.

        RESOLVEDAYS IS $null WHILE AN INCIDENT IS OPEN, never 0. Graph reports no resolution
        time for an unresolved incident, and a zero there would read as "closed instantly" -
        which is the opposite of a still-running investigation.

    .PARAMETER Days
        How far back to look at CREATION time. Default 30.

    .PARAMETER Severity
        Only these severities: informational, low, medium, high.

    .PARAMETER Status
        Only these statuses: active, inProgress, resolved, redirected.

    .PARAMETER ExcludeRedirected
        Drop incidents merged into another one. Use when counting; omit when explaining.

    .PARAMETER IncludeAlerts
        Also fetch each incident's alerts and report AlertCount and the distinct detection
        sources. One extra call per incident, so it is opt-in.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecDefenderIncident -Days 90 -ExcludeRedirected |
            Where-Object Status -ne 'resolved' | Sort-Object Severity

    .EXAMPLE
        # The triage gap: open incidents nobody has classified.
        Get-MsecDefenderIncident -Days 90 |
            Where-Object { $_.Status -eq 'active' -and $_.Classification -eq 'unknown' }

    .OUTPUTS
        One PSCustomObject per incident, PSTypeName 'MsecDefenderIncident'.

    .NOTES
        Needs Connect-Msec and the 'SecurityIncident.Read.All' application permission, which
        New-MsecApp grants.

        $top is not set: /security/incidents caps it at 50 and rejects larger values. Paging
        is handled by -All regardless of page size.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateRange(1, 365)]
        [int] $Days = 30,

        [ValidateSet('informational', 'low', 'medium', 'high')]
        [string[]] $Severity,

        [ValidateSet('active', 'inProgress', 'resolved', 'redirected')]
        [string[]] $Status,

        [switch] $ExcludeRedirected,

        [switch] $IncludeAlerts
    )

    Assert-MsecSession

    $startStr = (Get-Date).ToUniversalTime().AddDays(-$Days).ToString('yyyy-MM-ddTHH:mm:ssZ')

    try {
        $incidents = @(Invoke-MsecGraphRequest -Path "/v1.0/security/incidents?`$filter=createdDateTime ge $startStr" -All)
    }
    catch {
        if ($_.Exception.Message -match '403|Forbidden') {
            throw "Forbidden when calling /security/incidents. The msec app needs the 'SecurityIncident.Read.All' application permission (admin consent required). Re-run New-MsecApp to add and consent it. Original error: $($_.Exception.Message)"
        }
        throw
    }

    foreach ($i in $incidents) {
        if ($Severity -and [string]$i.severity -notin $Severity) { continue }
        if ($Status   -and [string]$i.status   -notin $Status)   { continue }
        if ($ExcludeRedirected -and $i.redirectIncidentId) { continue }

        $created  = if ($i.createdDateTime) { [datetime]::Parse($i.createdDateTime, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } else { $null }
        $updated  = if ($i.lastUpdateDateTime) { [datetime]::Parse($i.lastUpdateDateTime, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } else { $null }

        # Only meaningful once resolved - see the note in the help.
        $resolveDays = if ([string]$i.status -eq 'resolved' -and $created -and $updated) {
            [math]::Round(($updated - $created).TotalDays, 1)
        } else { $null }

        $alertCount = $null
        $sources = $null
        if ($IncludeAlerts) {
            try {
                $alerts = @(Invoke-MsecGraphRequest -Path "/v1.0/security/incidents/$($i.id)/alerts" -All)
                $alertCount = $alerts.Count
                $sources = (@($alerts.serviceSource | Where-Object { $_ } | Sort-Object -Unique) -join '; ')
            }
            catch {
                # $null rather than 0: an incident whose alerts could not be read has not been
                # shown to have none.
                Write-Verbose "Could not read alerts for incident $($i.id): $($_.Exception.Message)"
            }
        }

        [PSCustomObject]@{
            PSTypeName             = 'MsecDefenderIncident'
            Id                     = [string] $i.id
            DisplayName            = [string] $i.displayName
            Severity               = [string] $i.severity
            Status                 = [string] $i.status
            # Analyst judgements, not detections - 'unknown' means nobody has triaged it.
            Classification         = [string] $i.classification
            Determination          = [string] $i.determination
            AssignedTo             = [string] $i.assignedTo
            CreatedUtc             = $created
            LastUpdateUtc          = $updated
            ResolveDays            = $resolveDays
            AlertCount             = $alertCount
            AlertSources           = $sources
            # Set when this incident was merged INTO another - see the help.
            RedirectedToIncidentId = [string] $i.redirectIncidentId
            Tags                   = (@(@($i.customTags) + @($i.systemTags) | Where-Object { $_ }) -join '; ')
            IncidentWebUrl         = [string] $i.incidentWebUrl
            Raw                    = $i
        }
    }
}
