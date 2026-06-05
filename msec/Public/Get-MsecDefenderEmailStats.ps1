function Get-MsecDefenderEmailStats {
    <#
    .SYNOPSIS
        Inbound email volume and threat breakdown over the last N days.

    .DESCRIPTION
        Queries Microsoft 365 Defender's advanced-hunting EmailEvents table via
        Microsoft Graph (/security/runHuntingQuery) and returns a single summary
        row covering the requested window:

          - Total inbound volume
          - DeliveryAction counts: Delivered / Junked / Blocked / Replaced
          - ThreatTypes counts:    Phishing / Spam / Malware
          - Percentages of Total for each of the above

        Direction is filtered to Inbound only - "phishing stats" almost always
        means "what attackers sent into the org". Outbound/intra-org are excluded
        by the KQL.

        Counting note: ThreatTypes is a comma-separated multi-value column. A
        single email can simultaneously be Phish AND Spam, in which case it
        counts in both `Phishing` and `Spam`. Means `Phishing + Spam + Malware`
        will not in general add up to Total.

        Requires the 'ThreatHunting.Read.All' application permission on the msec
        app registration (admin-consent required). A clearer error is raised on
        the typical 403.

    .PARAMETER Days
        Window size in days. Default 7 (Microsoft 365 Defender portal default).

    .EXAMPLE
        # Last 7 days, single summary row.
        Get-MsecDefenderEmailStats

    .EXAMPLE
        Get-MsecDefenderEmailStats -Days 30 | Format-Table -AutoSize

    .EXAMPLE
        # Combine with the other Defender scores for an archive snapshot.
        $snapshot = [pscustomobject]@{
            CapturedAtUtc = (Get-Date).ToUniversalTime().ToString('u')
            SecureScore   = Get-MsecSecureScore -Top 1
            Email         = Get-MsecDefenderEmailStats -Days 30
        }

    .OUTPUTS
        PSCustomObject with StartDate, EndDate, Total, the four DeliveryAction
        counts, the three ThreatTypes counts, and their percentages of Total.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(1, 180)]
        [int] $Days = 7
    )

    Assert-MsecSession

    # The summarize gives us exactly one row regardless of email volume - no paging,
    # no client-side aggregation. countif() uses == for DeliveryAction (single value)
    # and `has` for ThreatTypes (multi-value tokenised match).
    $kql = @"
EmailEvents
| where Timestamp >= ago(${Days}d) and EmailDirection == "Inbound"
| summarize
    Total     = count(),
    Delivered = countif(DeliveryAction == "Delivered"),
    Junked    = countif(DeliveryAction == "JunkFolder"),
    Blocked   = countif(DeliveryAction == "Blocked"),
    Replaced  = countif(DeliveryAction == "Replaced"),
    Phishing  = countif(ThreatTypes has "Phish"),
    Spam      = countif(ThreatTypes has "Spam"),
    Malware   = countif(ThreatTypes has "Malware")
"@

    try {
        $response = Invoke-MsecGraphRequest `
            -Path   '/v1.0/security/runHuntingQuery' `
            -Method POST `
            -Body   @{ Query = $kql }
    }
    catch {
        # 403 here is overwhelmingly "you forgot to consent ThreatHunting.Read.All".
        # Promote it to a clearer message so the user doesn't have to dig.
        if ($_.Exception.Message -match '403|Forbidden') {
            throw "Forbidden when calling /security/runHuntingQuery. The msec app needs the 'ThreatHunting.Read.All' application permission (admin consent required). Add it in Entra > App registrations > <msec-app> > API permissions, grant admin consent, then retry. Original error: $($_.Exception.Message)"
        }
        throw
    }

    # Response shape: { Schema: [...], Results: [{ Total: N, Delivered: N, ... }] }.
    # With our summarize there's always exactly one row - but defensively handle the
    # zero-row case (could happen on a fresh tenant with no email history).
    $row = if ($response.Results -and @($response.Results).Count -gt 0) {
        $response.Results[0]
    }
    else {
        @{}
    }

    # Numeric coalesce - PSObject property access on a missing key returns $null,
    # and (int)$null == 0, but the explicit coalesce makes intent obvious.
    $intOf = { param($name) [int](($row.$name) ?? 0) }
    $total = & $intOf 'Total'
    $pct   = {
        param($n)
        if ($total -gt 0) { [math]::Round(($n / $total) * 100, 2) } else { 0.0 }
    }

    $delivered = & $intOf 'Delivered'
    $junked    = & $intOf 'Junked'
    $blocked   = & $intOf 'Blocked'
    $replaced  = & $intOf 'Replaced'
    $phishing  = & $intOf 'Phishing'
    $spam      = & $intOf 'Spam'
    $malware   = & $intOf 'Malware'

    [PSCustomObject]@{
        StartDate        = (Get-Date).Date.AddDays(-$Days)
        EndDate          = (Get-Date).Date
        Total            = $total
        Delivered        = $delivered
        Junked           = $junked
        Blocked          = $blocked
        Replaced         = $replaced
        Phishing         = $phishing
        Spam             = $spam
        Malware          = $malware
        DeliveredPercent = & $pct $delivered
        JunkedPercent    = & $pct $junked
        BlockedPercent   = & $pct $blocked
        PhishingPercent  = & $pct $phishing
        SpamPercent      = & $pct $spam
        MalwarePercent   = & $pct $malware
    }
}
