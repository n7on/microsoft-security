function Get-MsecEntraConditionalAccessSignInLog {
    <#
    .SYNOPSIS
        Raw Entra sign-in events with Conditional Access outcomes attached, for the
        last N days. One row per sign-in attempt.

    .DESCRIPTION
        Calls Microsoft Graph /v1.0/auditLogs/signIns?$filter=createdDateTime ge {start}
        and projects each event to a flat PSCustomObject with the CA-relevant
        fields surfaced. Interactive sign-ins only (the kind CA evaluates) -
        non-interactive token refreshes are not included by default. If you need
        those, the Graph endpoint supports a signInEventTypes filter (out of scope
        here).

        This is the data behind the Conditional Access "Insights and reporting"
        workbook in the Entra portal. Aggregate it in PowerShell on the consumer
        side - msec only returns the raw rows.

            $log = Get-MsecEntraConditionalAccessSignInLog -Days 1

            # CA outcome counts
            $log | Group-Object ConditionalAccessStatus

            # Sign-ins blocked by CA
            $log | Where ConditionalAccessStatus -eq 'failure' |
                Select CreatedDateTime, UserPrincipalName, AppDisplayName, AppliedPolicies

            # Top failing policies
            $log |
                Where ConditionalAccessStatus -eq 'failure' |
                ForEach-Object { $_.AppliedPolicies | Where-Object result -eq 'failure' } |
                Group-Object displayName | Sort Count -Descending

        VOLUME WARNING: in a busy tenant, expect ~10k-100k+ interactive sign-ins
        per day. Default window is intentionally narrow (1 day) so you don't
        accidentally pull 700k events. Widen with -Days deliberately, and consider
        using Where-Object on a small column projection if you only need a
        subset.

        Microsoft Graph caps sign-in log retention at 30 days for the
        /auditLogs/signIns endpoint (Premium tenants get longer retention via
        Log Analytics export, not via Graph) - hence the -Days max of 30.

        Requires the 'AuditLog.Read.All' application permission AND Microsoft Entra ID
        P1 or P2 on the tenant - the endpoint is premium-gated independently of
        permissions. A 403 is re-thrown with Graph's own message and is distinguished
        between the two causes, because a licensing 403 cannot be fixed by granting a
        permission.

    .PARAMETER Days
        Window size in days. Default 1, max 30 (Graph retention cap).

    .PARAMETER UserId
        Restrict to these user object ids. Without it every sign-in in the window is
        paged, which on a real tenant is tens of thousands of events per day; with it
        Graph filters server-side and a handful of users costs almost nothing. Ids are
        batched 15 per request so a long list cannot overflow the URL length limit.

        Use the object id, not the UPN - userId is the filterable property here.

    .EXAMPLE
        Get-MsecEntraConditionalAccessSignInLog -Days 1 |
            Group-Object ConditionalAccessStatus

    .EXAMPLE
        # Per-day blocked-by-CA count for a posture-meeting chart.
        Get-MsecEntraConditionalAccessSignInLog -Days 7 |
            Where ConditionalAccessStatus -eq 'failure' |
            Group-Object { $_.CreatedDateTime.Date } |
            Select Name, Count

    .OUTPUTS
        PSCustomObject per sign-in event. See .NOTES for the projection.

    .NOTES
        Projection (Graph field path -> output property):
          id                              -> Id
          createdDateTime                 -> CreatedDateTime ([datetime])
          userPrincipalName               -> UserPrincipalName
          userDisplayName                 -> UserDisplayName
          userId                          -> UserId
          appDisplayName                  -> AppDisplayName
          appId                           -> AppId
          ipAddress                       -> IpAddress
          location.city                   -> City
          location.state                  -> State
          location.countryOrRegion        -> Country
          clientAppUsed                   -> ClientAppUsed
          deviceDetail.operatingSystem    -> DeviceOs
          deviceDetail.browser            -> DeviceBrowser
          deviceDetail.isCompliant        -> DeviceCompliant
          deviceDetail.trustType          -> DeviceTrustType
          conditionalAccessStatus         -> ConditionalAccessStatus  (success/failure/notApplied)
          appliedConditionalAccessPolicies-> AppliedPolicies   (array; each row has id/displayName/result)
          riskLevelAggregated             -> RiskLevelAggregated
          riskLevelDuringSignIn           -> RiskLevelDuringSignIn
          status.errorCode                -> ResultCode
          status.failureReason            -> ResultFailureReason
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(1, 30)]
        [int] $Days = 1,


        [Parameter()]
        [string[]] $UserId
    )

    Assert-MsecSession

    $startUtc = (Get-Date).ToUniversalTime().AddDays(-$Days)
    $startStr = $startUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')

    # $select trims each event from ~50 columns to the ones documented above.
    # appliedConditionalAccessPolicies has to stay as the nested array (it's
    # multi-valued per event) - we just don't try to flatten it further.
    #
    # NB: the v1.0 signIn resource has NO authenticationRequirement, authenticationDetails
    # or mfaDetail property - all three are beta-only, and selecting them here would
    # produce empty columns. Whether MFA was demanded and met is therefore derived from
    # appliedConditionalAccessPolicies (see MfaRequiredByPolicies / MfaSatisfied below),
    # which is the stronger signal for evidence anyway: it names the policy and the
    # control instead of asserting a bare boolean. For per-step authentication detail,
    # query /beta/auditLogs/signIns directly.
    $select = @(
        'id'
        'createdDateTime'
        'userPrincipalName', 'userDisplayName', 'userId'
        'appDisplayName', 'appId'
        'ipAddress', 'location'
        'clientAppUsed'
        'deviceDetail'
        'isInteractive'
        'conditionalAccessStatus'
        'appliedConditionalAccessPolicies'
        'riskLevelAggregated', 'riskLevelDuringSignIn'
        'status'
    ) -join ','

    # Without -UserId this pages EVERY sign-in in the window, which on a real tenant is
    # tens of thousands of events per day - the difference between a query and a coffee
    # break. userId supports $filter (eq), so asking about a handful of users is cheap;
    # ids are batched because a filter naming hundreds of them would blow the URL length
    # limit rather than fail informatively.
    $filters = @()
    if ($UserId) {
        $ids = @($UserId | Where-Object { $_ } | Sort-Object -Unique)
        for ($i = 0; $i -lt $ids.Count; $i += 15) {
            $chunk = $ids[$i..([Math]::Min($i + 14, $ids.Count - 1))]
            $clause = ($chunk | ForEach-Object { "userId eq '$_'" }) -join ' or '
            $filters += "createdDateTime ge $startStr and ($clause)"
        }
    }
    else {
        $filters = @("createdDateTime ge $startStr")
    }

    try {
        $events = [System.Collections.Generic.List[object]]::new()
        $batchNo = 0
        foreach ($filter in $filters) {
            $batchNo++
            # One request per id batch, so a large -UserId list is several round trips.
            # Reported only when there is more than one, to keep the common case quiet.
            if ($filters.Count -gt 1) {
                Write-Progress -Id 1730 -Activity 'Reading sign-in logs' `
                    -Status "User batch $batchNo of $($filters.Count) - $($events.Count) event(s) so far" `
                    -PercentComplete (100 * ($batchNo - 1) / $filters.Count)
            }
            $path = "/v1.0/auditLogs/signIns?`$filter=$filter&`$select=$select"
            $page = @(Invoke-MsecGraphRequest -Path $path -All)
            if ($page.Count) { $events.AddRange([object[]]$page) }
        }
        if ($filters.Count -gt 1) {
            Write-Progress -Id 1730 -Activity 'Reading sign-in logs' -Completed
        }
    }
    catch {
        $err = $_
        if ($err.Exception.Message -notmatch '403|Forbidden') { throw }

        # This endpoint returns 403 for two unrelated reasons, and they need OPPOSITE
        # responses:
        #   1. the app is missing AuditLog.Read.All          -> grant + consent it
        #   2. the tenant has no Entra ID P1/P2              -> a licensing limit; no
        #      permission grant can ever fix it
        # Assuming (1) and printing that advice for a case (2) tenant is actively
        # misleading - it sends people through a New-MsecApp + consent cycle that cannot
        # change the outcome. So read what Graph actually said instead of guessing.
        $detail = Get-MsecGraphErrorMessage $err

        # "Tenant is not a B2C tenant and doesn't have premium license" is the licensing 403.
        if ($detail -match 'premium|B2C') {
            throw "Sign-in logs are not available in this tenant. Microsoft Graph reports: '$detail'. /auditLogs/signIns requires Microsoft Entra ID P1 or P2 - this is a LICENSING limit, not a permission problem, so granting 'AuditLog.Read.All' will not change it. Either license the tenant or treat Conditional Access / sign-in metrics as not applicable here."
        }

        throw "Forbidden when calling /auditLogs/signIns. Microsoft Graph reports: '$detail'. The usual cause is the msec app missing the 'AuditLog.Read.All' application permission (admin consent required) - re-run New-MsecApp to add and consent it. If that permission is already consented, check licensing instead: this endpoint also requires Entra ID P1/P2."
    }

    foreach ($e in $events) {
        # Whether MFA was DEMANDED and MET on this sign-in, read from the policies that
        # actually fired. v1.0 has no authenticationRequirement / mfaDetail field, so
        # this is the only signal available - and it is the better one for evidence,
        # because it names the policy and the control rather than asserting a bare
        # boolean. enforcedGrantControls carries 'Mfa'; PowerShell's -contains is
        # case-insensitive, so the casing difference from the policy API's 'mfa'
        # does not matter.
        $applied = @($e.appliedConditionalAccessPolicies)
        $mfaPolicies = @($applied | Where-Object { @($_.enforcedGrantControls) -contains 'Mfa' })

        [PSCustomObject]@{
            Id                      = $e.id
            CreatedDateTime         = if ($e.createdDateTime) { [datetime]$e.createdDateTime } else { $null }
            UserPrincipalName       = $e.userPrincipalName
            UserDisplayName         = $e.userDisplayName
            UserId                  = $e.userId
            AppDisplayName          = $e.appDisplayName
            AppId                   = $e.appId
            IpAddress               = $e.ipAddress
            City                    = $e.location.city
            State                   = $e.location.state
            Country                 = $e.location.countryOrRegion
            ClientAppUsed           = $e.clientAppUsed
            DeviceOs                = $e.deviceDetail.operatingSystem
            DeviceBrowser           = $e.deviceDetail.browser
            DeviceCompliant         = $e.deviceDetail.isCompliant
            DeviceTrustType         = $e.deviceDetail.trustType
            # Non-interactive sign-ins are token refreshes and background service calls.
            # They legitimately do not prompt, so counting them as single-factor would
            # make every tenant look uncovered.
            IsInteractive           = [bool] $e.isInteractive

            ConditionalAccessStatus = $e.conditionalAccessStatus
            AppliedPolicies         = @($applied)

            # Flattened MFA facts - the audit-evidence view of the same data.
            MfaRequiredByPolicies   = @($mfaPolicies | ForEach-Object { $_.displayName })
            MfaSatisfied            = @($mfaPolicies | Where-Object { $_.result -eq 'success' }).Count -gt 0
            MfaFailed               = @($mfaPolicies | Where-Object { $_.result -eq 'failure' }).Count -gt 0
            RiskLevelAggregated     = $e.riskLevelAggregated
            RiskLevelDuringSignIn   = $e.riskLevelDuringSignIn
            ResultCode              = $e.status.errorCode
            ResultFailureReason     = $e.status.failureReason
        }
    }
}
