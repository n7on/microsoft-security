#Requires -Module Pester
#
# Tests for Get-MsecEntraDirectoryRoleMember. Verifies the (role x member) fan-out,
# the roleTemplateId-based IsHighlyPrivileged flag (which must survive a renamed
# role), @odata.type normalisation, and that one unreadable role degrades to a
# warning instead of sinking the whole inventory.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEntraDirectoryRoleMember' {
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

    It 'emits one row per role member and flags highly-privileged roles by template id' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles$' } -MockWith {
                [pscustomobject]@{ value = @(
                    # Deliberately RENAMED away from 'Global Administrator' to prove the
                    # privileged flag comes from the template id, not the display name.
                    [pscustomobject]@{
                        id = 'role-ga'; displayName = 'Tenant God Mode'
                        roleTemplateId = '62e90394-69f5-4237-9190-012177145e10'
                    }
                    [pscustomobject]@{
                        id = 'role-reader'; displayName = 'Global Reader'
                        roleTemplateId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles/role-ga/members' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        '@odata.type' = '#microsoft.graph.user'
                        id = 'u1'; displayName = 'Anton'
                        userPrincipalName = 'anton@example.com'; accountEnabled = $true
                    }
                    [pscustomobject]@{
                        '@odata.type' = '#microsoft.graph.servicePrincipal'
                        id = 'sp1'; displayName = 'break-glass-app'
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles/role-reader/members' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        '@odata.type' = '#microsoft.graph.user'
                        id = 'u2'; displayName = 'Auditor'
                        userPrincipalName = 'auditor@example.com'; accountEnabled = $true
                    }
                ) }
            }

            Get-MsecEntraDirectoryRoleMember
        }

        $rows.Count | Should -Be 3

        # Renamed Global Administrator is still flagged, via roleTemplateId.
        $ga = $rows | Where-Object RoleTemplateId -eq '62e90394-69f5-4237-9190-012177145e10'
        $ga.Count | Should -Be 2
        ($ga | Select-Object -Unique IsHighlyPrivileged).IsHighlyPrivileged | Should -BeTrue
        ($ga | Select-Object -Unique RoleName).RoleName | Should -Be 'Tenant God Mode'

        # '@odata.type' is normalised to a bare type name.
        ($ga | Where-Object MemberId -eq 'u1').MemberType  | Should -Be 'user'
        ($ga | Where-Object MemberId -eq 'sp1').MemberType | Should -Be 'servicePrincipal'
        # A service principal has no UPN - that must be $null, not an error.
        ($ga | Where-Object MemberId -eq 'sp1').UserPrincipalName | Should -BeNullOrEmpty

        # Global Reader is read-only and deliberately NOT in the privileged set.
        $reader = $rows | Where-Object RoleName -eq 'Global Reader'
        $reader.IsHighlyPrivileged | Should -BeFalse

        $rows[0].PSObject.TypeNames | Should -Contain 'MsecEntraDirectoryRoleMember'
    }

    It 'filters to privileged roles with -HighlyPrivilegedOnly and skips the members call for the rest' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles$' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'role-ga'; displayName = 'Global Administrator'
                                       roleTemplateId = '62e90394-69f5-4237-9190-012177145e10' }
                    [pscustomobject]@{ id = 'role-reader'; displayName = 'Global Reader'
                                       roleTemplateId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451' }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles/role-ga/members' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'
                                       userPrincipalName = 'anton@example.com'; accountEnabled = $true }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles/role-reader/members' } -MockWith {
                throw 'this non-privileged role should never be fetched'
            }

            Get-MsecEntraDirectoryRoleMember -HighlyPrivilegedOnly
        }

        $rows.Count            | Should -Be 1
        $rows[0].RoleName      | Should -Be 'Global Administrator'
    }

    It 'warns and continues when one role''s members cannot be read' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles$' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'role-ga'; displayName = 'Global Administrator'
                                       roleTemplateId = '62e90394-69f5-4237-9190-012177145e10' }
                    [pscustomobject]@{ id = 'role-bad'; displayName = 'Exchange Administrator'
                                       roleTemplateId = '29232cdf-9323-42fd-ade2-1d097af3e4de' }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles/role-ga/members' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'
                                       userPrincipalName = 'anton@example.com' }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles/role-bad/members' } -MockWith {
                throw 'Response status code does not indicate success: 500 (Internal Server Error).'
            }

            Get-MsecEntraDirectoryRoleMember -WarningAction SilentlyContinue
        }

        # The readable role still comes back; the broken one is simply absent.
        $rows.Count       | Should -Be 1
        $rows[0].RoleName | Should -Be 'Global Administrator'
    }

    It 'rewrites a 403 to mention the missing RoleManagement.Read.Directory permission' {
        InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryRoles' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }

            { Get-MsecEntraDirectoryRoleMember } |
                Should -Throw -ExpectedMessage '*RoleManagement.Read.Directory*'
        }
    }
}
