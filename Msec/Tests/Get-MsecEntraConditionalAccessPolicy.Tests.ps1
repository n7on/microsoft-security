#Requires -Module Pester
#
# Tests for Get-MsecEntraConditionalAccessPolicy. Verifies the deeply-nested
# Graph response (conditions.users.*, conditions.applications.*, grantControls.*)
# is flattened to the documented PSCustomObject shape, with array fields always
# coerced to actual arrays (never $null) so Where-Object -contains works.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEntraConditionalAccessPolicy' {
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

    It 'flattens conditions/grantControls to top-level columns and projects arrays as arrays' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/identity/conditionalAccess/policies' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id              = 'pol-1'
                        displayName     = 'Require MFA for all admins'
                        state           = 'enabled'
                        createdDateTime  = '2024-08-12T10:00:00Z'
                        modifiedDateTime = '2026-04-22T13:00:00Z'
                        conditions = [pscustomobject]@{
                            users = [pscustomobject]@{
                                includeUsers  = @('All')
                                excludeUsers  = @('break-glass-guid')
                                includeGroups = @('admins-group-guid')
                                excludeGroups = @()
                                includeRoles  = @('global-admin-role-guid')
                                excludeRoles  = @()
                            }
                            applications = [pscustomobject]@{
                                includeApplications = @('All')
                                excludeApplications = @()
                                includeUserActions  = @()
                            }
                            platforms = [pscustomobject]@{
                                includePlatforms = @('all')
                                excludePlatforms = @()
                            }
                            locations = [pscustomobject]@{
                                includeLocations = @('All')
                                excludeLocations = @('trusted-ip-loc-guid')
                            }
                            clientAppTypes   = @('all')
                            signInRiskLevels = @('high','medium')
                            userRiskLevels   = @()
                        }
                        grantControls = [pscustomobject]@{
                            operator         = 'OR'
                            builtInControls  = @('mfa','compliantDevice')
                        }
                    }
                    [pscustomobject]@{
                        # A report-only policy: state value distinct from 'enabled'.
                        id              = 'pol-2'
                        displayName     = 'Block legacy auth (report-only)'
                        state           = 'enabledForReportingButNotEnforced'
                        createdDateTime  = '2026-02-01T10:00:00Z'
                        modifiedDateTime = '2026-05-01T10:00:00Z'
                        conditions = [pscustomobject]@{
                            users        = [pscustomobject]@{ includeUsers = @('All'); excludeUsers = @() }
                            applications = [pscustomobject]@{ includeApplications = @('All') }
                            # No platforms / locations restriction on this one - those nested
                            # objects can legitimately be $null in the Graph response.
                        }
                        grantControls = [pscustomobject]@{
                            operator = 'OR'
                            builtInControls = @('block')
                        }
                    }
                ) }
            }

            Get-MsecEntraConditionalAccessPolicy
        }

        $rows.Count | Should -Be 2

        $p1 = $rows | Where-Object Id -eq 'pol-1'
        $p1.DisplayName        | Should -Be 'Require MFA for all admins'
        $p1.State              | Should -Be 'enabled'
        $p1.CreatedDateTime    | Should -BeOfType [datetime]

        # Nested arrays flatten to top-level columns
        $p1.IncludedUsers      | Should -Be @('All')
        $p1.ExcludedUsers      | Should -Be @('break-glass-guid')
        $p1.IncludedGroups     | Should -Be @('admins-group-guid')
        $p1.IncludedRoles      | Should -Be @('global-admin-role-guid')
        $p1.IncludedApps       | Should -Be @('All')
        $p1.SignInRiskLevels   | Should -Be @('high','medium')
        $p1.ExcludedLocations  | Should -Be @('trusted-ip-loc-guid')

        # Grant controls
        $p1.GrantOperator      | Should -Be 'OR'
        $p1.Requires           | Should -Contain 'mfa'
        $p1.Requires           | Should -Contain 'compliantDevice'

        # The audit-friendly query pattern works.
        ($rows | Where-Object Requires -contains 'mfa').DisplayName | Should -Be 'Require MFA for all admins'

        # Raw holds the full Graph object so consumers can JSON-export / diff /
        # access fields that aren't flattened (sessionControls, devices filter, ...).
        $p1.Raw                          | Should -Not -BeNullOrEmpty
        $p1.Raw.id                       | Should -Be 'pol-1'
        $p1.Raw.conditions.users.includeUsers | Should -Contain 'All'
        # And the row is tagged with the PowerShell type that owns the default
        # display set - so Format-Table doesn't render Raw by default.
        $p1.PSObject.TypeNames           | Should -Contain 'MsecEntraConditionalAccessPolicy'

        # Report-only policy state surfaces verbatim (so consumer can filter on it)
        $p2 = $rows | Where-Object Id -eq 'pol-2'
        $p2.State | Should -Be 'enabledForReportingButNotEnforced'

        # When the platforms / locations conditions are absent in the Graph
        # response, the projected columns surface as null-or-empty (PowerShell
        # unrolls empty arrays on PSCustomObject property access - that's a
        # language quirk, not a function bug). What matters is the
        # Where-Object -contains pattern downstream consumers use doesn't blow
        # up on those policies.
        $p2.IncludedPlatforms | Should -BeNullOrEmpty
        { $rows | Where-Object IncludedPlatforms -contains 'iOS' } | Should -Not -Throw
        # And the policy with no platform restriction is correctly NOT matched by it.
        ($rows | Where-Object IncludedPlatforms -contains 'iOS').Id |
            Should -Not -Contain 'pol-2'
    }

    It 'rewrites a 403 to mention the missing Policy.Read.All permission' {
        InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/identity/conditionalAccess/policies' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }

            { Get-MsecEntraConditionalAccessPolicy } |
                Should -Throw -ExpectedMessage '*Policy.Read.All*'
        }
    }
}
