#Requires -Module Pester
#
# Tests for the Intune assignment-target projection. The cases that matter are the ones a
# count cannot express and a naive projection would misreport: an exclusion carved out of a
# tenant-wide assignment, and a filter narrowing one. Both make a policy apply to fewer
# people than its headline target claims, and both used to be invisible.
#
# Every column here is typed rather than a rendered phrase, so the assertions are on exact
# values - which is the property that lets callers use -contains instead of -match.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    # Builds one assignment the way Graph expands it onto a policy. Passed to
    # InModuleScope as TEXT and rebuilt there: a scriptblock stays bound to the session
    # state it was written in, and would not resolve the module's private functions.
    $script:MakeText = @'
$script:MkTarget = {
    param([string] $Type, [string] $GroupId, [string] $FilterType)
    $t = @{ '@odata.type' = "#microsoft.graph.$Type" }
    if ($GroupId)    { $t['groupId'] = $GroupId }
    if ($FilterType) {
        $t['deviceAndAppManagementAssignmentFilterType'] = $FilterType
        $t['deviceAndAppManagementAssignmentFilterId']   = 'flt-1'
    }
    [pscustomobject]@{ id = "as-$Type-$GroupId"; target = [pscustomobject]$t }
}
'@
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-MsecAssignmentTarget' {

    It 'returns empty arrays, not $null, for an unassigned policy' {
        # So a caller can pipe straight into -contains or .Count without a null check.
        $r = InModuleScope msec { ConvertTo-MsecAssignmentTarget @() }

        @($r.Type).Count          | Should -Be 0
        @($r.Group).Count         | Should -Be 0
        @($r.ExcludedGroup).Count | Should -Be 0
        @($r.Detail).Count        | Should -Be 0
        $r.HasFilter              | Should -BeFalse
    }

    It 'treats $null assignments the same as an empty collection' {
        # Graph omits the property rather than sending [] in some responses.
        $r = InModuleScope msec { ConvertTo-MsecAssignmentTarget $null }
        @($r.Type).Count | Should -Be 0
        $r.HasFilter     | Should -BeFalse
    }

    It 'names the two tenant-wide targets and orders them predictably' {
        $out = InModuleScope msec -Parameters @{ MakeText = $script:MakeText } {
            param($MakeText)
            & ([scriptblock]::Create($MakeText))
            [pscustomobject]@{
                Users   = ConvertTo-MsecAssignmentTarget @((& $script:MkTarget 'allLicensedUsersAssignmentTarget'))
                Devices = ConvertTo-MsecAssignmentTarget @((& $script:MkTarget 'allDevicesAssignmentTarget'))
                # Deliberately supplied devices-first.
                Both    = ConvertTo-MsecAssignmentTarget @(
                            (& $script:MkTarget 'allDevicesAssignmentTarget'),
                            (& $script:MkTarget 'allLicensedUsersAssignmentTarget'))
            }
        }

        $out.Users.Type   | Should -Be @('AllUsers')
        $out.Devices.Type | Should -Be @('AllDevices')
        # Fixed order regardless of the order Graph returned them, so two policies can be
        # compared without sorting first.
        $out.Both.Type    | Should -Be @('AllUsers', 'AllDevices')
        # Tenant-wide targets have no group.
        @($out.Both.Group).Count | Should -Be 0
    }

    It 'lists every included group, and reports the type once' {
        $out = InModuleScope msec -Parameters @{ MakeText = $script:MakeText } {
            param($MakeText)
            & ([scriptblock]::Create($MakeText))
            ConvertTo-MsecAssignmentTarget -GroupName @{ 'g1' = 'sg-pilot'; 'g2' = 'sg-broad' } -Assignment @(
                (& $script:MkTarget 'groupAssignmentTarget' 'g1'),
                (& $script:MkTarget 'groupAssignmentTarget' 'g2'),
                (& $script:MkTarget 'groupAssignmentTarget' 'g3'))
        }

        # Type is DISTINCT - three group assignments are still one kind of target.
        $out.Type  | Should -Be @('Group')
        # ...and the multiplicity lives here.
        $out.Group | Should -Be @('sg-pilot', 'sg-broad', 'g3')
        @($out.Detail).Count | Should -Be 3
    }

    It 'falls back to the group id when no name was supplied' {
        # -IncludeAssignmentGroup was not used, or the lookup was forbidden. A target must
        # never be nameless: the id is what you would act on.
        $r = InModuleScope msec -Parameters @{ MakeText = $script:MakeText } {
            param($MakeText)
            & ([scriptblock]::Create($MakeText))
            ConvertTo-MsecAssignmentTarget @((& $script:MkTarget 'groupAssignmentTarget' 'g-unknown'))
        }

        $r.Group             | Should -Be @('g-unknown')
        $r.Detail.GroupName  | Should -Be 'g-unknown'
        $r.Detail.GroupId    | Should -Be 'g-unknown'
    }

    It 'keeps excluded groups in their own column, out of the included one' {
        # THE case a count cannot express: this is 2 assignments, and so is a pair of
        # unrelated groups. Two parallel lists would also leave the reader guessing which
        # name was the carve-out - hence a separate column rather than a shared one.
        $out = InModuleScope msec -Parameters @{ MakeText = $script:MakeText } {
            param($MakeText)
            & ([scriptblock]::Create($MakeText))
            $names = @{ 'g9' = 'sg-vips'; 'g8' = 'sg-execs' }
            [pscustomobject]@{
                One = ConvertTo-MsecAssignmentTarget -GroupName $names -Assignment @(
                          (& $script:MkTarget 'allLicensedUsersAssignmentTarget'),
                          (& $script:MkTarget 'exclusionGroupAssignmentTarget' 'g9'))
                Two = ConvertTo-MsecAssignmentTarget -GroupName $names -Assignment @(
                          (& $script:MkTarget 'allLicensedUsersAssignmentTarget'),
                          (& $script:MkTarget 'exclusionGroupAssignmentTarget' 'g9'),
                          (& $script:MkTarget 'exclusionGroupAssignmentTarget' 'g8'))
            }
        }

        $out.One.Type          | Should -Be @('AllUsers', 'ExclusionGroup')
        $out.One.ExcludedGroup | Should -Be @('sg-vips')
        # An excluded group is NOT an included one.
        @($out.One.Group).Count | Should -Be 0

        $out.Two.ExcludedGroup | Should -Be @('sg-vips', 'sg-execs')
        ($out.One.Detail | Where-Object IsExclusion).TargetType | Should -Be 'ExclusionGroup'
    }

    It 'separates included from excluded when a policy has both' {
        $r = InModuleScope msec -Parameters @{ MakeText = $script:MakeText } {
            param($MakeText)
            & ([scriptblock]::Create($MakeText))
            ConvertTo-MsecAssignmentTarget -GroupName @{ 'g1' = 'sg-pilot'; 'g9' = 'sg-vips' } -Assignment @(
                (& $script:MkTarget 'groupAssignmentTarget' 'g1'),
                (& $script:MkTarget 'exclusionGroupAssignmentTarget' 'g9'))
        }

        # The whole point of two columns: no positional guessing about which is which.
        $r.Type          | Should -Be @('Group', 'ExclusionGroup')
        $r.Group         | Should -Be @('sg-pilot')
        $r.ExcludedGroup | Should -Be @('sg-vips')
    }

    It 'flags a filtered assignment, whose stated target overstates its reach' {
        $out = InModuleScope msec -Parameters @{ MakeText = $script:MakeText } {
            param($MakeText)
            & ([scriptblock]::Create($MakeText))
            [pscustomobject]@{
                Filtered    = ConvertTo-MsecAssignmentTarget @((& $script:MkTarget 'allDevicesAssignmentTarget' $null 'include'))
                Unfiltered  = ConvertTo-MsecAssignmentTarget @((& $script:MkTarget 'allDevicesAssignmentTarget'))
                NoneLiteral = ConvertTo-MsecAssignmentTarget @((& $script:MkTarget 'allDevicesAssignmentTarget' $null 'none'))
            }
        }

        $out.Filtered.HasFilter         | Should -BeTrue
        $out.Filtered.Detail.FilterType | Should -Be 'include'
        $out.Filtered.Detail.FilterId   | Should -Be 'flt-1'
        # The type is unaffected - it is still an All Devices assignment, just narrowed.
        $out.Filtered.Type              | Should -Be @('AllDevices')

        $out.Unfiltered.HasFilter          | Should -BeFalse
        $out.Unfiltered.Detail.FilterType  | Should -BeNullOrEmpty
        # Graph's literal 'none' must normalise to $null so callers test one thing.
        $out.NoneLiteral.HasFilter         | Should -BeFalse
        $out.NoneLiteral.Detail.FilterType | Should -BeNullOrEmpty
    }

    It 'keeps an unrecognised target type rather than flattening it' {
        # Intune has added target types before. A name you can look up beats a label that
        # hides one, and it sorts after the kinds msec does know.
        $r = InModuleScope msec {
            ConvertTo-MsecAssignmentTarget @(
                [pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } },
                [pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.futureThingTarget' } })
        }

        $r.Type | Should -Be @('AllDevices', 'futureThingTarget')
        ($r.Detail | Where-Object TargetType -eq 'futureThingTarget').IsExclusion | Should -BeFalse
    }

    It 'reports Unknown only when there is no @odata.type at all' {
        # Here 'Unknown' is the accurate description rather than a shrug - and the
        # assignment is still counted, so the columns cannot disagree with
        # AssignmentCount.
        $r = InModuleScope msec {
            ConvertTo-MsecAssignmentTarget @([pscustomobject]@{ target = [pscustomobject]@{} })
        }

        $r.Type              | Should -Be @('Unknown')
        @($r.Detail).Count   | Should -Be 1
        $r.Detail.TargetType | Should -Be 'Unknown'
    }

    It 'maps a ConfigMgr collection target, which has no group' {
        $r = InModuleScope msec -Parameters @{ MakeText = $script:MakeText } {
            param($MakeText)
            & ([scriptblock]::Create($MakeText))
            ConvertTo-MsecAssignmentTarget @((& $script:MkTarget 'configurationManagerCollectionAssignmentTarget'))
        }

        $r.Type          | Should -Be @('ConfigManagerCollection')
        @($r.Group).Count | Should -Be 0
    }

    It 'keeps the verbatim assignment on every detail row' {
        $r = InModuleScope msec -Parameters @{ MakeText = $script:MakeText } {
            param($MakeText)
            & ([scriptblock]::Create($MakeText))
            ConvertTo-MsecAssignmentTarget @((& $script:MkTarget 'groupAssignmentTarget' 'g1'))
        }

        $r.Detail.Raw.id             | Should -Be 'as-groupAssignmentTarget-g1'
        $r.Detail.Raw.target.groupId | Should -Be 'g1'
    }
}
