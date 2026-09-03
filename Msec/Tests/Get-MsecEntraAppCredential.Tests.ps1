#Requires -Module Pester
#
# Tests for Get-MsecEntraAppCredential.
#
# The behaviour worth pinning down is where the obvious implementation is wrong:
#
#   * one row per CREDENTIAL, not per app - rolling up per app hides the secret that
#     lapses on Friday behind the two that are good for a year
#   * an already-expired credential survives ANY -ExpiringWithinDays window, because
#     expired is strictly worse than expiring and a window that dropped it would report
#     the opposite of the truth
#   * IsExpired comes from the timestamps, NOT from the floored day count - a credential
#     with nine hours left floors to 0, and 0 must not read as expired
#   * an app with no credentials is reported (usually the good state, e.g. federated
#     credentials) but a service principal with none is not - a tenant holds hundreds of
#     Microsoft-owned ones and they would bury everything else

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEntraAppCredential' {
    BeforeEach {
        InModuleScope Msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId = 'tenant'; ClientId = 'client'; KeyVaultName = 'kv-test'
                KeyName = 'msec-app'; ThumbprintBytes = $Thumb; Tokens = @{}
            }
        }
    }

    It 'emits one row per credential, splitting secrets from certificates' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/applications' } -MockWith {
                $now = [DateTime]::UtcNow
                [pscustomobject]@{
                    id = 'obj-1'; appId = 'app-1'; displayName = 'Billing sync'
                    createdDateTime = '2024-01-01T00:00:00Z'; signInAudience = 'AzureADMyOrg'
                    passwordCredentials = @(
                        [pscustomobject]@{ keyId = 'k1'; displayName = 'rotate-me'; startDateTime = $now.AddDays(-100).ToString('o'); endDateTime = $now.AddDays(10).ToString('o') }
                        [pscustomobject]@{ keyId = 'k2'; displayName = 'spare';     startDateTime = $now.AddDays(-10).ToString('o');  endDateTime = $now.AddDays(300).ToString('o') }
                    )
                    keyCredentials = @(
                        [pscustomobject]@{ keyId = 'k3'; displayName = 'signing'; usage = 'Sign'; startDateTime = $now.AddDays(-5).ToString('o'); endDateTime = $now.AddDays(400).ToString('o') }
                    )
                }
            }
            Get-MsecEntraAppCredential
        }

        # Three credentials on one app is three rows. One row per app would have to pick
        # a single expiry, and any pick is wrong for the other two.
        @($rows).Count | Should -Be 3
        @($rows | Where-Object CredentialType -eq 'Secret').Count      | Should -Be 2
        @($rows | Where-Object CredentialType -eq 'Certificate').Count | Should -Be 1

        # App-level fields ride along on every row, so a row stands alone.
        @($rows | Where-Object DisplayName -eq 'Billing sync').Count | Should -Be 3
        ($rows | Where-Object KeyId -eq 'k1').AppId          | Should -Be 'app-1'
        ($rows | Where-Object KeyId -eq 'k1').SignInAudience | Should -Be 'AzureADMyOrg'

        # Usage tells a SAML signing cert from one used to authenticate as the app, and
        # is meaningless on a secret rather than blank-by-accident.
        ($rows | Where-Object KeyId -eq 'k3').CredentialUsage | Should -Be 'Sign'
        ($rows | Where-Object KeyId -eq 'k1').CredentialUsage | Should -BeNullOrEmpty

        # The security half, not the outage half: a 110-day secret next to a 405-day cert.
        ($rows | Where-Object KeyId -eq 'k1').LifetimeDays | Should -Be 110
        ($rows | Where-Object KeyId -eq 'k3').LifetimeDays | Should -Be 405
    }

    It 'does not call a credential with hours left expired' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/applications' } -MockWith {
                $now = [DateTime]::UtcNow
                [pscustomobject]@{
                    id = 'obj-1'; appId = 'app-1'; displayName = 'Edge case'
                    passwordCredentials = @(
                        # Nine hours left. Floors to 0 - and 0 must not read as expired.
                        [pscustomobject]@{ keyId = 'soon';    startDateTime = $now.AddDays(-30).ToString('o'); endDateTime = $now.AddHours(9).ToString('o') }
                        # Two hours GONE. Floors to -1, and is genuinely expired.
                        [pscustomobject]@{ keyId = 'lapsed';  startDateTime = $now.AddDays(-30).ToString('o'); endDateTime = $now.AddHours(-2).ToString('o') }
                    )
                    keyCredentials = @()
                }
            }
            Get-MsecEntraAppCredential
        }

        $soon = $rows | Where-Object KeyId -eq 'soon'
        $soon.DaysUntilExpiry | Should -Be 0
        $soon.IsExpired       | Should -BeFalse    # the whole point of this test

        $lapsed = $rows | Where-Object KeyId -eq 'lapsed'
        $lapsed.IsExpired       | Should -BeTrue
        $lapsed.DaysUntilExpiry | Should -BeLessThan 0
    }

    It 'keeps expired credentials inside any -ExpiringWithinDays window' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/applications' } -MockWith {
                $now = [DateTime]::UtcNow
                [pscustomobject]@{
                    id = 'obj-1'; appId = 'app-1'; displayName = 'Windowed'
                    passwordCredentials = @(
                        [pscustomobject]@{ keyId = 'long-dead'; startDateTime = $now.AddDays(-800).ToString('o'); endDateTime = $now.AddDays(-400).ToString('o') }
                        [pscustomobject]@{ keyId = 'due-soon';  startDateTime = $now.AddDays(-100).ToString('o'); endDateTime = $now.AddDays(20).ToString('o') }
                        [pscustomobject]@{ keyId = 'healthy';   startDateTime = $now.AddDays(-10).ToString('o');  endDateTime = $now.AddDays(300).ToString('o') }
                    )
                    keyCredentials = @()
                }
            }
            Get-MsecEntraAppCredential -ExpiringWithinDays 30
        }

        # A credential that lapsed 400 days ago is not less urgent than one lapsing next
        # week. Filtering it out on the grounds that -400 is outside a 30-day window would
        # report the opposite of the truth.
        @($rows | ForEach-Object KeyId) | Should -Contain 'long-dead'
        @($rows | ForEach-Object KeyId) | Should -Contain 'due-soon'
        @($rows | ForEach-Object KeyId) | Should -Not -Contain 'healthy'
    }

    It 'reports an app with no credentials, because that is usually the good state' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/applications' } -MockWith {
                [pscustomobject]@{ id = 'obj-fed'; appId = 'app-fed'; displayName = 'Workload identity'
                                   passwordCredentials = @(); keyCredentials = @() }
            }
            Get-MsecEntraAppCredential
        }

        @($rows).Count | Should -Be 1
        $rows[0].CredentialType  | Should -Be 'None'
        # Not 0 and not $false - there is no expiry to report, and a zero would sort into
        # the "expires today" rows and read as an emergency.
        $rows[0].DaysUntilExpiry | Should -BeNullOrEmpty
        $rows[0].IsExpired       | Should -BeNullOrEmpty
        $rows[0].EndDateTime     | Should -BeNullOrEmpty

        # ...but it has no expiry, so a window is not about it.
        $windowed = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/applications' } -MockWith {
                [pscustomobject]@{ id = 'obj-fed'; appId = 'app-fed'; displayName = 'Workload identity'
                                   passwordCredentials = @(); keyCredentials = @() }
            }
            Get-MsecEntraAppCredential -ExpiringWithinDays 90
        }
        @($windowed).Count | Should -Be 0
    }

    It 'skips service principals holding no credentials, and only when asked at all' {
        $default = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/applications' } -MockWith {
                [pscustomobject]@{ id = 'obj-1'; appId = 'app-1'; displayName = 'App'
                                   passwordCredentials = @([pscustomobject]@{ keyId = 'k1'; endDateTime = [DateTime]::UtcNow.AddDays(5).ToString('o') })
                                   keyCredentials = @() }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/servicePrincipals' } -MockWith {
                throw 'servicePrincipals must not be called without -IncludeServicePrincipal'
            }
            Get-MsecEntraAppCredential
        }
        @($default).Count | Should -Be 1

        $withSp = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/applications' } -MockWith {
                [pscustomobject]@{ id = 'obj-1'; appId = 'app-1'; displayName = 'App'
                                   passwordCredentials = @([pscustomobject]@{ keyId = 'k1'; endDateTime = [DateTime]::UtcNow.AddDays(5).ToString('o') })
                                   keyCredentials = @() }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/servicePrincipals' } -MockWith {
                # The SAML app whose signing cert is a sign-in outage for every user of it.
                [pscustomobject]@{ id = 'sp-1'; appId = 'app-saml'; displayName = 'HR portal'
                                   passwordCredentials = @()
                                   keyCredentials = @([pscustomobject]@{ keyId = 'sign-1'; usage = 'Sign'; endDateTime = [DateTime]::UtcNow.AddDays(45).ToString('o') }) }
                # Three of the hundreds Microsoft owns. Reporting these would bury the one above.
                [pscustomobject]@{ id = 'sp-2'; appId = 'ms-1'; displayName = 'Microsoft Graph';        passwordCredentials = @(); keyCredentials = @() }
                [pscustomobject]@{ id = 'sp-3'; appId = 'ms-2'; displayName = 'Office 365 Exchange';   passwordCredentials = @(); keyCredentials = @() }
                [pscustomobject]@{ id = 'sp-4'; appId = 'ms-3'; displayName = 'Windows Azure Service'; passwordCredentials = @(); keyCredentials = @() }
            }
            Get-MsecEntraAppCredential -IncludeServicePrincipal
        }

        @($withSp).Count | Should -Be 2       # the app registration and the SAML cert, not the three empties
        $saml = $withSp | Where-Object ObjectType -eq 'ServicePrincipal'
        $saml.DisplayName     | Should -Be 'HR portal'
        $saml.CredentialUsage | Should -Be 'Sign'
        # signInAudience belongs to the registration, not the tenant-local object, so it is
        # left out of the $select rather than asked for and returned null.
        $saml.SignInAudience  | Should -BeNullOrEmpty
    }

    It 'names the missing permission on a 403 rather than passing the raw error up' {
        InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            { Get-MsecEntraAppCredential } | Should -Throw '*Application.Read.All*'
        }
    }

    It 'throws a clear error when not connected' {
        InModuleScope Msec {
            $script:MsecSession = $null
            { Get-MsecEntraAppCredential } | Should -Throw '*Connect-Msec*'
        }
    }
}
