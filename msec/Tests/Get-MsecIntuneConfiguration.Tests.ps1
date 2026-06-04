#Requires -Module Pester
#
# Tests for Get-MsecIntuneConfiguration. The function merges Settings Catalog and
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

Describe 'Get-MsecIntuneConfiguration' {
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

            Get-MsecIntuneConfiguration
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

            Get-MsecIntuneConfiguration -IncludeStatus
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

            Get-MsecIntuneConfiguration -IncludeStatus
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

            Get-MsecIntuneConfiguration -IncludeStatus
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
}
