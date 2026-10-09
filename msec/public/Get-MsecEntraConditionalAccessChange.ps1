function Get-MsecEntraConditionalAccessChange {
    <#
    .SYNOPSIS
        Changes to Conditional Access policies - who altered what, when - with the before and
        after values of each setting that actually moved.

    .DESCRIPTION
        Entra records a CA change as a single audit property called 'ConditionalAccessPolicy'
        whose old and new values are the ENTIRE POLICY as a JSON string. Read raw that is two
        multi-kilobyte blobs and no answer. This parses both and reports only the fields that
        differ, so "MFA was removed from policy X" is a row rather than an exercise.

        MODIFIEDDATETIME IS EXCLUDED FROM THE DIFF because it changes on every edit by
        definition. Left in, every single change carries a meaningless entry and the real one is
        harder to see. Same for the policy id and createdDateTime, which cannot change at all.

        STATE IS CALLED OUT SEPARATELY. A policy moving enabled -> disabled or -> enabledForReportingButNotEnforced
        is the highest-signal CA change there is, and it is one field inside a large object.
        StateBefore and StateAfter are columns so it can be filtered without reading diffs.

        AN APP CAN CHANGE CONDITIONAL ACCESS, AND OFTEN DOES. Measured on one tenant, 11 of 15
        changes came from a Microsoft365DSC orchestrator service principal and only 4 from
        people. Actor therefore falls back from user principal name to application display
        name - taking only the user would report the majority of changes as having no author.

        THE AUDIT WINDOW IS 30 DAYS ON ENTRA ID P1/P2 AND 7 ON THE FREE TIER, and that ceiling
        cannot be raised by asking. A policy altered before it shows no change here at all. The
        window actually returned is reported on the verbose stream, and
        Get-MsecEntraConditionalAccessPolicy's ModifiedDateTime persists indefinitely - so a
        policy whose ModifiedDateTime predates this window was changed by someone whose identity
        is simply gone. Compare the two rather than reading silence as stability.

    .PARAMETER Days
        How far back to search. Default 30, the P1/P2 ceiling. Drop to 7 on a free tenant.

    .PARAMETER PolicyName
        Substring match on the policy name, case-insensitive.

    .PARAMETER Actor
        Substring match on who made the change - user principal name or application name.

    .PARAMETER IncludeUnchanged
        Keep rows where nothing but the excluded noise fields moved. Off by default: an edit
        that changed nothing of substance is not a change anyone needs to read.

    .EXAMPLE
        Get-MsecEntraConditionalAccessChange

        Every Conditional Access change in the retention window.

    .EXAMPLE
        Get-MsecEntraConditionalAccessChange | Where-Object { $_.StateAfter -eq 'disabled' }

        Policies that were switched off. The change most worth knowing about.

    .EXAMPLE
        Get-MsecEntraConditionalAccessChange |
            Where-Object { $_.ChangedProperties -match 'grantControls' } |
            Select-Object ActivityDateTime, PolicyName, Actor, ChangedProperties

        Changes that touched what a policy actually enforces, as opposed to its name or scope.

    .EXAMPLE
        # Policies altered outside the audit window - changed, but by whom is unrecoverable.
        $changed = (Get-MsecEntraConditionalAccessChange).PolicyId
        Get-MsecEntraConditionalAccessPolicy |
            Where-Object { $_.Id -notin $changed -and $_.ModifiedDateTime -gt $_.CreatedDateTime }

    .OUTPUTS
        PSCustomObject per change, PSTypeName 'MsecEntraConditionalAccessChange'.

    .NOTES
        Needs 'AuditLog.Read.All', which New-MsecApp already grants, plus Entra ID P1/P2 for a
        directory audit log at all.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateRange(1, 30)]
        [int] $Days = 30,

        [string] $PolicyName,

        [string] $Actor,

        [switch] $IncludeUnchanged
    )

    Assert-MsecSession

    $since = (Get-Date).ToUniversalTime().AddDays(-$Days).ToString('yyyy-MM-ddTHH:mm:ssZ')
    # Filtered server-side on category and time. activityDisplayName is NOT filtered here:
    # Graph rejects some string operators on it, and the set of CA activity names ('Add
    # conditional access policy', 'Update...', 'Delete...') is small enough to match locally.
    $filter = "category eq 'Policy' and activityDateTime ge $since"
    $path = "/v1.0/auditLogs/directoryAudits?`$filter=$([uri]::EscapeDataString($filter))&`$top=999"

    try {
        $events = @(Invoke-MsecGraphRequest -Path $path -All)
    }
    catch {
        $message = "$($_.Exception.Message)"
        if ($message -match '403|Forbidden') {
            throw "Forbidden reading the directory audit log. The msec app needs 'AuditLog.Read.All', which New-MsecApp grants. Note this also requires Entra ID P1 or P2 on the tenant - a free tenant has no directory audit log to read. Original error: $message"
        }
        throw
    }

    $ca = @($events | Where-Object { "$($_.activityDisplayName)" -match 'conditional access policy' })

    if (-not $ca.Count) {
        Write-Warning "No Conditional Access changes found in the last $Days day(s). This is NOT evidence that the policies are unchanged: the directory audit log retains 30 days on Entra ID P1/P2 and 7 on the free tier, so an older change is simply gone. Compare ModifiedDateTime from Get-MsecEntraConditionalAccessPolicy, which persists."
        return
    }

    $seen = @($events | ForEach-Object { if ($_.activityDateTime) { [datetime]$_.activityDateTime } }) | Sort-Object
    if ($seen.Count) {
        Write-Verbose "Asked for $Days day(s); audit log returned $($events.Count) policy event(s) from $($seen[0].ToString('u')) to $($seen[-1].ToString('u')), of which $($ca.Count) are Conditional Access."
    }

    # Fields that move on every edit or cannot move at all. Diffing them buries the real change.
    $noise = @('modifiedDateTime', 'createdDateTime', 'id')

    function ConvertTo-FlatMap {
        param($Node, [string] $Prefix = '')
        $map = @{}
        if ($null -eq $Node) { return $map }
        if ($Node -is [System.Collections.IDictionary] -or $Node -is [psobject] -and $Node -isnot [string] -and $Node -isnot [ValueType]) {
            $props = if ($Node -is [System.Collections.IDictionary]) { $Node.Keys } else { $Node.PSObject.Properties.Name }
            foreach ($k in $props) {
                $v = if ($Node -is [System.Collections.IDictionary]) { $Node[$k] } else { $Node.$k }
                $p = if ($Prefix) { "$Prefix.$k" } else { "$k" }
                # An array is compared whole: a reordered list of excluded groups is not a
                # change worth reporting as ten.
                if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
                    $map[$p] = ($v | ConvertTo-Json -Depth 10 -Compress)
                }
                elseif ($null -ne $v -and ($v -is [psobject]) -and $v -isnot [ValueType] -and $v -isnot [string]) {
                    foreach ($e in (ConvertTo-FlatMap -Node $v -Prefix $p).GetEnumerator()) { $map[$e.Key] = $e.Value }
                }
                else { $map[$p] = $v }
            }
        }
        else { $map[$Prefix] = $Node }
        $map
    }

    foreach ($e in ($ca | Sort-Object { [datetime]$_.activityDateTime } -Descending)) {
        # A change made by a service principal has no user at all - taking only the user would
        # report most changes on an automated tenant as authorless.
        $actorName = @(
            $e.initiatedBy.user.userPrincipalName
            $e.initiatedBy.user.displayName
            $e.initiatedBy.app.displayName
            $e.initiatedBy.app.servicePrincipalName
        ) | Where-Object { $_ } | Select-Object -First 1
        $actorType = if ($e.initiatedBy.user.userPrincipalName -or $e.initiatedBy.user.displayName) { 'User' }
                     elseif ($e.initiatedBy.app.displayName) { 'Application' } else { $null }

        if ($Actor -and "$actorName" -notmatch [regex]::Escape($Actor)) { continue }

        foreach ($target in @($e.targetResources)) {
            $name = [string] $target.displayName
            if ($PolicyName -and $name -notmatch [regex]::Escape($PolicyName)) { continue }

            $changed = [System.Collections.Generic.List[string]]::new()
            $stateBefore = $null; $stateAfter = $null

            foreach ($mp in @($target.modifiedProperties)) {
                if ("$($mp.displayName)" -ne 'ConditionalAccessPolicy') {
                    # Any other property is reported verbatim rather than dropped.
                    if ("$($mp.oldValue)" -ne "$($mp.newValue)") {
                        $changed.Add("$($mp.displayName): $(if ("$($mp.oldValue)") { $mp.oldValue } else { '(none)' }) -> $(if ("$($mp.newValue)") { $mp.newValue } else { '(none)' })")
                    }
                    continue
                }

                $old = $null; $new = $null
                try { if ("$($mp.oldValue)".Trim()) { $old = $mp.oldValue | ConvertFrom-Json -ErrorAction Stop } } catch { }
                try { if ("$($mp.newValue)".Trim()) { $new = $mp.newValue | ConvertFrom-Json -ErrorAction Stop } } catch { }

                $stateBefore = [string] $old.state
                $stateAfter  = [string] $new.state

                $fo = ConvertTo-FlatMap -Node $old
                $fn = ConvertTo-FlatMap -Node $new
                foreach ($key in (@($fo.Keys) + @($fn.Keys) | Sort-Object -Unique)) {
                    if ($noise -contains ($key -split '\.')[-1]) { continue }
                    $a = $fo[$key]; $b = $fn[$key]
                    if ("$a" -eq "$b") { continue }
                    $as = if ($null -eq $a -or "$a" -eq '') { '(none)' } else { "$a" }
                    $bs = if ($null -eq $b -or "$b" -eq '') { '(none)' } else { "$b" }
                    $changed.Add("${key}: $as -> $bs")
                }
            }

            if (-not $IncludeUnchanged -and -not $changed.Count) { continue }

            [PSCustomObject]@{
                PSTypeName        = 'MsecEntraConditionalAccessChange'
                ActivityDateTime  = if ($e.activityDateTime) { [datetime]$e.activityDateTime } else { $null }
                Activity          = [string] $e.activityDisplayName
                PolicyName        = $name
                PolicyId          = [string] $target.id
                Actor             = $actorName
                ActorType         = $actorType
                Result            = [string] $e.result
                # The highest-signal field in a CA change, lifted out of the diff.
                StateBefore       = $stateBefore
                StateAfter        = $stateAfter
                StateChanged      = ($stateBefore -and $stateAfter -and $stateBefore -ne $stateAfter)
                ChangedProperties = $changed.ToArray()
                ChangedCount      = $changed.Count
                CorrelationId     = [string] $e.correlationId
                Raw               = $e
            }
        }
    }
}
