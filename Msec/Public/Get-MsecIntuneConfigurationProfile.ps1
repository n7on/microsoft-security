function Get-MsecIntuneConfigurationProfile {
    <#
    .SYNOPSIS
        Lists Intune configuration profiles - Settings Catalog policies and classic device
        configuration profiles - merged into one stream, with the full Graph object kept
        in a Raw column for audit / backup / diff.

    .DESCRIPTION
        Microsoft is migrating Intune configuration from the older "device configuration
        profiles" (Templates) model to the newer "Settings Catalog" model. The Intune
        portal under Devices > Configuration profiles shows both side by side, and most
        tenants have a mix.

        This function queries both Graph endpoints:
          - /beta/deviceManagement/configurationPolicies (Settings Catalog - new; still beta-only)
          - /v1.0/deviceManagement/deviceConfigurations  (classic templates - legacy; GA)

        and projects each entry to a uniform shape with a Source discriminator
        ('SettingsCatalog' or 'Templates') so the rows can be combined or filtered.

        Each row also carries:

          - Assignments: pulled via $expand in the same call - no extra round trip.
            AssignmentCount is how many; the rest say WHO, as separate typed columns so
            each can be filtered on its own:

            All of the collection columns are ARRAYS, not joined strings, so they can be
            tested exactly - `Where-Object AssignmentGroup -contains 'sg-pilot-ring'`. The
            default table renders them comma-separated via msec.format.ps1xml, so the
            display is flat while the data is not; a joined property would force
            -like '*sg-pilot-ring*' and match 'sg-pilot' too.

              AssignmentType          'AllUsers', 'AllDevices', 'Group',
                                      'ExclusionGroup', 'ConfigManagerCollection' -
                                      distinct, so three groups report 'Group' once
              AssignmentGroup         the INCLUDED group names (or ids)
              AssignmentExcludedGroup the EXCLUDED group names, kept apart because a
                                      carve-out changes what the policy means
              HasAssignmentFilter     true when a device filter narrows any assignment
              AssignmentDetail        one structured row per assignment

            The target type costs nothing extra - it is already on the expanded
            assignment. Group display NAMES are resolved by default, one cached Graph
            call per DISTINCT group; -NoGroupNameLookup skips that for a zero-extra-call
            sweep and reports group ids instead.

          - Status (optional, -IncludeStatus): per-policy check-in counts. Templates use
            /deviceStatusOverview (one call per policy); Settings Catalog uses the Intune
            Reports API exportJob (one job per tenant, ~5-15s, results cached in a
            hashtable for the per-policy loop).

          - Raw: the verbatim Graph object for the policy. For Templates this includes
            every configured setting inline (the Graph response is naturally deep). For
            Settings Catalog, Raw only contains the policy metadata unless you pass
            -IncludeSettings, which fetches /configurationPolicies/{id}/settings per
            policy and merges the result into Raw.settings.

        The Raw column replaces the old Export-MsecIntuneConfiguration function - JSON
        backup, change diffs, and audit drill-downs all work directly off Raw:

            # Backup all SC policies' full config as JSON files
            Get-MsecIntuneConfigurationProfile -Source SettingsCatalog -IncludeSettings |
                ForEach-Object {
                    $name = $_.DisplayName -replace '[\/:*?"<>|]', '_'
                    $_.Raw | ConvertTo-Json -Depth 20 | Set-Content "./intune/$name.json"
                }

        Required Graph permission: DeviceManagementConfiguration.Read.All (Application).

    .PARAMETER Source
        Restrict to one generation:
          - 'All'             (default) both endpoints
          - 'SettingsCatalog' only Settings Catalog policies
          - 'Templates'       only classic device configuration profiles

    .PARAMETER IncludeStatus
        Fetch the per-policy device check-in counts. Adds one extra Graph call per policy
        (the Settings Catalog call also paginates per device), so it can be noticeably
        slower on large tenants. Off by default.

    .PARAMETER IncludeSettings
        For Settings Catalog policies: fetch each policy's settings via
        /configurationPolicies/{id}/settings and merge them into Raw.settings. Adds one
        extra Graph call per SC policy. Off by default. Templates already include their
        settings inline in the list response - this switch is a no-op for them.

    .PARAMETER NoGroupNameLookup
        Report assignment groups by id instead of resolving their display names.

        Names are resolved by DEFAULT, because a GUID in an AssignmentGroup column is not
        an answer to "who is this aimed at" - it is the question again. The cost is one
        Graph call per DISTINCT group, cached for the run, which is what makes this
        different in kind from -IncludeStatus and -IncludeSettings: those scale with the
        number of policies, this scales with the (much smaller) number of groups Intune
        assignments actually use. A tenant with 200 policies sharing 12 groups pays 12
        calls, not 200.

        Resolution needs 'Group.Read.All', which New-MsecApp already grants. If it is
        missing, one warning is raised for the whole run and ids are used - so a missing
        permission degrades the names, never the target types.

        Use this switch when you want the inventory with provably no per-group calls, or
        to silence the lookup entirely on an app that cannot read groups. AssignmentType,
        AssignmentCount and HasAssignmentFilter are unaffected by it: those come from the
        expanded assignment and cost nothing either way.

        A group that no longer exists is reported as '<deleted group {id}>' rather than
        as a blank: a policy assigned only to a deleted group is deployed to nobody,
        which is a finding and not a gap in the output.

    .EXAMPLE
        # Standard inventory. Target types and named groups are in the default table.
        Get-MsecIntuneConfigurationProfile | Format-Table

    .EXAMPLE
        # Fastest possible sweep: two Graph calls total, no per-group lookups. Groups
        # come back as ids; the target TYPES are unaffected.
        Get-MsecIntuneConfigurationProfile -NoGroupNameLookup |
            Format-Table DisplayName, AssignmentType, AssignmentCount

    .EXAMPLE
        # Which policies are tenant-wide? These apply to everyone who enrols tomorrow.
        # An exact test on a typed column, not a match against a rendered phrase.
        Get-MsecIntuneConfigurationProfile |
            Where-Object { $_.AssignmentType -contains 'AllUsers' -or
                           $_.AssignmentType -contains 'AllDevices' }

    .EXAMPLE
        # Assigned to nobody - configured, reviewed, and doing nothing.
        Get-MsecIntuneConfigurationProfile | Where-Object AssignmentCount -eq 0

    .EXAMPLE
        # Tenant-wide but carved into by an exclusion. The riskiest thing to misread as
        # "applies to everyone", and the reason a count was never enough.
        Get-MsecIntuneConfigurationProfile |
            Where-Object { $_.AssignmentExcludedGroup } |
            Format-Table DisplayName, AssignmentType, AssignmentExcludedGroup

    .EXAMPLE
        # Every group that any profile is scoped to, and how many profiles each carries.
        Get-MsecIntuneConfigurationProfile |
            ForEach-Object { $_.AssignmentDetail } |
            Where-Object TargetType -in 'Group', 'ExclusionGroup' |
            Group-Object GroupName -NoElement | Sort-Object Count -Descending

    .EXAMPLE
        # Assignments narrowed by a device filter, where the stated target overstates
        # the real reach.
        Get-MsecIntuneConfigurationProfile |
            Where-Object HasAssignmentFilter |
            Select-Object DisplayName, AssignmentType, AssignmentGroup

    .EXAMPLE
        # Find policies failing on many devices
        Get-MsecIntuneConfigurationProfile -IncludeStatus |
            Where SuccessPercent -lt 95 |
            Sort SuccessPercent | Select DisplayName, SuccessPercent, ErrorCount

    .EXAMPLE
        # Audit drill-down: pull one specific SC policy's full settings
        $row = Get-MsecIntuneConfigurationProfile -IncludeSettings |
            Where Id -eq 'sc-1'
        $row.Raw | ConvertTo-Json -Depth 20

    .OUTPUTS
        PSCustomObject with PSTypeName 'MsecIntuneConfigurationProfile'. Default
        Format-Table view is: DisplayName, Source, Platform, AssignmentType,
        AssignmentGroup, Status
        (last column only present with -IncludeStatus). All other columns including
        Raw remain available via Select-Object / Format-List / direct property access.

        Status values (only present with -IncludeStatus):
          - NotDeployed   - AssignmentCount=0
          - NotReporting  - assigned but no devices currently evaluated
          - Healthy       - 100% success, no errors or conflicts
          - Degraded      - any errors / conflicts / pending or partial success
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('All', 'SettingsCatalog', 'Templates')]
        [string] $Source = 'All',

        [Parameter()]
        [switch] $IncludeStatus,

        [Parameter()]
        [switch] $IncludeSettings,

        [Parameter()]
        [switch] $NoGroupNameLookup
    )

    Assert-MsecSession

    # groupId -> display name, for AssignmentGroup / AssignmentExcludedGroup /
    # AssignmentDetail. On by default - an unresolved GUID in a group column is not an
    # answer - and skippable with -NoGroupNameLookup.
    #
    # Cached across the whole run rather than per policy, which is what keeps this
    # affordable enough to be the default: the call count is the number of DISTINCT
    # groups used by any assignment, not the number of policies. One group assigned to
    # thirty profiles is one lookup, not thirty.
    #
    # Deliberately one request per group rather than a batched /groups?$filter=id in (...):
    # a filtered list silently OMITS ids that no longer exist, so telling a deleted group
    # from an unreadable one would mean diffing the response against what was asked for.
    # Per-group lookups get that distinction from the 404 directly, and the cache already
    # bounds the count.
    $groupNameCache = @{}

    # A hashtable, not a bool: $resolveGroupNames is invoked with & and so runs in a child
    # scope, where assigning to an outer SCALAR silently creates a local instead - the flag
    # would reset on every policy and the auth warning would repeat per assigned group.
    # Same reason Get-MsecEntraRoleHolder keeps its counters in one.
    $groupLookup = @{ Denied = $false }

    $resolveGroupNames = {
        param($Assignments)

        foreach ($a in @($Assignments)) {
            $groupId = [string]$a.target.groupId
            if (-not $groupId -or $groupNameCache.ContainsKey($groupId)) { continue }
            if ($groupLookup.Denied) { continue }

            try {
                $g = Invoke-MsecGraphRequest -Path "/v1.0/groups/$groupId`?`$select=id,displayName"
                $groupNameCache[$groupId] = if ($g.displayName) { $g.displayName } else { $groupId }
            }
            catch {
                if ($_.Exception.Message -match '404|Not Found') {
                    # A profile assigned to a group that no longer exists is deployed to
                    # nobody, and that is a finding rather than a blank - so it is
                    # labelled, and cached so the dead id is not looked up again.
                    $groupNameCache[$groupId] = "<deleted group $groupId>"
                    continue
                }
                # An AUTH failure is not about this group - it will be true of every
                # subsequent one - so it is reported once and the lookup gives up. Naming
                # each group it then failed on would bury the actual output of a tenant
                # with hundreds of profiles under identical warnings.
                #
                # 401 and 403 are separated because the fixes are opposite: a token that
                # is not being accepted at all, versus a token that is fine and lacks a
                # scope. Sending someone through a consent cycle for the former wastes
                # their time and does not help.
                if ($_.Exception.Message -match '\b401\b|Unauthorized') {
                    $groupLookup.Denied = $true
                    Write-Warning "Cannot resolve assignment group names: Graph rejected the token (401) on /groups. Group targets are reported by id instead - AssignmentType, AssignmentCount and HasAssignmentFilter are unaffected. Try Disconnect-Msec then Connect-Msec to get a fresh token. Graph said: $($_.Exception.Message)"
                    continue
                }
                if ($_.Exception.Message -match '\b403\b|Forbidden') {
                    $groupLookup.Denied = $true
                    Write-Warning "Cannot resolve assignment group names: the msec app needs the 'Group.Read.All' application permission (admin consent required). Group targets are reported by id instead - the target TYPE in AssignmentType is unaffected. Re-run New-MsecApp to add and consent it, or pass -NoGroupNameLookup to skip the lookup."
                    continue
                }

                # Anything else IS per-group - a transient failure on one group says
                # nothing about the next - so it warns per group and carries on. Bounded
                # by the number of distinct groups, and each one names a different id.
                Write-Warning "Could not resolve assignment group '$groupId': $($_.Exception.Message)"
                $groupNameCache[$groupId] = $groupId
            }
        }
    }

    # If we'll need Settings Catalog status, pre-fetch the Reports API export *once* for
    # the whole tenant so the per-policy loop is just hashtable lookups.
    $scStatusCache = $null
    if ($IncludeStatus -and $Source -ne 'Templates') {
        Write-Verbose 'Pre-fetching Settings Catalog status (Intune Reports exportJob, ~5-15s)'
        $scStatusCache = Get-MsecSettingsCatalogStatusReport
    }

    # Local projection helper so both branches produce the same shape.
    # The Status / Success* / Error* / etc. columns only appear when -IncludeStatus is set.
    # Raw is always set to the (optionally settings-expanded) Graph object.
    $project = {
        param($id, $displayName, $description, $platform, $type, $sourceTag,
              $created, $modified, $assignments, $raw)
        $assignmentCount = @($assignments).Count

        if (-not $NoGroupNameLookup) { & $resolveGroupNames $assignments }
        $targets = ConvertTo-MsecAssignmentTarget $assignments -GroupName $groupNameCache

        $obj = [ordered]@{
            PSTypeName       = 'MsecIntuneConfigurationProfile'
            Id               = $id
            DisplayName      = $displayName
            Description      = $description
            Platform         = $platform
            Type             = $type
            Source           = $sourceTag
            AssignmentCount  = $assignmentCount

            # Who the policy is aimed at, as separate typed columns rather than one
            # rendered phrase - the kind of target and the group it points at are
            # different facts, and each is filterable on its own with -contains.
            # AssignmentCount cannot answer any of this: an 'All Users' assignment plus
            # an exclusion group is 2, and so is a pair of unrelated groups.
            AssignmentType   = $targets.Type

            # Included and excluded groups kept in separate columns. One list with a
            # parallel type column would leave the reader working out which name was the
            # carve-out, and the carve-out is the part that changes the meaning.
            AssignmentGroup         = $targets.Group
            AssignmentExcludedGroup = $targets.ExcludedGroup

            # An assignment filter re-evaluates the target at check-in, so a filtered
            # 'All Devices' is not all devices.
            HasAssignmentFilter     = $targets.HasFilter

            AssignmentDetail        = $targets.Detail
        }

        if ($IncludeStatus) {
            # Skip the per-policy status call when AssignmentCount=0 - the answer is
            # "all zeros / NotDeployed" regardless of what the API would return.
            $status = if ($assignmentCount -gt 0) {
                $statusArgs = @{ Id = $id; Source = $sourceTag }
                if ($scStatusCache) { $statusArgs['SettingsCatalogStatusCache'] = $scStatusCache }
                Get-MsecPolicyStatus @statusArgs
            }
            else { $null }

            # Status rollup label - see .OUTPUTS in the help for the meaning of each value.
            $obj.Status = if ($assignmentCount -eq 0) {
                'NotDeployed'
            }
            elseif ($null -eq $status.SuccessPercent) {
                'NotReporting'
            }
            elseif ($status.SuccessPercent -eq 100 -and $status.ErrorCount -eq 0 -and $status.ConflictCount -eq 0) {
                'Healthy'
            }
            else {
                'Degraded'
            }
        }

        $obj.CreatedDateTime      = if ($created)  { [datetime]$created }  else { $null }
        $obj.LastModifiedDateTime = if ($modified) { [datetime]$modified } else { $null }

        if ($IncludeStatus) {
            # NotDeployed and NotReporting both mean "no devices effectively reporting".
            # Zero across the board is the consistent answer in both cases.
            if ($obj.Status -in 'NotDeployed', 'NotReporting') {
                $obj.SuccessCount       = 0
                $obj.ErrorCount         = 0
                $obj.ConflictCount      = 0
                $obj.NotApplicableCount = 0
                $obj.PendingCount       = 0
                $obj.SuccessPercent     = 0
            }
            else {
                $obj.SuccessCount       = $status.SuccessCount
                $obj.ErrorCount         = $status.ErrorCount
                $obj.ConflictCount      = $status.ConflictCount
                $obj.NotApplicableCount = $status.NotApplicableCount
                $obj.PendingCount       = $status.PendingCount
                $obj.SuccessPercent     = $status.SuccessPercent
            }
        }

        # Raw - the full Graph object for the policy. Templates carry their settings
        # inline; Settings Catalog only does when -IncludeSettings was passed (in
        # which case the caller has already attached them as a 'settings' property).
        $obj.Raw = $raw

        [PSCustomObject]$obj
    }

    if ($Source -in 'All', 'SettingsCatalog') {
        Write-Verbose 'Loading Settings Catalog policies (/beta/deviceManagement/configurationPolicies)'
        # NB: configurationPolicies is still in beta only (Microsoft has not GA'd it to /v1.0).
        $scPath = '/beta/deviceManagement/configurationPolicies?$expand=assignments'
        foreach ($p in (Invoke-MsecGraphRequest -Path $scPath -All)) {
            if ($IncludeSettings) {
                # One extra call per SC policy - settings are not inline in the list
                # response. Attach them as a 'settings' property on the raw object so
                # Raw stays a single coherent shape rather than splitting policy/settings.
                $settingsResp = @(Invoke-MsecGraphRequest -Path "/beta/deviceManagement/configurationPolicies/$($p.id)/settings" -All)
                Add-Member -InputObject $p -NotePropertyName 'settings' -NotePropertyValue $settingsResp -Force
            }
            & $project $p.id $p.name $p.description $p.platforms 'Settings Catalog' 'SettingsCatalog' `
                $p.createdDateTime $p.lastModifiedDateTime $p.assignments $p
        }
    }

    if ($Source -in 'All', 'Templates') {
        Write-Verbose 'Loading classic device configurations (/v1.0/deviceManagement/deviceConfigurations)'
        $tPath = '/v1.0/deviceManagement/deviceConfigurations?$expand=assignments'
        foreach ($c in (Invoke-MsecGraphRequest -Path $tPath -All)) {
            $odataType = $c.'@odata.type'
            $typeShort = if ($odataType) { $odataType -replace '^#microsoft\.graph\.', '' } else { $null }

            # Classic configs don't expose a platform field directly; derive it from the type name.
            # 'switch -Wildcard' falls through to every matching case by default; the
            # 'break' on each case ensures the most-specific match wins (e.g. windows10*
            # before windows*).
            $platform = $null
            switch -Wildcard ($typeShort) {
                'windows10*'           { $platform = 'windows10';          break }
                'windows*'             { $platform = 'windows';            break }
                'macOS*'               { $platform = 'macOS';              break }
                'ios*'                 { $platform = 'iOS';                break }
                'androidWorkProfile*'  { $platform = 'androidWorkProfile'; break }
                'androidDeviceOwner*'  { $platform = 'androidDeviceOwner'; break }
                'androidForWork*'      { $platform = 'androidForWork';     break }
                'android*'             { $platform = 'android';            break }
            }

            & $project $c.id $c.displayName $c.description $platform $typeShort 'Templates' `
                $c.createdDateTime $c.lastModifiedDateTime $c.assignments $c
        }
    }
}
