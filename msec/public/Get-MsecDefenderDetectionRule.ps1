function Get-MsecDefenderDetectionRule {
    <#
    .SYNOPSIS
        Defender XDR custom detection rules - the scheduled advanced hunting queries that raise
        alerts - with their run status, schedule and the query behind each.

    .DESCRIPTION
        A custom detection rule is an advanced hunting query Defender runs on a schedule and
        turns into alerts. This lists them, so "do we detect that?" is answerable without
        opening the portal.

        NOT THE SAME THING AS Get-MsecSentinelRule, AND THE TWO ARE EASY TO CONFUSE because
        Microsoft calls both "detection rules". They live in different products, read different
        data, and neither can see the other's:

            Get-MsecDefenderDetectionRule  Defender XDR    queries advanced hunting tables
            Get-MsecSentinelRule           Sentinel        queries a Log Analytics workspace

        A tenant whose Defender data is not connected to Sentinel cannot write a Sentinel rule
        over DeviceEvents at all - measured on one tenant, 53 Sentinel rules and not one of them
        able to see a Defender device event, because no Device* table exists in the workspace.
        Asking the wrong command returns a confident list of the wrong rules.

        'AUTODISABLED' IS THE REASON THIS IS WORTH RUNNING. Defender switches a custom detection
        off by itself when its query starts failing - a renamed column, a table that stopped
        resolving, a schema change. The rule still exists, still appears in the portal list, and
        has silently stopped running. That is indistinguishable from a rule that is working and
        finding nothing, which is the most expensive failure a detection can have.

        STATUS, NOT ISENABLED. The isEnabled property was REMOVED from this resource on
        2026-10-01, along with detectorId and lastRunDetails. Code still reading isEnabled gets
        $null, which is falsy, and reports every rule as disabled. Status carries the same
        information plus the autoDisabled value isEnabled could never express.

    .PARAMETER Name
        Substring match on the display name, case-insensitive.

    .PARAMETER Status
        Only rules in this run state: 'enabled', 'disabled' or 'autoDisabled'.

    .PARAMETER Query
        Substring match on the rule's hunting query. 'DeviceEvents', 'Asr', a table name -
        answers "is anything watching this?" without reading every rule.

    .EXAMPLE
        Get-MsecDefenderDetectionRule | Where-Object Status -eq 'autoDisabled'

        Rules Defender has switched off because their query broke. They look live in the portal
        and are not running.

    .EXAMPLE
        Get-MsecDefenderDetectionRule -Query 'Asr'

        Whether anything detects on attack surface reduction events. Most ASR rules raise no
        alert of their own, so without a custom detection a block is invisible.

    .EXAMPLE
        Get-MsecDefenderDetectionRule | Select-Object DisplayName, Status, Frequency, NextRun, Severity

        The whole detection surface at a glance.

    .OUTPUTS
        PSCustomObject per rule, PSTypeName 'MsecDefenderDetectionRule'.

    .NOTES
        Needs the 'CustomDetection.Read.All' application permission, which New-MsecApp grants.
        An app created before that was added must re-run New-MsecApp and re-consent.

        Reads the beta endpoint: custom detection rules are beta-only in Microsoft Graph at the
        time of writing, and the run-detail properties are not exposed in v1.0 at all.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string] $Name,

        [ArgumentCompleter({
            param($c, $p, $wordToComplete)
            @('enabled', 'disabled', 'autoDisabled') |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
        })]
        [string] $Status,

        [string] $Query
    )

    Assert-MsecSession

    try {
        $rules = @(Invoke-MsecGraphRequest -Path '/beta/security/rules/detectionRules' -All)
    }
    catch {
        $message = "$($_.Exception.Message)"
        if ($message -match '403|Forbidden') {
            throw "Forbidden when calling /security/rules/detectionRules. The msec app needs the 'CustomDetection.Read.All' application permission - this is NOT covered by ThreatHunting.Read.All, which only lets the app RUN hunting queries, not see the scheduled detections built on them. Re-run New-MsecApp to add and consent it, then Disconnect-Msec / Connect-Msec. Original error: $message"
        }
        throw
    }

    if (-not $rules.Count) {
        Write-Warning "No Defender XDR custom detection rules exist in this tenant. Note this is NOT the same as having no detections: Microsoft's own built-in analytics are separate and are not listed here, and Sentinel analytics rules are a different store entirely (Get-MsecSentinelRule)."
        return
    }

    $autoDisabled = 0

    foreach ($rule in $rules) {
        if ($Name -and "$($rule.displayName)" -notmatch [regex]::Escape($Name)) { continue }

        $queryText = [string] $rule.queryCondition.queryText
        if ($Query -and $queryText -notmatch [regex]::Escape($Query)) { continue }

        # 'status' replaced 'isEnabled', which was removed from the resource on 2026-10-01.
        # Falling back to it only where status is absent keeps an older tenant working without
        # letting a $null isEnabled quietly mean 'disabled'.
        $ruleStatus = if ("$($rule.status)") { [string] $rule.status }
                      elseif ($null -ne $rule.isEnabled) { if ($rule.isEnabled) { 'enabled' } else { 'disabled' } }
                      else { $null }

        if ($Status -and "$ruleStatus" -ne $Status) { continue }
        if ($ruleStatus -eq 'autoDisabled') { $autoDisabled++ }

        [PSCustomObject]@{
            PSTypeName       = 'MsecDefenderDetectionRule'
            Id               = [string] $rule.id
            DisplayName      = [string] $rule.displayName
            Description      = [string] $rule.description
            # 'enabled', 'disabled', or 'autoDisabled' - the last meaning Defender turned it
            # off because the query stopped working. $null only where the API returned neither
            # status nor the retired isEnabled, which is unknown rather than off.
            Status           = $ruleStatus
            IsRunning        = if ($null -eq $ruleStatus) { $null } else { $ruleStatus -eq 'enabled' }
            Frequency        = [string] $rule.schedule.frequency
            NextRun          = if ($rule.schedule.nextRunDateTime) { [datetime] $rule.schedule.nextRunDateTime } else { $null }
            # The alert this rule raises when it matches.
            AlertTitle       = [string] $rule.detectionAction.alertTemplate.title
            Severity         = [string] $rule.detectionAction.alertTemplate.severity
            Category         = [string] $rule.detectionAction.alertTemplate.category
            # The query is the rule. Kept whole so -Query can search it and so a reader can see
            # what is actually being watched without a second call.
            Query            = $queryText
            CreatedBy        = [string] $rule.createdBy
            CreatedUtc       = if ($rule.createdDateTime) { [datetime] $rule.createdDateTime } else { $null }
            LastModifiedBy   = [string] $rule.lastModifiedBy
            LastModifiedUtc  = if ($rule.lastModifiedDateTime) { [datetime] $rule.lastModifiedDateTime } else { $null }
            Raw              = $rule
        }
    }

    if ($autoDisabled) {
        Write-Warning "$autoDisabled custom detection rule(s) are AUTODISABLED - Defender switched them off because their query stopped working. They still appear in the portal's rule list and are not running. Filter on Status 'autoDisabled' to see them."
    }
}
