#Requires -Module Pester
#
# Tests for Get-MsecIntuneConfigurationProfile. The function merges Settings Catalog and
# classic Templates into a unified shape, derives Platform from @odata.type, gets
# AssignmentCount via $expand, and optionally adds per-policy status counts.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecIntuneConfigurationProfile' {
    BeforeEach {
        InModuleScope msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId        = 'tenant'
                ClientId        = 'client'
                KeyVaultName    = 'kv-test'
                KeyName         = 'msec-app'
                ThumbprintBytes = $Thumb
                Tokens          = @{}
            }
        }
    }

    It 'merges Settings Catalog policies and classic device configurations into a unified shape' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/beta/deviceManagement/configurationPolicies\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'sc-1'; name = 'Win10 Hardening'; description = 'Catalog policy'
                        platforms = 'windows10'
                        createdDateTime = '2026-04-01T00:00:00Z'; lastModifiedDateTime = '2026-05-01T00:00:00Z'
                        assignments = @(@{ target = @{ groupId = 'g-1' } }; @{ target = @{ groupId = 'g-2' } })
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/v1.0/deviceManagement/deviceConfigurations\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'tpl-1'; displayName = 'Legacy iOS Restrictions'; description = 'Classic template'
                        '@odata.type' = '#microsoft.graph.iosGeneralDeviceConfiguration'
                        createdDateTime = '2025-12-01T00:00:00Z'; lastModifiedDateTime = '2026-02-01T00:00:00Z'
                        assignments = @()
                    }
                    [pscustomobject]@{
                        # Regression: windows10* used to also match windows* without 'break' -
                        # producing Platform = @('windows10','windows') instead of a single value.
                        id = 'tpl-2'; displayName = 'Win10 Custom'; description = 'Classic template'
                        '@odata.type' = '#microsoft.graph.windows10CustomConfiguration'
                        createdDateTime = '2024-05-20T00:00:00Z'; lastModifiedDateTime = '2024-06-01T00:00:00Z'
                        assignments = @(@{ target = @{ groupId = 'g-3' } })
                    }
                ) }
            }

            Get-MsecIntuneConfigurationProfile -NoGroupNameLookup
        }

        $rows.Count | Should -Be 3

        $sc = $rows | Where-Object Source -eq 'SettingsCatalog'
        $sc.Id          | Should -Be 'sc-1'
        $sc.DisplayName | Should -Be 'Win10 Hardening'   # comes from .name, not .displayName
        $sc.Platform    | Should -Be 'windows10'
        $sc.Type        | Should -Be 'Settings Catalog'

        $ios = $rows | Where-Object Id -eq 'tpl-1'
        $ios.DisplayName | Should -Be 'Legacy iOS Restrictions'
        $ios.Platform    | Should -Be 'iOS'              # derived from @odata.type prefix
        $ios.Type        | Should -Be 'iosGeneralDeviceConfiguration'

        # Regression: Platform is a single string, not an array of wildcard matches.
        $win = $rows | Where-Object Id -eq 'tpl-2'
        $win.Platform | Should -Be 'windows10'
        $win.Platform | Should -BeOfType [string]

        # AssignmentCount comes from $expand=assignments (no extra round-trip).
        $sc.AssignmentCount | Should -Be 2
        ($rows | Where-Object Id -eq 'tpl-1').AssignmentCount | Should -Be 0
        $win.AssignmentCount | Should -Be 1

        # Status column only appears with -IncludeStatus - the rows here should not have it.
        $sc.PSObject.Properties.Name  | Should -Not -Contain 'Status'
        $win.PSObject.Properties.Name | Should -Not -Contain 'Status'

        # Raw - every row carries the full Graph object verbatim. Lets the consumer
        # access fields we don't flatten (createdDateTime is just an obvious one).
        $sc.Raw  | Should -Not -BeNullOrEmpty
        $sc.Raw.id   | Should -Be 'sc-1'
        $sc.Raw.name | Should -Be 'Win10 Hardening'

        $win.Raw                | Should -Not -BeNullOrEmpty
        $win.Raw.id             | Should -Be 'tpl-2'
        $win.Raw.'@odata.type'  | Should -Match 'windows10CustomConfiguration'

        # PSTypeName tag - so the .psm1's Update-TypeData picks the right
        # DefaultDisplayPropertySet (hides Raw from default Format-Table).
        $sc.PSObject.TypeNames  | Should -Contain 'MsecIntuneConfigurationProfile'
        $win.PSObject.TypeNames | Should -Contain 'MsecIntuneConfigurationProfile'
    }

    It '-IncludeSettings fetches per-policy settings for SC and merges them into Raw' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            # SC list endpoint returns one policy
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/beta/deviceManagement/configurationPolicies\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'sc-1'; name = 'Win10 Hardening'; platforms = 'windows10'
                        assignments = @()
                    }
                ) }
            }
            # Per-policy settings endpoint - this is the extra call -IncludeSettings makes
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/configurationPolicies/sc-1/settings' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = '0'; settingInstance = @{ settingDefinitionId = 'firewall_state' } }
                    [pscustomobject]@{ id = '1'; settingInstance = @{ settingDefinitionId = 'bitlocker_required' } }
                ) }
            }
            # No Templates in this test
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/v1.0/deviceManagement/deviceConfigurations' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            Get-MsecIntuneConfigurationProfile -Source SettingsCatalog -IncludeSettings -NoGroupNameLookup
        }

        $rows.Count | Should -Be 1
        $rows[0].Raw.settings        | Should -Not -BeNullOrEmpty
        $rows[0].Raw.settings.Count  | Should -Be 2
        $rows[0].Raw.settings[0].settingInstance.settingDefinitionId | Should -Be 'firewall_state'
    }

    It '-IncludeStatus adds check-in counts from the right endpoint per Source' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            # The list-all endpoint with $expand=assignments
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/beta/deviceManagement/configurationPolicies\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'sc-1'; name = 'SC Test'; platforms = 'windows10'
                        assignments = @(@{ target = @{ groupId = 'g-1' } })
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/v1.0/deviceManagement/deviceConfigurations\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'tpl-1'; displayName = 'Tpl Test'
                        '@odata.type' = '#microsoft.graph.windows10GeneralConfiguration'
                        assignments = @(@{ target = @{ groupId = 'g-1' } })
                    }
                ) }
            }
            # Templates status: single aggregated object from /deviceStatusOverview
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceConfigurations/tpl-1/deviceStatusOverview' } -MockWith {
                [pscustomobject]@{
                    successCount = 10; errorCount = 0; conflictCount = 0
                    notApplicableCount = 2; pendingCount = 0
                }
            }
            # Settings Catalog status: pre-fetched via the Reports API. Mock the helper
            # directly to avoid mocking the full exportJob + poll + download flow here.
            Mock Get-MsecSettingsCatalogStatusReport -MockWith {
                @{
                    'sc-1' = [pscustomobject]@{
                        SuccessCount = 3; ErrorCount = 1; ConflictCount = 0
                        NotApplicableCount = 1; PendingCount = 0
                    }
                }
            }

            Get-MsecIntuneConfigurationProfile -IncludeStatus -NoGroupNameLookup
        }

        # Templates: real counts from deviceStatusOverview
        $tpl = $rows | Where-Object Source -eq 'Templates'
        $tpl.SuccessCount   | Should -Be 10
        $tpl.ErrorCount     | Should -Be 0
        $tpl.SuccessPercent | Should -Be 100.0

        # Settings Catalog: counts came from the (mocked) Reports API helper.
        $sc = $rows | Where-Object Source -eq 'SettingsCatalog'
        $sc.SuccessCount   | Should -Be 3
        $sc.ErrorCount     | Should -Be 1
        # Applicable = 3 success + 1 error + 0 conflict + 0 pending = 4 -> 75.0
        $sc.SuccessPercent | Should -Be 75.0

        # Status rollup with -IncludeStatus.
        $tpl.Status | Should -Be 'Healthy'   # 100% success, no errors/conflicts
        $sc.Status  | Should -Be 'Degraded'  # 75% with an error
    }

    It 'NotDeployed policies get zero counts (not nulls) on every status field' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/beta/deviceManagement/configurationPolicies\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'sc-unassigned'; name = 'Unassigned SC policy'; platforms = 'windows10'
                        assignments = @()  # AssignmentCount = 0 -> NotDeployed
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/v1.0/deviceManagement/deviceConfigurations\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'tpl-unassigned'; displayName = 'Unassigned Template'
                        '@odata.type' = '#microsoft.graph.windows10GeneralConfiguration'
                        assignments = @()
                    }
                ) }
            }
            Mock Get-MsecSettingsCatalogStatusReport -MockWith { @{} }

            Get-MsecIntuneConfigurationProfile -IncludeStatus -NoGroupNameLookup
        }

        foreach ($r in $rows) {
            $r.Status             | Should -Be 'NotDeployed'
            $r.SuccessCount       | Should -Be 0
            $r.ErrorCount         | Should -Be 0
            $r.ConflictCount      | Should -Be 0
            $r.NotApplicableCount | Should -Be 0
            $r.PendingCount       | Should -Be 0
            $r.SuccessPercent     | Should -Be 0
        }
    }

    It 'Status is NotReporting when assigned but no status data, and all counts are zero (consistent with NotDeployed)' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/beta/deviceManagement/configurationPolicies\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    # Assigned, but the report (mocked below) does not include this PolicyId
                    # - same shape as your Autopilot device prep / empty-group policies.
                    [pscustomobject]@{
                        id = 'sc-orphan'; name = 'Empty group policy'; platforms = 'windows10'
                        assignments = @(@{ target = @{ groupId = 'g-1' } })
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/v1.0/deviceManagement/deviceConfigurations\?' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            Mock Get-MsecSettingsCatalogStatusReport -MockWith { @{} }  # empty report

            Get-MsecIntuneConfigurationProfile -IncludeStatus -NoGroupNameLookup
        }

        $r = $rows[0]
        $r.AssignmentCount    | Should -Be 1
        $r.Status             | Should -Be 'NotReporting'
        # NotReporting now zeros every status field (consistent with NotDeployed) so the
        # table doesn't mix blanks and integers per row.
        $r.SuccessCount       | Should -Be 0
        $r.ErrorCount         | Should -Be 0
        $r.ConflictCount      | Should -Be 0
        $r.NotApplicableCount | Should -Be 0
        $r.PendingCount       | Should -Be 0
        $r.SuccessPercent     | Should -Be 0
    }

    Context 'assignment targets' {
        BeforeAll {
            # One policy per interesting target shape. Note sc-excl: tenant-wide with a
            # carve-out, which AssignmentCount alone reports identically to sc-two-groups.
            $script:ProfileMockText = @'
Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
    [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
}
Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/beta/deviceManagement/configurationPolicies\?' } -MockWith {
    $t = { param($Type, $GroupId, $FilterType)
        $o = @{ '@odata.type' = "#microsoft.graph.$Type" }
        if ($GroupId)    { $o['groupId'] = $GroupId }
        if ($FilterType) { $o['deviceAndAppManagementAssignmentFilterType'] = $FilterType
                           $o['deviceAndAppManagementAssignmentFilterId']   = 'flt-1' }
        [pscustomobject]@{ target = [pscustomobject]$o } }

    [pscustomobject]@{ value = @(
        [pscustomobject]@{ id = 'sc-allusers'; name = 'Baseline'; platforms = 'windows10'
                           assignments = @((& $t 'allLicensedUsersAssignmentTarget')) }
        [pscustomobject]@{ id = 'sc-excl'; name = 'Everyone But VIPs'; platforms = 'windows10'
                           assignments = @((& $t 'allLicensedUsersAssignmentTarget'),
                                           (& $t 'exclusionGroupAssignmentTarget' 'g-vip')) }
        [pscustomobject]@{ id = 'sc-two-groups'; name = 'Two Rings'; platforms = 'windows10'
                           assignments = @((& $t 'groupAssignmentTarget' 'g-ring1'),
                                           (& $t 'groupAssignmentTarget' 'g-ring2')) }
        [pscustomobject]@{ id = 'sc-filtered'; name = 'Filtered Devices'; platforms = 'windows10'
                           assignments = @((& $t 'allDevicesAssignmentTarget' $null 'include')) }
        [pscustomobject]@{ id = 'sc-none'; name = 'Orphan'; platforms = 'windows10'
                           assignments = @() }
    ) }
}
Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/v1.0/deviceManagement/deviceConfigurations\?' } -MockWith {
    [pscustomobject]@{ value = @() }
}
'@
        }

        It 'reports the target type with no group call at all under -NoGroupNameLookup' {
            $out = InModuleScope msec -Parameters @{ MockText = $script:ProfileMockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                # The switch must mean PROVABLY no per-group calls, not merely fewer.
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/v1.0/groups/' } -MockWith {
                    throw 'no group lookup may happen under -NoGroupNameLookup'
                }
                @(Get-MsecIntuneConfigurationProfile -Source SettingsCatalog -NoGroupNameLookup)
            }

            ($out | Where-Object Id -eq 'sc-allusers').AssignmentType     | Should -Be @('AllUsers')
            ($out | Where-Object Id -eq 'sc-filtered').AssignmentType     | Should -Be @('AllDevices')
            ($out | Where-Object Id -eq 'sc-filtered').HasAssignmentFilter | Should -BeTrue

            # An unassigned policy gets empty arrays, not $null, so -contains and .Count
            # work at the call site without a null check first.
            ($out | Where-Object Id -eq 'sc-none').AssignmentType          | Should -BeNullOrEmpty
            @(($out | Where-Object Id -eq 'sc-none').AssignmentGroup).Count | Should -Be 0

            # Ids stand in for names because the lookup was skipped.
            ($out | Where-Object Id -eq 'sc-two-groups').AssignmentType  | Should -Be @('Group')
            ($out | Where-Object Id -eq 'sc-two-groups').AssignmentGroup | Should -Be @('g-ring1', 'g-ring2')

            ($out | Where-Object Id -eq 'sc-excl').AssignmentType          | Should -Be @('AllUsers', 'ExclusionGroup')
            ($out | Where-Object Id -eq 'sc-excl').AssignmentExcludedGroup | Should -Be @('g-vip')
            # The carve-out must not leak into the INCLUDED groups column.
            @(($out | Where-Object Id -eq 'sc-excl').AssignmentGroup).Count | Should -Be 0
        }

        It 'distinguishes an exclusion from a second group, which AssignmentCount cannot' {
            $out = InModuleScope msec -Parameters @{ MockText = $script:ProfileMockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                @(Get-MsecIntuneConfigurationProfile -Source SettingsCatalog -NoGroupNameLookup)
            }

            $excl = $out | Where-Object Id -eq 'sc-excl'
            $two  = $out | Where-Object Id -eq 'sc-two-groups'

            # Identical counts...
            $excl.AssignmentCount | Should -Be 2
            $two.AssignmentCount  | Should -Be 2
            # ...entirely different deployments.
            $excl.AssignmentType          | Should -Be @('AllUsers', 'ExclusionGroup')
            $two.AssignmentType           | Should -Be @('Group')
            $excl.AssignmentExcludedGroup | Should -Be @('g-vip')
            @($two.AssignmentExcludedGroup).Count | Should -Be 0
            @($excl.AssignmentDetail | Where-Object IsExclusion).Count | Should -Be 1
            @($two.AssignmentDetail  | Where-Object IsExclusion).Count | Should -Be 0
        }

        It 'resolves group names by default, one call per distinct group' {
            $out = InModuleScope msec -Parameters @{ MockText = $script:ProfileMockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                $script:GroupCalls = [System.Collections.Generic.List[string]]::new()
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/v1.0/groups/' } -MockWith {
                    $id = ([regex]::Match([string]$Uri, '/groups/(?<id>[^?]+)')).Groups['id'].Value
                    $script:GroupCalls.Add($id)
                    [pscustomobject]@{ id = $id; displayName = "name-of-$id" }
                }
                [pscustomobject]@{
                    Rows  = @(Get-MsecIntuneConfigurationProfile -Source SettingsCatalog)
                    Calls = @($script:GroupCalls)
                }
            }

            ($out.Rows | Where-Object Id -eq 'sc-two-groups').AssignmentGroup |
                Should -Be @('name-of-g-ring1', 'name-of-g-ring2')
            ($out.Rows | Where-Object Id -eq 'sc-excl').AssignmentExcludedGroup |
                Should -Be @('name-of-g-vip')
            ($out.Rows | Where-Object Id -eq 'sc-two-groups').AssignmentDetail.GroupName |
                Should -Be @('name-of-g-ring1', 'name-of-g-ring2')
            # Same names, reached the other way - the column is derived from the detail.

            # Three distinct groups across the policies, three lookups - no duplicates.
            @($out.Calls).Count            | Should -Be 3
            @($out.Calls | Sort-Object -Unique).Count | Should -Be 3
        }

        It 'labels a deleted group instead of leaving it blank' {
            # A policy assigned only to a group that no longer exists is deployed to
            # nobody. That is a finding, so it has to be legible rather than empty.
            $row = InModuleScope msec -Parameters @{ MockText = $script:ProfileMockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/v1.0/groups/' } -MockWith {
                    throw 'Response status code does not indicate success: 404 (Not Found).'
                }
                @(Get-MsecIntuneConfigurationProfile -Source SettingsCatalog) |
                    Where-Object Id -eq 'sc-excl'
            }

            $row.AssignmentExcludedGroup | Should -Be @('<deleted group g-vip>')
        }

        It 'warns once and falls back to ids when Group.Read.All is missing' {
            $out = InModuleScope msec -Parameters @{ MockText = $script:ProfileMockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                $script:GroupCalls = [System.Collections.Generic.List[string]]::new()
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/v1.0/groups/' } -MockWith {
                    $script:GroupCalls.Add('call')
                    throw 'Response status code does not indicate success: 403 (Forbidden).'
                }
                $rows = Get-MsecIntuneConfigurationProfile -Source SettingsCatalog `
                            -WarningVariable w -WarningAction SilentlyContinue
                [pscustomobject]@{ Rows = @($rows); Warnings = @($w); Calls = @($script:GroupCalls) }
            }

            ($out.Warnings -join "`n") | Should -Match 'Group\.Read\.All'
            # One warning for the run, not one per assigned group.
            @($out.Warnings).Count     | Should -Be 1
            # And it stops asking after the first refusal.
            @($out.Calls).Count        | Should -Be 1
            # The target TYPE is unaffected by a failed name lookup.
            ($out.Rows | Where-Object Id -eq 'sc-allusers').AssignmentType     | Should -Be @('AllUsers')
            ($out.Rows | Where-Object Id -eq 'sc-excl').AssignmentType          | Should -Be @('AllUsers', 'ExclusionGroup')
            ($out.Rows | Where-Object Id -eq 'sc-excl').AssignmentExcludedGroup | Should -Be @('g-vip')
        }

        It 'gives up after one auth failure instead of warning per group' {
            # A 401 is not about this group - it will be true of the next one too. Warning
            # per group would bury the output of a tenant with hundreds of profiles.
            $out = InModuleScope msec -Parameters @{ MockText = $script:ProfileMockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                $script:GroupCalls = [System.Collections.Generic.List[string]]::new()
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/v1.0/groups/' } -MockWith {
                    $script:GroupCalls.Add('call')
                    throw 'Response status code does not indicate success: 401 (Unauthorized).'
                }
                $rows = Get-MsecIntuneConfigurationProfile -Source SettingsCatalog `
                            -WarningVariable w -WarningAction SilentlyContinue
                [pscustomobject]@{ Rows = @($rows); Warnings = @($w); Calls = @($script:GroupCalls) }
            }

            @($out.Warnings).Count | Should -Be 1
            @($out.Calls).Count    | Should -Be 1
            # A 401 must NOT be described as a missing permission - the fixes are opposite.
            ($out.Warnings -join "`n") | Should -Match 'Connect-Msec'
            ($out.Warnings -join "`n") | Should -Not -Match 'Group\.Read\.All'
            # Target types survive a failed name lookup untouched.
            ($out.Rows | Where-Object Id -eq 'sc-excl').AssignmentType | Should -Be @('AllUsers', 'ExclusionGroup')
        }

        It 'warns per group for a failure that really is per group' {
            # A transient failure on one group says nothing about the next, so it keeps
            # going - and each warning names a different id rather than repeating.
            $out = InModuleScope msec -Parameters @{ MockText = $script:ProfileMockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/v1.0/groups/' } -MockWith {
                    throw 'Response status code does not indicate success: 500 (Internal Server Error).'
                }
                $rows = Get-MsecIntuneConfigurationProfile -Source SettingsCatalog `
                            -WarningVariable w -WarningAction SilentlyContinue
                [pscustomobject]@{ Rows = @($rows); Warnings = @($w) }
            }

            # Three distinct groups across the fixture, so three warnings - bounded by
            # distinct groups, not by policy count.
            @($out.Warnings).Count | Should -Be 3
            ($out.Warnings -join "`n") | Should -Match 'g-vip'
            ($out.Warnings -join "`n") | Should -Match 'g-ring1'
            # Ids stand in for the names that could not be read.
            ($out.Rows | Where-Object Id -eq 'sc-excl').AssignmentExcludedGroup | Should -Be @('g-vip')
        }

        It 'keeps AssignmentCount as the raw number of assignments' {
            # AssignmentType is DISTINCT, so it collapses three groups into one entry.
            # AssignmentDetail must still account for every assignment, or the columns
            # and the count would disagree.
            $out = InModuleScope msec -Parameters @{ MockText = $script:ProfileMockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                @(Get-MsecIntuneConfigurationProfile -Source SettingsCatalog -NoGroupNameLookup)
            }

            foreach ($row in $out) {
                @($row.AssignmentDetail).Count | Should -Be $row.AssignmentCount `
                    -Because "AssignmentDetail must account for every assignment on $($row.Id)"
            }
        }
    }
}

