function Get-MsecDefenderIncidentStats {
    <#
    .SYNOPSIS
        Microsoft Defender XDR incident summary: severity / classification / status
        breakdown for a period, plus current-backlog point-in-time view.

    .DESCRIPTION
        Queries Microsoft Graph /security/incidents and returns a single PSCustomObject
        per call covering three different cuts:

          - "Volume in window"       - incidents CREATED in the last -Days days.
                                       Drives Total, severity, classification buckets.
          - "Resolution in window"   - incidents RESOLVED (status='resolved') in the same
                                       window, regardless of when they were created.
                                       Drives MTTR / median TTR.
          - "Backlog (point-in-time)"- incidents currently in status active OR inProgress,
                                       independent of -Days. Drives CurrentlyOpen and
                                       OldestOpenAgeDays.

        Field names mirror the Microsoft Defender XDR portal labels: severity is
        High/Medium/Low/Informational (no 'Critical' - the API's top severity is high).
        Classification follows Microsoft's current naming (TruePositive / FalsePositive /
        BenignPositive / Unclassified). 'BenignPositive' bucket includes both the
        legacy 'benignPositive' value and the newer 'informationalExpectedActivity'
        Microsoft replaced it with.

        MTTR best practice: computed only over incidents classified as TruePositive or
        BenignPositive. FalsePositive incidents typically close in minutes and would
        artificially deflate the average; not counting them gives a more honest "time
        to handle real things" number.

        CONSEQUENCE, and read ResolvedClassifiedCount before trusting an MTTR: because
        UNCLASSIFIED incidents are excluded too, a team that closes incidents without
        setting a classification gets MeanTimeToResolveHours = $null however many
        incidents it resolved. That null means "nothing qualified to be averaged" - it is
        neither a collection failure nor a claim that resolution was instant. Equally, an
        MTTR backed by ResolvedClassifiedCount = 1 is one incident, not an average; that
        is the case where mean and median come back identical.

        Requires the 'SecurityIncident.Read.All' application permission on the msec
        app registration (admin consent required). A clearer error is raised on the
        typical 403.

    .PARAMETER Days
        Window size in days, applied to BOTH createdDateTime (for volume) and
        lastUpdateDateTime (for resolution). Default 30. Backlog metrics
        (CurrentlyOpen / OldestOpenAgeDays) ignore this and always show right-now.

    .EXAMPLE
        Get-MsecDefenderIncidentStats              # last 30 days + current backlog

    .EXAMPLE
        Get-MsecDefenderIncidentStats -Days 7      # last week for a posture-meeting view

    .EXAMPLE
        Get-MsecDefenderIncidentStats -Days 90 |   # quarterly window
            Select-Object TotalCreated, High, Medium, MeanTimeToResolveHours, CurrentlyOpen

    .OUTPUTS
        PSCustomObject with StartDate, EndDate, volume/severity/classification counts,
        TotalResolvedInWindow + ResolvedClassifiedCount, MTTR (mean + median in hours),
        CurrentlyOpen + OldestOpenAgeDays.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(1, 365)]
        [int] $Days = 30
    )

    Assert-MsecSession

    $now      = (Get-Date).ToUniversalTime()
    $startUtc = $now.AddDays(-$Days)
    $startStr = $startUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')

    # Small helper: GET a $filter'd incident list, paginating through @odata.nextLink.
    # Don't set $top - /security/incidents caps it at 50, so passing larger values
    # is rejected. The -All flag handles paging transparently regardless of page size.
    $listIncidents = {
        param([string]$filter)
        $path = "/v1.0/security/incidents?`$filter=$filter"
        try {
            @(Invoke-MsecGraphRequest -Path $path -All)
        }
        catch {
            if ($_.Exception.Message -match '403|Forbidden') {
                throw "Forbidden when calling /security/incidents. The msec app needs the 'SecurityIncident.Read.All' application permission (admin consent required). Re-run New-MsecApp to add and consent it. Original error: $($_.Exception.Message)"
            }
            throw
        }
    }

    # ---- Three independent queries, three different "what counts?" semantics ----
    $createdInWindow  = & $listIncidents "createdDateTime ge $startStr"
    $resolvedInWindow = & $listIncidents "lastUpdateDateTime ge $startStr and status eq 'resolved'"
    $currentlyOpen    = & $listIncidents "status eq 'active' or status eq 'inProgress'"

    # ---- Bucket the created-in-window incidents ----
    $sev = @{ high = 0; medium = 0; low = 0; informational = 0 }
    $cls = @{ truePositive = 0; falsePositive = 0; benignPositive = 0; unclassified = 0 }

    foreach ($i in $createdInWindow) {
        $s = if ($i.severity) { ([string]$i.severity).ToLower() } else { $null }
        if ($s -and $sev.ContainsKey($s)) { $sev[$s]++ }

        # Microsoft renamed 'benignPositive' to 'informationalExpectedActivity'; treat
        # both as the same bucket so the column is stable across API versions.
        $c = if ($i.classification) { [string]$i.classification } else { 'unknown' }
        switch -CaseSensitive ($c) {
            'truePositive'                  { $cls.truePositive++ }
            'falsePositive'                 { $cls.falsePositive++ }
            'benignPositive'                { $cls.benignPositive++ }
            'informationalExpectedActivity' { $cls.benignPositive++ }
            default                         { $cls.unclassified++ }
        }
    }

    # ---- Mean/median time-to-resolve, over TruePositive + BenignPositive only ----
    $resolvedRealIncidents = @($resolvedInWindow | Where-Object {
        $c = [string]$_.classification
        $c -in @('truePositive', 'benignPositive', 'informationalExpectedActivity')
    })

    $hoursList = foreach ($i in $resolvedRealIncidents) {
        $created  = [datetime]$i.createdDateTime
        $resolved = [datetime]$i.lastUpdateDateTime
        ($resolved - $created).TotalHours
    }
    $hoursList = @($hoursList)

    $meanMttr = $null
    $medianMttr = $null
    if ($hoursList.Count -gt 0) {
        $meanMttr = [math]::Round(($hoursList | Measure-Object -Average).Average, 2)

        $sorted = $hoursList | Sort-Object
        $n = $sorted.Count
        $medianMttr = [math]::Round(
            $(if ($n % 2 -eq 1) {
                $sorted[[int]([math]::Floor($n / 2))]
            } else {
                ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2.0
            }),
            2
        )
    }

    # ---- Backlog (point-in-time) ----
    $oldestOpenAgeDays = $null
    if ($currentlyOpen.Count -gt 0) {
        $oldest = ($currentlyOpen |
                   Sort-Object @{ Expression = { [datetime]$_.createdDateTime } } |
                   Select-Object -First 1).createdDateTime
        $oldestOpenAgeDays = [math]::Round(($now - [datetime]$oldest).TotalDays, 1)
    }

    [PSCustomObject]@{
        StartDate                = $startUtc.Date
        EndDate                  = $now.Date

        # Volume in window
        TotalCreated             = $createdInWindow.Count
        High                     = $sev.high
        Medium                   = $sev.medium
        Low                      = $sev.low
        Informational            = $sev.informational
        TruePositive             = $cls.truePositive
        FalsePositive            = $cls.falsePositive
        BenignPositive           = $cls.benignPositive
        Unclassified             = $cls.unclassified

        # Resolution in window
        TotalResolvedInWindow    = $resolvedInWindow.Count
        # The DENOMINATOR behind the two MTTR figures, and the reason they can be null.
        # Emitted so a consumer never has to guess: 0 means "nothing was classified, so
        # there was nothing to average" (not "resolution was instant" and not a
        # collection failure), and a low number means the average rests on that few
        # incidents. Always <= TotalResolvedInWindow.
        ResolvedClassifiedCount  = $hoursList.Count
        MeanTimeToResolveHours   = $meanMttr
        MedianTimeToResolveHours = $medianMttr

        # Backlog (point-in-time, ignores -Days)
        CurrentlyOpen            = $currentlyOpen.Count
        OldestOpenAgeDays        = $oldestOpenAgeDays
    }
}
