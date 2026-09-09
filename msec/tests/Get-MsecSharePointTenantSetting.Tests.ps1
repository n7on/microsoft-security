#Requires -Module Pester
#
# Tests for Get-MsecSharePointTenantSetting.
#
# The tenant settings are the CEILING every site sits under: a locked-down site in a tenant
# where anyone-links are on is still exposed, and reviewing sites one at a time never shows it.
#
# Two things worth pinning. First, an empty domain list must not render blank - with
# SharingDomainRestrictionMode = allowList, an EMPTY allowed list means nobody outside can be
# invited, which is the opposite of what a blank cell suggests. Second, the 403 has to name the
# permission: Graph's own error names none, and Sites.Read.All (which the app already holds)
# does not cover this endpoint.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecSharePointTenantSetting' {

    BeforeEach {
        InModuleScope Msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
        }
    }

    It 'flattens to one row per setting, keeping only the security-relevant ones' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{
                    sharingCapability            = 'ExternalUserAndGuestSharing'
                    sharingDomainRestrictionMode = 'AllowList'
                    sharingAllowedDomainList     = @('partner.com', 'vendor.com')
                    isLegacyAuthProtocolsEnabled = $true
                    # Not a security control - must not appear in the default projection.
                    tenantDefaultTimezone        = 'W. Europe Standard Time'
                }
            }
            Get-MsecSharePointTenantSetting
        }

        @($rows | ForEach-Object { $_.Setting }) | Should -Contain 'sharingCapability'
        @($rows | ForEach-Object { $_.Setting }) | Should -Not -Contain 'tenantDefaultTimezone'

        ($rows | Where-Object Setting -eq 'sharingAllowedDomainList').Value | Should -Be 'partner.com; vendor.com'
        ($rows | Where-Object Setting -eq 'sharingCapability').Category     | Should -Be 'Sharing'
        # Legacy auth bypasses Conditional Access entirely, so it is grouped where a reviewer
        # will look for it rather than under sharing.
        ($rows | Where-Object Setting -eq 'isLegacyAuthProtocolsEnabled').Category | Should -Be 'Authentication'
    }

    It 'says (none) for an empty list, never blank' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{
                    sharingDomainRestrictionMode = 'AllowList'
                    sharingAllowedDomainList     = @()
                }
            }
            Get-MsecSharePointTenantSetting
        }

        # With an allowList mode, an EMPTY allowed list means nobody outside can be invited at
        # all. A blank cell reads as "we did not look", which is the one reading that is wrong.
        ($rows | Where-Object Setting -eq 'sharingAllowedDomainList').Value | Should -Be '(none)'
    }

    It 'says (not set) for a null, so it is not confused with off' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ sharingCapability = $null }
            }
            Get-MsecSharePointTenantSetting
        }

        ($rows | Where-Object Setting -eq 'sharingCapability').Value | Should -Be '(not set)'
    }

    It 'flattens a nested setting instead of printing a type name' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{
                    idleSessionSignOut = [pscustomobject]@{
                        isEnabled          = $true
                        signOutAfterInSeconds = 3600
                    }
                }
            }
            Get-MsecSharePointTenantSetting
        }

        # 'Value = System.Management.Automation.PSCustomObject' tells a reader nothing.
        ($rows | Where-Object Setting -eq 'idleSessionSignOut.isEnabled').Value | Should -Be 'True'
        ($rows | Where-Object Setting -eq 'idleSessionSignOut.signOutAfterInSeconds').Value | Should -Be '3600'
    }

    It 'returns everything under -All, so the projection can be checked' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{
                    sharingCapability     = 'Disabled'
                    tenantDefaultTimezone = 'W. Europe Standard Time'
                }
            }
            Get-MsecSharePointTenantSetting -All
        }

        # Which settings count as security controls is this command's judgement, so there has
        # to be a way to see what it left out.
        ($rows | Where-Object Setting -eq 'tenantDefaultTimezone').Category | Should -Be 'Other'
    }

    It 'skips a setting this tenant does not report, rather than inventing a null row' {
        $rows = InModuleScope Msec {
            # The property set moves as Microsoft adds settings. A row of nulls for an absent
            # one reads as "configured off" rather than "not present here".
            Mock Invoke-MsecGraphRequest -MockWith { [pscustomobject]@{ sharingCapability = 'Disabled' } }
            Get-MsecSharePointTenantSetting
        }

        @($rows).Count | Should -Be 1
    }

    It 'names the permission on a 403, because Graph names none' {
        InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }

            # The app already holds Sites.Read.All, so "you need a SharePoint permission" would
            # send the reader to check one they have. This endpoint needs its own.
            { Get-MsecSharePointTenantSetting } | Should -Throw '*SharePointTenantSettings.Read.All*'
        }
    }

    It 'throws a clear error when not connected' {
        InModuleScope Msec {
            $script:MsecSession = $null
            { Get-MsecSharePointTenantSetting } | Should -Throw '*Connect-Msec*'
        }
    }
}
