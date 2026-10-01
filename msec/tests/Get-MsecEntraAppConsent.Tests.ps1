#Requires -Module Pester
#
# Tests for Get-MsecEntraAppConsent.
#
# The behaviour worth pinning hardest is the one that made this command cost 30 seconds instead
# of 6: app role assignments are read from the RESOURCE side, because expanding them on each
# service principal silently truncates at one page. A test cannot catch Graph truncating, but it
# can catch someone "optimising" the command back to $expand - the resource-side mock is the
# only shape that satisfies these tests.
#
# After that: a permission that could not be resolved must be null rather than false, and a
# resource that could not be read must produce a row rather than vanish. An app whose
# permissions nobody could enumerate must never read as an app with none.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEntraAppConsent' {

    BeforeEach {
        InModuleScope Msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
        }
    }

    It 'splits a scope string into one row per permission' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*servicePrincipals?$select*') {
                    @(
                        [pscustomobject]@{ id = 'client-1'; appId = 'app-1'; displayName = 'Contoso App'; appRoles = @() }
                        [pscustomobject]@{ id = 'res-1';    appId = 'app-r'; displayName = 'Microsoft Graph'; appRoles = @() }
                    )
                }
                elseif ($Path -like '*oauth2PermissionGrants*') {
                    @([pscustomobject]@{
                        id = 'g1'; clientId = 'client-1'; resourceId = 'res-1'
                        consentType = 'AllPrincipals'; principalId = $null
                        # Leading whitespace is how Graph actually returns these.
                        scope = ' Mail.Read User.Read Files.Read.All'
                    })
                }
                else { @() }
            }
            Get-MsecEntraAppConsent -PermissionType Delegated
        }

        $rows.Count | Should -Be 3
        @($rows.Permission) | Should -Contain 'Mail.Read'
        @($rows.Permission) | Should -Contain 'Files.Read.All'
        ($rows | Where-Object Permission -eq 'User.Read').ConsentType | Should -Be 'AllPrincipals'
        # Curated list: two of these three are sensitive, User.Read is not.
        @($rows | Where-Object IsHighRisk).Count | Should -Be 2
    }

    It 'reads app role assignments from the resource, and ignores user and group assignments' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*servicePrincipals?$select*') {
                    @(
                        [pscustomobject]@{ id = 'client-1'; appId = 'app-1'; displayName = 'Contoso App'; appRoles = @() }
                        [pscustomobject]@{
                            id = 'res-1'; appId = 'app-r'; displayName = 'Microsoft Graph'
                            appRoles = @([pscustomobject]@{ id = 'role-1'; value = 'Mail.Read' })
                        }
                    )
                }
                elseif ($Path -like '*appRoleAssignedTo*') {
                    @(
                        [pscustomobject]@{ id = 'a1'; appRoleId = 'role-1'; principalId = 'client-1'
                                           principalType = 'ServicePrincipal'; principalDisplayName = 'Contoso App'
                                           createdDateTime = '2026-01-01T00:00:00Z' }
                        # Assigning an app role to a USER says who may use the app. Not consent.
                        [pscustomobject]@{ id = 'a2'; appRoleId = 'role-1'; principalId = 'user-1'
                                           principalType = 'User'; principalDisplayName = 'Someone' }
                        [pscustomobject]@{ id = 'a3'; appRoleId = 'role-1'; principalId = 'group-1'
                                           principalType = 'Group'; principalDisplayName = 'A group' }
                    )
                }
                else { @() }
            }
            Get-MsecEntraAppConsent -PermissionType Application
        }

        $rows.Count | Should -Be 1
        $rows[0].Permission | Should -Be 'Mail.Read'
        $rows[0].PermissionType | Should -Be 'Application'
        $rows[0].ConsentType | Should -Be 'Application'
        $rows[0].ClientDisplayName | Should -Be 'Contoso App'
        $rows[0].IsHighRisk | Should -BeTrue
    }

    It 'only sweeps resources that publish app roles' {
        InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*servicePrincipals?$select*') {
                    @(
                        [pscustomobject]@{ id = 'plain-1'; displayName = 'No roles'; appRoles = @() }
                        [pscustomobject]@{ id = 'res-1'; displayName = 'Publisher'
                                           appRoles = @([pscustomobject]@{ id = 'role-1'; value = 'Mail.Read' }) }
                    )
                }
                else { @() }
            }
            Get-MsecEntraAppConsent -PermissionType Application | Out-Null

            # One call for the publisher, none for the principal that cannot be a resource.
            Should -Invoke Invoke-MsecGraphRequest -Times 1 -Exactly -ParameterFilter { $Path -like '*/servicePrincipals/res-1/appRoleAssignedTo*' }
            Should -Invoke Invoke-MsecGraphRequest -Times 0 -Exactly -ParameterFilter { $Path -like '*/servicePrincipals/plain-1/appRoleAssignedTo*' }
        }
    }

    It 'reports an unresolvable app role as null, not as a non-risky permission' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*servicePrincipals?$select*') {
                    @(
                        [pscustomobject]@{ id = 'client-1'; displayName = 'Contoso App'; appRoles = @() }
                        [pscustomobject]@{ id = 'res-1'; displayName = 'Microsoft Graph'
                                           appRoles = @([pscustomobject]@{ id = 'role-1'; value = 'Mail.Read' }) }
                    )
                }
                elseif ($Path -like '*appRoleAssignedTo*') {
                    # A grant naming a role the resource no longer publishes - a real state.
                    @([pscustomobject]@{ id = 'a1'; appRoleId = 'role-GONE'; principalId = 'client-1'
                                         principalType = 'ServicePrincipal'; principalDisplayName = 'Contoso App' })
                }
                else { @() }
            }
            Get-MsecEntraAppConsent -PermissionType Application
        }

        $rows.Count | Should -Be 1
        $rows[0].Permission | Should -BeNullOrEmpty
        # $false would assert it was checked against the list and found safe.
        $rows[0].IsHighRisk | Should -BeNullOrEmpty
    }

    It 'reports a resource whose assignments cannot be read instead of dropping it' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*servicePrincipals?$select*') {
                    @([pscustomobject]@{ id = 'res-1'; appId = 'app-r'; displayName = 'Locked API'
                                         appRoles = @([pscustomobject]@{ id = 'role-1'; value = 'Mail.Read' }) })
                }
                elseif ($Path -like '*appRoleAssignedTo*') { throw 'Insufficient privileges' }
                else { @() }
            }
            Get-MsecEntraAppConsent -PermissionType Application -WarningAction SilentlyContinue
        }

        $rows.Count | Should -Be 1
        $rows[0].ClientDisplayName | Should -Be 'Unreadable'
        $rows[0].ResourceDisplayName | Should -Be 'Locked API'
        $rows[0].IsHighRisk | Should -BeNullOrEmpty
    }

    It 'keeps an app of unknown ownership under -ThirdPartyOnly' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*servicePrincipals?$select*') {
                    @(
                        [pscustomobject]@{ id = 'ms-1'; displayName = 'A Microsoft app'; appRoles = @()
                                           appOwnerOrganizationId = 'f8cdef31-a31e-4b4a-93e4-5f571e91255a' }
                        [pscustomobject]@{ id = 'unknown-1'; displayName = 'Unknown owner'; appRoles = @() }
                        [pscustomobject]@{ id = 'res-1'; displayName = 'Microsoft Graph'; appRoles = @() }
                    )
                }
                elseif ($Path -like '*oauth2PermissionGrants*') {
                    @(
                        [pscustomobject]@{ id='g1'; clientId='ms-1';      resourceId='res-1'; consentType='AllPrincipals'; scope='Mail.Read' }
                        [pscustomobject]@{ id='g2'; clientId='unknown-1'; resourceId='res-1'; consentType='AllPrincipals'; scope='Mail.Read' }
                    )
                }
                else { @() }
            }
            Get-MsecEntraAppConsent -PermissionType Delegated -ThirdPartyOnly
        }

        # An unresolved owner is not evidence of a Microsoft app, so it must survive the filter.
        $rows.Count | Should -Be 1
        $rows[0].ClientDisplayName | Should -Be 'Unknown owner'
        $rows[0].ClientIsMicrosoft | Should -BeNullOrEmpty
    }

    It 'warns rather than returning silence when delegated grants cannot be read' {
        $warnings = @()
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*servicePrincipals?$select*') { @([pscustomobject]@{ id = 'res-1'; displayName = 'x'; appRoles = @() }) }
                elseif ($Path -like '*oauth2PermissionGrants*') { throw 'Insufficient privileges to complete the operation.' }
                else { @() }
            }
            Get-MsecEntraAppConsent -PermissionType Delegated -WarningVariable w -WarningAction SilentlyContinue
            $script:capturedWarnings = $w
        }
        $captured = InModuleScope Msec { $script:capturedWarnings }

        # An empty result with no warning would read as a tenant with no delegated consent.
        $rows | Should -BeNullOrEmpty
        "$captured" | Should -Match 'not the same as a tenant with none'
    }
}
