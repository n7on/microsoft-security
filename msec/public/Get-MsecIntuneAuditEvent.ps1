function Get-MsecIntuneAuditEvent {
    <#
    .SYNOPSIS
        The Intune audit log - who changed which policy, when, and what the setting was
        before and after. Retains far longer than the Entra audit log, and is the only
        durable record of a configuration change that was later rolled back.

    .DESCRIPTION
        Reads /deviceManagement/auditEvents. One row per change, with the before and after
        values of each property that moved.

        THIS IS A DIFFERENT STORE FROM THE ENTRA AUDIT LOG, WITH A DIFFERENT RETENTION. The
        Entra directory audit log keeps 30 days on P1/P2 and 7 on the free tier, and
        Get-MsecEntraDisabledUser is built around that ceiling. Intune keeps its own audit
        separately and for much longer, so a policy change that is long gone from Entra is
        usually still here. Nothing in the endpoint path hints at this: both are "the audit
        log" in conversation, and reaching for the wrong one returns an empty result rather
        than an error.

        THE PERMISSION IS THE LEAST GUESSABLE IN THE MODULE. This endpoint is gated by
        DeviceManagementApps.Read.All - the Intune APPS scope. It is NOT covered by
        DeviceManagementConfiguration.Read.All, which reads the very policies whose changes
        are logged here, nor by DeviceManagementManagedDevices.Read.All, nor by
        AuditLog.Read.All, which is Entra's. Without it the endpoint returns a bare 403 that
        names nothing, so the 403 is caught and rewritten.

        THE WINDOW ACTUALLY RETURNED IS REPORTED, NOT ASSUMED. Microsoft does not state the
        retention on the API reference, and it is not worth guessing in a module anyone can
        run against any tenant. So -Days sets what is ASKED FOR, and the verbose stream
        reports the oldest event that actually came back. If you ask for 365 days and the
        oldest row is 200 days old, that is the real floor of what this tenant can tell you,
        and it is a different answer from "nothing happened before then".

        AN EMPTY RESULT IS WARNED ABOUT, NEVER RETURNED SILENTLY. "No changes in the window"
        and "the window does not reach back far enough" look identical in an empty array, and
        the second one is the answer that matters when you are trying to date a change that
        somebody rolled back.

        A FILTER THAT MATCHES NOTHING SAYS WHAT WAS THERE INSTEAD. Resource names are whatever
        somebody typed into Intune, so a reasonable-looking -Resource finds nothing and reads
        as "that policy was never touched". Measured: searching a real tenant for 'Attack
        Surface' returned zero against 2,798 events, because the policy is called 'Block use of
        copied or impersonated system tools'. When a filter eliminates every row, the values
        actually present are named on the warning stream rather than left to be guessed.

        ACTIVITY FALLS BACK TO DISPLAYNAME. Graph returns the `activity` property EMPTY on every
        row of some tenants - measured 2,798 of 2,798 - while `displayName` carries the verb
        ('Create device configuration 2.0 (beta)'). Activity is therefore the first of the two
        that is non-empty, so the column is never blank when the information exists.

        CHANGEDPROPERTIES IS THE POINT. An audit event names the policy that was touched;
        ChangedProperties names the settings inside it and carries old -> new for each. That
        is what tells an ASR rule moving from Audit to Block apart from someone renaming the
        policy. It is a string[] so it can be searched with -match without parsing a blob,
        and the structured originals stay in Raw.

    .PARAMETER Days
        How far back to ask for, counted from now. Default 30. This sets the REQUEST, not
        the retention - see the description. Use -Verbose to see what actually came back.

    .PARAMETER Category
        Only events in this category, for example 'DeviceConfiguration', 'Enrollment',
        'Compliance', 'Application'. Completed from the categories this tenant has actually
        produced rather than a fixed list, because the set is not documented and differs
        between tenants.

    .PARAMETER Activity
        Substring match on the activity and its display name, case-insensitive. 'Patch' finds
        every update; 'Delete' every removal.

    .PARAMETER Resource
        Substring match on the name of the thing that was changed - the policy, profile or
        app. This is usually how you find a specific policy's history.

    .PARAMETER ResourceType
        Only events against this kind of thing - 'DeviceManagementConfigurationPolicy' for
        Settings Catalog and endpoint security policies, 'ManagedDevice', 'MobileApp' and so on.
        Completed from the types Intune actually emits. Unlike -Resource, these are Microsoft's
        own type names rather than whatever a policy was called, so they are stable to filter on.

    .PARAMETER Actor
        Substring match on who did it: user principal name, application display name, or
        service principal name. Covers changes made by an app as well as by a person.

    .PARAMETER FailedOnly
        Only events whose activityResult is not a success. A failed change attempt is its own
        signal - somebody tried and lacked the rights.

    .EXAMPLE
        Get-MsecIntuneAuditEvent -Days 365 -Resource 'Attack Surface' -Verbose

        Every change to an ASR policy in the last year, with the window actually available
        reported on the verbose stream. This is the query that dates a rule that was enabled
        and later rolled back.

    .EXAMPLE
        Get-MsecIntuneAuditEvent -Days 365 |
            Where-Object { $_.ChangedProperties -match 'Block|Audit|Warn' } |
            Select-Object ActivityDateTime, Actor, Resource, ChangedProperties

        Changes that moved an enforcement mode, whichever policy they were in.

    .EXAMPLE
        Get-MsecIntuneAuditEvent -Days 90 | Group-Object Actor | Sort-Object Count -Descending

        Who is changing Intune. A service principal near the top is worth knowing about.

    .EXAMPLE
        Get-MsecIntuneAuditEvent -Days 365 -ResourceType DeviceManagementConfigurationPolicy |
            Group-Object { $_.Resource } | Sort-Object Count -Descending

        Every policy touched in the year, busiest first. Run this BEFORE guessing at -Resource:
        the names are whatever somebody typed, and a policy enforcing an ASR rule is as likely
        to be called 'Block use of copied or impersonated system tools' as anything with 'ASR'
        in it.

    .EXAMPLE
        Get-MsecIntuneAuditEvent -Days 90 -FailedOnly

        Attempted changes that did not succeed.

    .OUTPUTS
        PSCustomObject per audit event, PSTypeName 'MsecIntuneAuditEvent'.

    .NOTES
        Needs the 'DeviceManagementApps.Read.All' application permission, which New-MsecApp
        grants. An app created before that was added must re-run New-MsecApp.

        Also needs an active Intune licence on the tenant - the Graph API for Intune returns
        an error rather than an empty list without one.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateRange(1, 3650)]
        [int] $Days = 30,

        # Deliberately an ArgumentCompleter and not a ValidateSet. The category list is not
        # documented, tenants produce different sets, and a ValidateSet would reject a real
        # value this tenant returns - the same mistake that would have made 'AlternateMitigation'
        # unreachable in Get-MsecSecureScoreRecommendation.
        [ArgumentCompleter({
            param($c, $p, $wordToComplete)
            @('Application', 'Compliance', 'Device', 'DeviceConfiguration', 'DeviceIntent',
              'Enrollment', 'Other', 'Role', 'RoleBasedAccessControl') |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
        })]
        [string] $Category,

        [string] $Activity,

        [string] $Resource,

        # Microsoft's own type names, so unlike -Resource these are stable across tenants.
        # An ArgumentCompleter rather than a ValidateSet for the same reason as -Category:
        # Intune emits types that are not in any published list, and rejecting a real one
        # would be worse than completing an incomplete set.
        [ArgumentCompleter({
            param($c, $p, $wordToComplete)
            @('DeviceManagementConfigurationPolicy', 'DeviceManagementConfigurationPolicyAssignment',
              'DeviceConfiguration', 'DeviceConfigurationAssignment', 'DeviceManagementIntent',
              'ManagedDevice', 'MobileApp', 'MobileAppAssignment', 'Win32LobApp',
              'Windows10CompliancePolicy', 'MacOSCompliancePolicy',
              'WindowsUpdateForBusinessConfiguration', 'DeviceHealthScript',
              'DeviceManagementScript', 'DepOnboardingSetting', 'RoleDefinition') |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
        })]
        [string] $ResourceType,

        [string] $Actor,

        [switch] $FailedOnly
    )

    Assert-MsecSession

    $since = (Get-Date).ToUniversalTime().AddDays(-$Days)
    # Graph wants an unquoted ISO 8601 literal here. 'o' round-trip format is what it accepts;
    # a locale-formatted string 400s with a filter-parse error that does not name the date.
    $filter = "activityDateTime ge $($since.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    $path = "/v1.0/deviceManagement/auditEvents?`$filter=$([uri]::EscapeDataString($filter))&`$top=1000"

    try {
        $events = @(Invoke-MsecGraphRequest -Path $path -All)
    }
    catch {
        $message = "$($_.Exception.Message)"
        if ($message -match '403|Forbidden') {
            throw "Forbidden when calling /deviceManagement/auditEvents. This endpoint is gated by the 'DeviceManagementApps.Read.All' application permission - the Intune APPS scope, which is NOT implied by DeviceManagementConfiguration.Read.All, DeviceManagementManagedDevices.Read.All or AuditLog.Read.All. Re-run New-MsecApp to add and consent it, then Disconnect-Msec / Connect-Msec. Original error: $message"
        }
        if ($message -match 'Intune|license|licence') {
            throw "The Intune Graph API rejected the call, which usually means the tenant has no active Intune licence rather than that there are no audit events. Original error: $message"
        }
        throw
    }

    if (-not $events.Count) {
        Write-Warning "No Intune audit events returned for the last $Days day(s). This is NOT the same as 'nothing was changed' - it is also what an out-of-retention window looks like. Try a larger -Days to find where this tenant's audit history actually starts."
        return
    }

    # Report the window that actually came back. Asking for 365 days and receiving 200 is the
    # real floor of what this tenant can answer, and it is not visible in the rows themselves.
    $dates = @($events | ForEach-Object { if ($_.activityDateTime) { [datetime]$_.activityDateTime } }) | Sort-Object
    if ($dates.Count) {
        $oldestDays = [math]::Round(((Get-Date).ToUniversalTime() - $dates[0].ToUniversalTime()).TotalDays, 1)
        Write-Verbose "Asked for $Days day(s); $($events.Count) event(s) returned, oldest $($dates[0].ToString('u')) ($oldestDays days ago), newest $($dates[-1].ToString('u'))."
        if ($oldestDays -lt ($Days * 0.9)) {
            Write-Verbose "The oldest event is well inside the requested window, so either nothing older was changed or this tenant's audit history does not reach back $Days days. The two are indistinguishable from here."
        }
    }

    $emitted = 0
    $rows = foreach ($e in $events) {
        if ($Category -and "$($e.category)" -ne $Category) { continue }
        if ($Activity -and "$($e.activity) $($e.displayName)" -notmatch [regex]::Escape($Activity)) { continue }

        # An actor is a person OR an application OR a service principal, and which fields are
        # populated depends on how the change was made. A change made by a script through an
        # app registration has no userPrincipalName at all, so taking only that field would
        # report the most interesting changes as having no author.
        $actorName = @(
            $e.actor.userPrincipalName
            $e.actor.servicePrincipalName
            $e.actor.applicationDisplayName
        ) | Where-Object { $_ } | Select-Object -First 1
        if (-not $actorName) { $actorName = $null }

        if ($Actor -and ("$actorName" -notmatch [regex]::Escape($Actor))) { continue }

        $resources = @($e.resources | ForEach-Object { $_.displayName } | Where-Object { $_ })
        $resourceTypes = @($e.resources | ForEach-Object { $_.auditResourceType } | Where-Object { $_ })
        if ($Resource) {
            $resourceText = ($resources -join ' ') + ' ' + (@($e.resources | ForEach-Object { $_.type }) -join ' ')
            if ($resourceText -notmatch [regex]::Escape($Resource)) { continue }
        }
        if ($ResourceType -and ($resourceTypes -notcontains $ResourceType)) { continue }

        # activityResult is free text, not an enum - 'Success', 'Succeeded' and failure strings
        # all appear. Tested for success rather than for failure so an unfamiliar value counts
        # as a failure and gets looked at, instead of being quietly filtered out.
        $succeeded = "$($e.activityResult)" -match '^succe'
        if ($FailedOnly -and $succeeded) { continue }

        $changed = @(
            foreach ($r in $e.resources) {
                foreach ($mp in $r.modifiedProperties) {
                    $old = if ($null -ne $mp.oldValue -and "$($mp.oldValue)" -ne '') { "$($mp.oldValue)" } else { '(none)' }
                    $new = if ($null -ne $mp.newValue -and "$($mp.newValue)" -ne '') { "$($mp.newValue)" } else { '(none)' }
                    "$($mp.displayName): $old -> $new"
                }
            }
        )

        [PSCustomObject]@{
            PSTypeName       = 'MsecIntuneAuditEvent'
            Id               = [string] $e.id
            ActivityDateTime = if ($e.activityDateTime) { [datetime]$e.activityDateTime } else { $null }
            # Graph returns `activity` EMPTY on every row of some tenants while `displayName`
            # carries the verb, so this is the first of the two that has anything in it. A
            # blank column here would read as an event with no action.
            Activity         = $(if ("$($e.activity)") { [string] $e.activity } else { [string] $e.displayName })
            DisplayName      = [string] $e.displayName
            Category         = [string] $e.category
            ComponentName    = [string] $e.componentName
            OperationType    = [string] $e.activityOperationType
            ActivityType     = [string] $e.activityType
            Result           = [string] $e.activityResult
            Succeeded        = $succeeded
            Actor            = $actorName
            ActorType        = [string] $e.actor.auditActorType
            ActorIpAddress   = [string] $e.actor.ipAddress
            ActorAppId       = [string] $e.actor.applicationId
            # The things that were changed. Usually one; a bulk edit can name several.
            Resource         = $resources
            ResourceType     = $resourceTypes
            ResourceId       = @($e.resources | ForEach-Object { $_.resourceId } | Where-Object { $_ })
            # 'Setting: old -> new' per property that moved. The reason this command exists.
            ChangedProperties = $changed
            ChangedCount     = $changed.Count
            CorrelationId    = [string] $e.correlationId
            Raw              = $e
        }
        $emitted++
    }

    $rows

    # A FILTER THAT ELIMINATES EVERYTHING IS NOT THE SAME ANSWER AS AN EMPTY AUDIT LOG, and the
    # two are the same empty array to the caller. Resource names in particular are whatever
    # somebody typed into Intune, so a sensible-looking guess finds nothing and reads as "that
    # was never changed". Naming what is actually present turns a dead end into the next query.
    if ($emitted -eq 0) {
        $present = @(
            if ($Resource -or $ResourceType) {
                # Ranked by how often each was touched, NOT alphabetically. Sorted by name, a
                # tenant's list opens with auto-generated GUID-and-timestamp resource names and
                # the policy the reader is looking for is 300 entries down - which is a longer
                # way of saying nothing. Busiest first puts the real policies at the top.
                $flat = @($events | ForEach-Object { $_.resources })
                if ($ResourceType) { $flat = @($flat | Where-Object { $_.auditResourceType -eq $ResourceType }) }
                $types = @($events | ForEach-Object { $_.resources } | Where-Object { $_.auditResourceType } |
                           Group-Object { $_.auditResourceType } | Sort-Object Count -Descending)
                $names = @($flat | Where-Object { $_.displayName } | Group-Object { $_.displayName } |
                           Sort-Object Count -Descending)
                if (-not $ResourceType -and $types) {
                    "ResourceType values present (busiest first): $((($types | Select-Object -First 10).Name) -join ', ')$(if ($types.Count -gt 10) { " (+$($types.Count - 10) more)" })"
                }
                if ($names) {
                    $scope = if ($ResourceType) { "Resource names of type '$ResourceType'" } else { 'Resource names' }
                    "$scope (busiest first): $((($names | Select-Object -First 10).Name) -join '; ')$(if ($names.Count -gt 10) { " (+$($names.Count - 10) more)" })"
                }
                elseif ($ResourceType) { "No resource of type '$ResourceType' appears in the window at all - check the spelling against the ResourceType list." }
            }
            if ($Category) {
                $cats = @($events | ForEach-Object { $_.category } | Where-Object { $_ } | Sort-Object -Unique)
                if ($cats) { "Category values present: $($cats -join ', ')" }
            }
        )
        Write-Warning ("$($events.Count) audit event(s) were returned for the last $Days day(s), but no row matched the filters, so this is a FILTER miss and NOT an empty audit log. " + ($present -join ' | '))
    }
}
