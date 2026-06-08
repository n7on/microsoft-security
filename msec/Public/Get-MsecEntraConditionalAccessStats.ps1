function Get-MsecEntraConditionalAccessStats {
    <#
    .SYNOPSIS
        Aggregated Conditional Access insights over the last N days - the data
        behind the "Conditional Access insights and reporting" workbook in the
        Entra portal, in a single summary row.

    .DESCRIPTION
        Internally calls Get-MsecEntraConditionalAccessSignInLog -Days $Days and
        aggregates the sign-in events. Returns one PSCustomObject covering:

          - Volume:   TotalSignIns, UniqueUsers
          - CA mix:   CaSuccess / CaFailure / CaNotApplied (mutually exclusive,
                      sum to TotalSignIns) + their percentages
          - Risk:     HighRiskSignIns, MediumRiskSignIns (from Identity Protection)
          - Report-only impact: ReportOnlyWouldBlock - sign-ins that a report-only
                      policy WOULD HAVE blocked if it were enforced. The single
                      most useful metric for "is it safe to flip this report-only
                      policy to enabled?"
          - TopFailingPolicies: top-5 policies by failure count (nested array of
                      {Name, Count} objects).

        This function is a thin aggregation over the raw sign-in log. It pulls
        every sign-in event for the window once, so the API cost is the same as
        a single Get-MsecEntraConditionalAccessSignInLog call - heavy in busy
        tenants. The default -Days 7 matches the portal workbook's default view
        and keeps the cost bounded.

        Permission requirement is inherited from Get-MsecEntraConditionalAccessSignInLog
        (AuditLog.Read.All).

    .PARAMETER Days
        Window size in days. Default 7, max 30 (Graph signIn retention cap).

    .EXAMPLE
        Get-MsecEntraConditionalAccessStats              # last 7 days

    .EXAMPLE
        Get-MsecEntraConditionalAccessStats -Days 30 | Format-List

    .EXAMPLE
        # Slot it into the bi-weekly archive snapshot:
        $snapshot = [pscustomobject]@{
            CapturedAtUtc = (Get-Date).ToUniversalTime().ToString('u')
            SecureScore   = Get-MsecSecureScore -Top 1
            EmailStats    = Get-MsecDefenderEmailStats -Days 30
            IncidentStats = Get-MsecDefenderIncidentStats -Days 30
            CaStats       = Get-MsecEntraConditionalAccessStats -Days 7
        }

    .OUTPUTS
        PSCustomObject with StartDate, EndDate, volume + CA-outcome + risk +
        report-only + TopFailingPolicies columns.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(1, 30)]
        [int] $Days = 7
    )

    # No Assert-MsecSession here - the inner call asserts, and double-checking
    # would just give a misleading stack trace.

    $log   = @(Get-MsecEntraConditionalAccessSignInLog -Days $Days)
    $total = $log.Count

    # Closure for percent-of-total math. Returns 0.0 (not null) when total is 0
    # so the row schema stays consistent (no mixed-type columns in the archive).
    $pct = {
        param($n)
        if ($total -gt 0) { [math]::Round($n / $total * 100, 2) } else { 0.0 }
    }

    # CA outcomes are mutually exclusive: every sign-in has exactly one
    # ConditionalAccessStatus value. Sum should equal $total (modulo 'unknown'
    # for very rare cases - we count what's there).
    $caSuccess    = ($log | Where-Object ConditionalAccessStatus -eq 'success').Count
    $caFailure    = ($log | Where-Object ConditionalAccessStatus -eq 'failure').Count
    $caNotApplied = ($log | Where-Object ConditionalAccessStatus -eq 'notApplied').Count

    # Identity Protection risk levels (only populated when IP is licensed and
    # actually evaluating sign-ins).
    $highRisk   = ($log | Where-Object RiskLevelDuringSignIn -eq 'high').Count
    $mediumRisk = ($log | Where-Object RiskLevelDuringSignIn -eq 'medium').Count

    # Per-applied-policy aggregations: flatten the nested AppliedPolicies array
    # so we can group across all events.
    $applied = $log | ForEach-Object { $_.AppliedPolicies }

    # Report-only WOULD-block: the headline "is this safe to turn on?" metric.
    $reportOnlyWouldBlock =
        ($applied | Where-Object result -in 'reportOnlyFailure', 'reportOnlyInterrupted').Count

    # Top-5 failing policies (by failed-application count). Returned as an
    # explicit array so the column shape is stable even when there are <5.
    $topFailing = @(
        $applied |
            Where-Object result -eq 'failure' |
            Group-Object displayName |
            Sort-Object Count -Descending |
            Select-Object -First 5 @{n = 'Name'; e = { $_.Name } },
                                   @{n = 'Count'; e = { $_.Count } }
    )

    $now      = (Get-Date).ToUniversalTime()
    $startUtc = $now.AddDays(-$Days)

    [PSCustomObject]@{
        StartDate            = $startUtc.Date
        EndDate              = $now.Date

        TotalSignIns         = $total
        UniqueUsers          = ($log.UserPrincipalName | Sort-Object -Unique).Count

        CaSuccess            = $caSuccess
        CaFailure            = $caFailure
        CaNotApplied         = $caNotApplied
        CaSuccessPercent     = & $pct $caSuccess
        CaFailurePercent     = & $pct $caFailure

        HighRiskSignIns      = $highRisk
        MediumRiskSignIns    = $mediumRisk

        ReportOnlyWouldBlock = $reportOnlyWouldBlock

        TopFailingPolicies   = $topFailing
    }
}
