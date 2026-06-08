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

        Requires the 'AuditLog.Read.All' application permission. A clearer error
        is raised on the typical 403.

    .PARAMETER Days
        Window size in days. Default 1, max 30 (Graph retention cap).

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
          mfaDetail.authMethod            -> MfaAuthMethod
          riskLevelAggregated             -> RiskLevelAggregated
          riskLevelDuringSignIn           -> RiskLevelDuringSignIn
          status.errorCode                -> ResultCode
          status.failureReason            -> ResultFailureReason
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(1, 30)]
        [int] $Days = 1
    )

    Assert-MsecSession

    $startUtc = (Get-Date).ToUniversalTime().AddDays(-$Days)
    $startStr = $startUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')

    # $select trims each event from ~50 columns to the ones documented above.
    # appliedConditionalAccessPolicies has to stay as the nested array (it's
    # multi-valued per event) - we just don't try to flatten it further.
    $select = @(
        'id'
        'createdDateTime'
        'userPrincipalName', 'userDisplayName', 'userId'
        'appDisplayName', 'appId'
        'ipAddress', 'location'
        'clientAppUsed'
        'deviceDetail'
        'conditionalAccessStatus'
        'appliedConditionalAccessPolicies'
        'mfaDetail'
        'riskLevelAggregated', 'riskLevelDuringSignIn'
        'status'
    ) -join ','

    $path = "/v1.0/auditLogs/signIns?`$filter=createdDateTime ge $startStr&`$select=$select"

    try {
        $events = @(Invoke-MsecGraphRequest -Path $path -All)
    }
    catch {
        if ($_.Exception.Message -match '403|Forbidden') {
            throw "Forbidden when calling /auditLogs/signIns. The msec app needs the 'AuditLog.Read.All' application permission (admin consent required). Re-run New-MsecApp to add and consent it. Original error: $($_.Exception.Message)"
        }
        throw
    }

    foreach ($e in $events) {
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
            ConditionalAccessStatus = $e.conditionalAccessStatus
            AppliedPolicies         = @($e.appliedConditionalAccessPolicies)
            MfaAuthMethod           = $e.mfaDetail.authMethod
            RiskLevelAggregated     = $e.riskLevelAggregated
            RiskLevelDuringSignIn   = $e.riskLevelDuringSignIn
            ResultCode              = $e.status.errorCode
            ResultFailureReason     = $e.status.failureReason
        }
    }
}
