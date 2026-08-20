function ConvertTo-MsecAssignmentTarget {
    <#
    .SYNOPSIS
        Turns an Intune policy's expanded assignments into filterable target columns plus
        one structured row per assignment.

    .DESCRIPTION
        Answers "who is this actually aimed at" - All Users, All Devices, a group, or some
        combination - from the assignments already expanded onto the policy. No Graph call
        of its own: the target TYPE is carried in each assignment's target.'@odata.type',
        so the whole question is answerable from data the caller already has. Only group
        display NAMES need a lookup, and those are passed in.

        SEPARATE, TYPED COLUMNS rather than one summary line. The kind of target and the
        group it points at are different facts, and a caller wants to filter on them
        independently - `Where-Object AssignmentType -contains 'AllUsers'` is an exact
        test, where matching a rendered phrase would be string-matching a display value.
        This module has been bitten by that often enough (see the Global Administrator /
        'Company Administrator' naming trap) that no column here is a sentence.

        EXCLUSIONS ARE TARGETS TOO, and this is why a count was never enough. Intune
        models "everyone except the pilot ring" as an allLicensedUsers target plus an
        exclusionGroup target - two assignments. A policy reported as "2 assignments" is
        then indistinguishable from one aimed at two unrelated groups. Excluded groups get
        their own TargetType AND their own column, kept apart from included ones: two
        parallel name lists would leave the reader guessing which name was the carve-out.

        ASSIGNMENT FILTERS narrow a target further, on device properties evaluated at
        check-in, and are likewise invisible in a count. An 'All Devices' assignment
        carrying an include filter is not all devices. HasFilter flags any such
        assignment; FilterType and FilterId on the detail rows carry the specifics. Filter
        names are not resolved - a separate endpoint and permission - and the presence of
        a filter is what changes how the row reads.

    .PARAMETER Assignment
        The policy's expanded assignments collection. $null or empty is fine, and yields
        empty columns rather than $null ones.

    .PARAMETER GroupName
        Optional hashtable of groupId -> display name. Ids with no entry keep their id as
        the name, so a target is never nameless.

    .OUTPUTS
        PSCustomObject with:
          Type          - string[], distinct target types in a fixed order
          Group         - string[], INCLUDED group names (or ids)
          ExcludedGroup - string[], EXCLUDED group names (or ids)
          HasFilter     - bool, any assignment narrowed by an assignment filter
          Detail        - one PSCustomObject per assignment: TargetType, IsExclusion,
                          GroupId, GroupName, FilterType, FilterId, Raw

        Every collection is an array, empty rather than $null, so -contains and .Count
        work on an unassigned policy without a null check at each call site.

    .NOTES
        TargetType values, mapped from target.'@odata.type':
          allLicensedUsersAssignmentTarget    -> AllUsers
          allDevicesAssignmentTarget          -> AllDevices
          groupAssignmentTarget               -> Group
          exclusionGroupAssignmentTarget      -> ExclusionGroup
          configurationManagerCollectionAssignmentTarget -> ConfigManagerCollection

        A target carrying an '@odata.type' msec does not recognise keeps that type with
        the '#microsoft.graph.' prefix stripped, rather than being flattened to 'Unknown':
        Intune has added target types before, and a name you can look up beats a label
        that hides one. 'Unknown' is used only when there is no '@odata.type' at all -
        where it is the accurate description rather than a shrug.

        Type is DISTINCT, so a policy aimed at three groups reports 'Group' once; the
        multiplicity lives in Group.Count and AssignmentCount. Its order is fixed - All
        Users, All Devices, groups, exclusions, collections, then anything else - so the
        same set of assignments always projects the same way and two policies can be
        compared without sorting first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        $Assignment,

        [Parameter()]
        [hashtable] $GroupName
    )

    $detail = [System.Collections.Generic.List[object]]::new()

    foreach ($a in @($Assignment)) {
        if (-not $a) { continue }

        $target = $a.target
        $odata  = if ($target) { [string]$target.'@odata.type' } else { '' }
        $short  = $odata -replace '^#?microsoft\.graph\.', ''

        $type = switch ($short) {
            'allLicensedUsersAssignmentTarget'              { 'AllUsers' }
            'allDevicesAssignmentTarget'                     { 'AllDevices' }
            'groupAssignmentTarget'                          { 'Group' }
            'exclusionGroupAssignmentTarget'                 { 'ExclusionGroup' }
            'configurationManagerCollectionAssignmentTarget' { 'ConfigManagerCollection' }
            default { if ($short) { $short } else { 'Unknown' } }
        }

        $groupId = if ($target) { [string]$target.groupId } else { $null }

        # 'none' and $null both mean unfiltered; normalised so callers test one thing.
        $filterType = if ($target) { [string]$target.deviceAndAppManagementAssignmentFilterType } else { $null }
        if (-not $filterType -or $filterType -eq 'none') { $filterType = $null }

        $detail.Add([PSCustomObject]@{
            TargetType  = $type
            IsExclusion = ($type -eq 'ExclusionGroup')
            GroupId     = if ($groupId) { $groupId } else { $null }
            GroupName   = if (-not $groupId) { $null }
                          elseif ($GroupName -and $GroupName.ContainsKey($groupId)) { $GroupName[$groupId] }
                          else { $groupId }
            FilterType  = $filterType
            FilterId    = if ($target -and $target.deviceAndAppManagementAssignmentFilterId) {
                              [string]$target.deviceAndAppManagementAssignmentFilterId
                          } else { $null }
            Raw         = $a
        })
    }

    # Fixed order, so the projection is stable and two policies are comparable without
    # sorting. Anything msec does not know about trails the known kinds, alphabetically.
    $rank = @{ 'AllUsers' = 0; 'AllDevices' = 1; 'Group' = 2; 'ExclusionGroup' = 3; 'ConfigManagerCollection' = 4 }
    $types = @(
        $detail.TargetType | Sort-Object -Unique |
            Sort-Object @{ Expression = { if ($rank.ContainsKey($_)) { $rank[$_] } else { 99 } } }, @{ Expression = { $_ } }
    )

    [PSCustomObject]@{
        Type          = $types
        Group         = @($detail | Where-Object TargetType -eq 'Group'          | ForEach-Object { $_.GroupName })
        ExcludedGroup = @($detail | Where-Object TargetType -eq 'ExclusionGroup' | ForEach-Object { $_.GroupName })
        HasFilter     = [bool] @($detail | Where-Object FilterType).Count
        Detail        = $detail.ToArray()
    }
}
