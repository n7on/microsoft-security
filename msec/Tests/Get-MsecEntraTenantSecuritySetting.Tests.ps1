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
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles$' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'role-ga'; displayName = 'Global Administrator'
                                       roleTemplateId = '62e90394-69f5-4237-9190-012177145e10' }
                    [pscustomobject]@{ id = 'role-sec'; displayName = 'Security Administrator'
                                       roleTemplateId = '194ae4cb-b126-40b2-bd5b-6091b380977d' }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles/role-ga/members' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'; userPrincipalName = 'a@x.com' }
                    [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u2'; userPrincipalName = 'b@x.com' }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles/role-sec/members' } -MockWith {
                # u1 is ALSO a Security Admin - the distinct-principal count must not double-count.
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'; userPrincipalName = 'a@x.com' }
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
            # read as a mail estate - it grants no mailboxes. This is the real shape of
            # the ViedocProd tenant.
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
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles$' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'role-ga'; displayName = 'Global Administrator'
                                       roleTemplateId = '62e90394-69f5-4237-9190-012177145e10' }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles/role-ga/members' } -MockWith {
                [pscustomobject]@{ value = @(
                    1..6 | ForEach-Object {
                        [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'
                                           id = "u$_"; userPrincipalName = "admin$_@x.com" }
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
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles$' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'role-ga'; displayName = 'Global Administrator'
                                       roleTemplateId = '62e90394-69f5-4237-9190-012177145e10' }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles/role-ga/members' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'; userPrincipalName = 'a@x.com' }
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
