#Requires -Module Pester
#
# Tests for Get-MsecEntraTenantSecuritySetting. The behaviour that matters most is
# the one this cmdlet exists for: telling "the tenant isn't licensed for this"
# apart from "we couldn't read it". A read that succeeds and finds no premium
# licence must report ConditionalAccessAvailable = $false (a real answer); a read
# that FAILS must report $null plus a reason in Notes - never $false, which would
# assert something unmeasured.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEntraTenantSecuritySetting' {
    BeforeEach {
        InModuleScope msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId        = 'tenant-abc'
                ClientId        = 'client'
                KeyVaultName    = 'kv-test'
                KeyName         = 'msec-app'
                ThumbprintBytes = $Thumb
                Tokens          = @{}
            }
        }
    }

    It 'summarises a premium tenant: CA available, security defaults off, admins counted' {
        $s = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'identitySecurityDefaultsEnforcementPolicy' } -MockWith {
                # Security defaults are mutually exclusive with CA - off is correct here.
                [pscustomobject]@{ isEnabled = $false }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/policies/authorizationPolicy' } -MockWith {
                [pscustomobject]@{
                    guestUserRoleId = '10dae51f-b6af-4016-8d66-8c2a99b929b3'
                    allowInvitesFrom = 'adminsAndGuestInviters'
                    allowEmailVerifiedUsersToJoinOrganization = $false
                    defaultUserRolePermissions = [pscustomobject]@{
                        allowedToCreateApps           = $false
                        allowedToCreateSecurityGroups = $false
                        allowedToReadOtherUsers       = $true
                    }
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/subscribedSkus' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        skuId = 'sku-e5'; skuPartNumber = 'SPE_E5'; capabilityStatus = 'Enabled'
                        consumedUnits = 18
                        prepaidUnits = [pscustomobject]@{ enabled = 20; warning = 0; suspended = 0 }
                        servicePlans = @(
                            [pscustomobject]@{ servicePlanName = 'AAD_PREMIUM';        provisioningStatus = 'Success' }
                            [pscustomobject]@{ servicePlanName = 'AAD_PREMIUM_P2';     provisioningStatus = 'Success' }
                            [pscustomobject]@{ servicePlanName = 'INTUNE_A';           provisioningStatus = 'Success' }
                            [pscustomobject]@{ servicePlanName = 'EXCHANGE_S_ENTERPRISE'; provisioningStatus = 'Success' }
                            [pscustomobject]@{ servicePlanName = 'WINDEFATP';          provisioningStatus = 'Success' }
                            [pscustomobject]@{ servicePlanName = 'ATP_ENTERPRISE';     provisioningStatus = 'Success' }
                        )
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'role-ga'; displayName = 'Global Administrator'
                                       templateId = '62e90394-69f5-4237-9190-012177145e10'; isBuiltIn = $true }
                    [pscustomobject]@{ id = 'role-sec'; displayName = 'Security Administrator'
                                       templateId = '194ae4cb-b126-40b2-bd5b-6091b380977d'; isBuiltIn = $true }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleAssignments' } -MockWith {
                $u1 = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'; userPrincipalName = 'a@x.com' }
                $u2 = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u2'; userPrincipalName = 'b@x.com' }
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'as1'; roleDefinitionId = 'role-ga';  principalId = 'u1'; directoryScopeId = '/'; principal = $u1 }
                    [pscustomobject]@{ id = 'as2'; roleDefinitionId = 'role-ga';  principalId = 'u2'; directoryScopeId = '/'; principal = $u2 }
                    # u1 is ALSO a Security Admin - the distinct-principal count must not double-count.
                    [pscustomobject]@{ id = 'as3'; roleDefinitionId = 'role-sec'; principalId = 'u1'; directoryScopeId = '/'; principal = $u1 }
                ) }
            }

            Get-MsecEntraTenantSecuritySetting
        }

        $s.TenantId                        | Should -Be 'tenant-abc'
        $s.SecurityDefaultsEnabled         | Should -BeFalse

        $s.EntraIdPremium                  | Should -Be 'P2'
        $s.ConditionalAccessAvailable      | Should -BeTrue
        $s.IdentityProtectionAvailable     | Should -BeTrue
        $s.PimAvailable                    | Should -BeTrue
        $s.IntuneProvisioned               | Should -BeTrue
        $s.ExchangeOnlineProvisioned       | Should -BeTrue
        $s.DefenderForEndpointProvisioned  | Should -BeTrue
        $s.DefenderForOffice365Provisioned | Should -BeTrue
        $s.LicensedSkuCount                | Should -Be 1

        $s.DefaultUserRoleCanCreateApps    | Should -BeFalse
        $s.GuestUserRole                   | Should -Be 'Guest'
        $s.AllowInvitesFrom                | Should -Be 'adminsAndGuestInviters'

        $s.GlobalAdministratorCount        | Should -Be 2
        # 3 role memberships across 2 distinct people.
        $s.HighlyPrivilegedMemberCount     | Should -Be 2
        $s.ActivatedRoleCount              | Should -Be 2
        ($s.PrivilegedRoleSummary | Where-Object RoleName -eq 'Global Administrator').MemberCount | Should -Be 2

        $s.Notes.Count                     | Should -Be 0
        $s.PSObject.TypeNames              | Should -Contain 'MsecEntraTenantSecuritySetting'
    }

    It 'reports an unlicensed tenant as a real answer: CA unavailable, not unknown' {
        $s = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'identitySecurityDefaultsEnforcementPolicy' } -MockWith {
                [pscustomobject]@{ isEnabled = $true }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/policies/authorizationPolicy' } -MockWith {
                [pscustomobject]@{ defaultUserRolePermissions = [pscustomobject]@{ allowedToCreateApps = $true } }
            }
            # An Azure-infrastructure tenant: a couple of unrelated SKUs, no premium.
            # EXCHANGE_S_FOUNDATION rides along with Power BI Standard and must NOT be
            # read as a mail estate - it grants no mailboxes.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/subscribedSkus' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        skuId = 'sku-pbi'; skuPartNumber = 'POWER_BI_STANDARD'; consumedUnits = 2
                        prepaidUnits = [pscustomobject]@{ enabled = 1000000 }
                        servicePlans = @(
                            [pscustomobject]@{ servicePlanName = 'BI_AZURE_P0';           provisioningStatus = 'Success' }
                            [pscustomobject]@{ servicePlanName = 'EXCHANGE_S_FOUNDATION'; provisioningStatus = 'Success' }
                        )
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'role-ga'; displayName = 'Global Administrator'
                                       templateId = '62e90394-69f5-4237-9190-012177145e10'; isBuiltIn = $true }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    1..6 | ForEach-Object {
                        $p = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'
                                                id = "u$_"; userPrincipalName = "admin$_@x.com" }
                        [pscustomobject]@{ id = "as$_"; roleDefinitionId = 'role-ga'
                                           principalId = "u$_"; directoryScopeId = '/'; principal = $p }
                    }
                ) }
            }

            Get-MsecEntraTenantSecuritySetting
        }

        # These are measured facts, not unknowns - so $false, never $null.
        $s.ConditionalAccessAvailable | Should -BeFalse
        $s.ConditionalAccessAvailable | Should -Not -BeNullOrEmpty -Because 'a read that succeeded must not look unmeasured'
        $s.EntraIdPremium             | Should -BeNullOrEmpty
        $s.IntuneProvisioned          | Should -BeFalse
        $s.PimAvailable               | Should -BeFalse
        # The bundled stub plan must NOT count as a mail estate, or an absent emailStats
        # domain would be reported as a fault to fix instead of as not-applicable.
        $s.ServicePlans               | Should -Contain 'EXCHANGE_S_FOUNDATION'
        $s.ExchangeOnlineProvisioned  | Should -BeFalse -Because 'EXCHANGE_S_FOUNDATION grants no mailboxes'

        # Security defaults carry the whole MFA story in a tenant with no CA.
        $s.SecurityDefaultsEnabled    | Should -BeTrue
        $s.GlobalAdministratorCount   | Should -Be 6
        $s.Notes.Count                | Should -Be 0
    }

    It 'degrades a failed section to $null + a Notes reason instead of throwing' {
        $s = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'identitySecurityDefaultsEnforcementPolicy' } -MockWith {
                [pscustomobject]@{ isEnabled = $false }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/policies/authorizationPolicy' } -MockWith {
                [pscustomobject]@{ defaultUserRolePermissions = [pscustomobject]@{ allowedToCreateApps = $false } }
            }
            # Licences unreadable - the app is missing Organization.Read.All.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/subscribedSkus' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'role-ga'; displayName = 'Global Administrator'
                                       templateId = '62e90394-69f5-4237-9190-012177145e10'; isBuiltIn = $true }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleAssignments' } -MockWith {
                $u1 = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'; userPrincipalName = 'a@x.com' }
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'as1'; roleDefinitionId = 'role-ga'; principalId = 'u1'
                                       directoryScopeId = '/'; principal = $u1 }
                ) }
            }

            Get-MsecEntraTenantSecuritySetting
        }

        # Unmeasured is $null - crucially NOT $false, which would claim CA is unavailable.
        $s.ConditionalAccessAvailable | Should -BeNullOrEmpty
        $s.IntuneProvisioned          | Should -BeNullOrEmpty
        $s.ServicePlans               | Should -BeNullOrEmpty
        $s.LicensedSkuCount           | Should -BeNullOrEmpty

        # ...and the reason is recorded, naming the permission to grant.
        $s.Notes.Contains('licenses')  | Should -BeTrue
        $s.Notes['licenses']           | Should -BeLike '*Organization.Read.All*'

        # Sections that DID read still carry real values.
        $s.SecurityDefaultsEnabled    | Should -BeFalse
        $s.GlobalAdministratorCount   | Should -Be 1
    }

    It 'counts Global Admins when Graph calls the role by its legacy name' {
        # REGRESSION. Graph returns Global Administrator as 'Company Administrator' on a
        # great many tenants, and this count used to be `RoleName -eq 'Global
        # Administrator'` - which reported ZERO Global Admins on every one of them, in
        # the headline column of this report. The template id is identical everywhere.
        $s = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'identitySecurityDefaultsEnforcementPolicy' } -MockWith {
                [pscustomobject]@{ isEnabled = $false }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/policies/authorizationPolicy' } -MockWith {
                [pscustomobject]@{ defaultUserRolePermissions = [pscustomobject]@{ allowedToCreateApps = $false } }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/subscribedSkus' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/organization' } -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ id = 'tenant-abc'; displayName = 'Contoso' }) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    # The legacy display name, as Graph is observed to return for this role.
                    [pscustomobject]@{ id = 'role-ga'; displayName = 'Company Administrator'
                                       templateId = '62e90394-69f5-4237-9190-012177145e10'; isBuiltIn = $true }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    1..3 | ForEach-Object {
                        $p = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'
                                                id = "u$_"; userPrincipalName = "u$_@x.com" }
                        [pscustomobject]@{ id = "as$_"; roleDefinitionId = 'role-ga'
                                           principalId = "u$_"; directoryScopeId = '/'; principal = $p }
                    }
                ) }
            }

            Get-MsecEntraTenantSecuritySetting
        }

        $s.GlobalAdministratorCount    | Should -Be 3 -Because 'the count must key on roleTemplateId, not the display name'
        $s.HighlyPrivilegedMemberCount | Should -Be 3
        $s.ActivatedRoleCount          | Should -Be 1
        # The report still shows the name the directory actually uses, rather than
        # silently substituting a friendlier one.
        ($s.PrivilegedRoleSummary | Where-Object RoleName -eq 'Company Administrator').MemberCount | Should -Be 3
    }

    It 'counts a role held by a GROUP as one privileged principal' {
        # /directoryRoles does not expand groups, so the group is the assignee and the
        # holder is unknown. The count must come from PrincipalId - EffectiveId is $null
        # on exactly these rows and would silently drop them.
        $s = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'identitySecurityDefaultsEnforcementPolicy' } -MockWith {
                [pscustomobject]@{ isEnabled = $false }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/policies/authorizationPolicy' } -MockWith {
                [pscustomobject]@{ defaultUserRolePermissions = [pscustomobject]@{ allowedToCreateApps = $false } }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/subscribedSkus' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/organization' } -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ id = 'tenant-abc' }) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'role-ga'; displayName = 'Company Administrator'
                                       templateId = '62e90394-69f5-4237-9190-012177145e10'; isBuiltIn = $true }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleAssignments' } -MockWith {
                $u1 = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user';  id = 'u1'; userPrincipalName = 'a@x.com' }
                $g1 = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; id = 'g1'; displayName = 'sg-admins' }
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'as1'; roleDefinitionId = 'role-ga'; principalId = 'u1'; directoryScopeId = '/'; principal = $u1 }
                    [pscustomobject]@{ id = 'as2'; roleDefinitionId = 'role-ga'; principalId = 'g1'; directoryScopeId = '/'; principal = $g1 }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/transitiveMembers' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/transitiveMembers/microsoft\.graph\.user' } -MockWith {
                [pscustomobject]@{ value = @(
                    # u1 is BOTH directly assigned and in the group - one administrator.
                    [pscustomobject]@{ id = 'u1'; userPrincipalName = 'a@x.com' }
                    [pscustomobject]@{ id = 'u2'; userPrincipalName = 'b@x.com' }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'eligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            Get-MsecEntraTenantSecuritySetting -WarningAction SilentlyContinue
        }

        # Two PEOPLE, not two assignments and not one group: the group is expanded, and
        # u1 - directly assigned AND inside the group - counts once. The older
        # /directoryRoles view reported this tenant as 1 user + 1 opaque group.
        $s.GlobalAdministratorCount    | Should -Be 2
        $s.HighlyPrivilegedMemberCount | Should -Be 2
        ($s.PrivilegedRoleSummary | Where-Object RoleName -eq 'Company Administrator').MemberCount | Should -Be 2
    }

    It 'counts an unexpandable group as one principal rather than dropping it' {
        # Whoever can write that group's membership can take the role tomorrow, so the
        # assignment must survive into the count even with no holder resolved.
        $s = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'identitySecurityDefaultsEnforcementPolicy' } -MockWith {
                [pscustomobject]@{ isEnabled = $false }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/policies/authorizationPolicy' } -MockWith {
                [pscustomobject]@{ defaultUserRolePermissions = [pscustomobject]@{ allowedToCreateApps = $false } }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/subscribedSkus' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/organization' } -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ id = 'tenant-abc' }) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'role-ga'; displayName = 'Global Administrator'
                                       templateId = '62e90394-69f5-4237-9190-012177145e10'; isBuiltIn = $true }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleAssignments' } -MockWith {
                $g1 = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; id = 'g1'; displayName = 'sg-admins' }
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'as1'; roleDefinitionId = 'role-ga'; principalId = 'g1'; directoryScopeId = '/'; principal = $g1 }
                ) }
            }
            # Group.Read.All missing: no cast succeeds, and PIM-for-groups fails too.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/transitiveMembers' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'eligibilityScheduleInstances' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }

            Get-MsecEntraTenantSecuritySetting -WarningAction SilentlyContinue
        }

        $s.GlobalAdministratorCount    | Should -Be 1 -Because 'an unresolved group assignment is still a privilege path'
        $s.HighlyPrivilegedMemberCount | Should -Be 1
    }

    It 'rethrows the annotated error under -Strict' {
        InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'identitySecurityDefaultsEnforcementPolicy' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }

            { Get-MsecEntraTenantSecuritySetting -Strict } |
                Should -Throw -ExpectedMessage '*Policy.Read.All*'
        }
    }
}
