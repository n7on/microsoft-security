#Requires -Module Pester
#
# Tests for Get-MsecEntraMfaRegistration. Covers the projection, the array coercion on
# methodsRegistered, and the two DIFFERENT 403s this premium-gated report returns - the
# licensing one must not blame the permission, or it sends people through a consent cycle
# that cannot help.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEntraMfaRegistration' {
    BeforeEach {
        InModuleScope Msec -Parameters @{ Thumb = $script:TestThumbBytes } {
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

    It 'projects each user, keeping IsMfaRegistered and IsMfaCapable distinct' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'userRegistrationDetails' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'u1'; userPrincipalName = 'admin@example.com'; userDisplayName = 'Admin One'
                        userType = 'member'; isAdmin = $true
                        isMfaRegistered = $true; isMfaCapable = $true; isPasswordlessCapable = $true
                        isSsprRegistered = $true; isSsprEnabled = $true; isSsprCapable = $true
                        methodsRegistered = @('microsoftAuthenticatorPush','fido2SecurityKey')
                        # System-preferred is ON, so Entra's ranked choice wins and the
                        # user's own preference ('sms') is what a sign-in would NOT use.
                        userPreferredMethodForSecondaryAuthentication = 'sms'
                        systemPreferredAuthenticationMethods = @('push','sms')
                        isSystemPreferredAuthenticationMethodEnabled = $true
                        lastUpdatedDateTime = '2026-08-01T10:00:00Z'
                    }
                    [pscustomobject]@{
                        # Registered a method the tenant has since DISABLED: registered but
                        # not capable. Counting this as coverage would overstate it.
                        id = 'u2'; userPrincipalName = 'stale@example.com'; userDisplayName = 'Stale'
                        userType = 'member'; isAdmin = $false
                        isMfaRegistered = $true; isMfaCapable = $false; isPasswordlessCapable = $false
                        isSsprRegistered = $false; isSsprEnabled = $false; isSsprCapable = $false
                        methodsRegistered = @('sms')
                        # System-preferred is OFF, so the user's own choice stands.
                        userPreferredMethodForSecondaryAuthentication = 'sms'
                        systemPreferredAuthenticationMethods = @('push')
                        isSystemPreferredAuthenticationMethodEnabled = $false
                        lastUpdatedDateTime = $null
                    }
                    [pscustomobject]@{
                        # Nothing registered: the system has no ranked list to offer even
                        # though the tenant toggle is on, so the user's 'none' is the
                        # only truthful answer.
                        id = 'u3'; userPrincipalName = 'guest@partner.test'; userDisplayName = 'Guest'
                        userType = 'guest'; isAdmin = $false
                        isMfaRegistered = $false; isMfaCapable = $false
                        methodsRegistered = $null
                        userPreferredMethodForSecondaryAuthentication = 'none'
                        systemPreferredAuthenticationMethods = $null
                        isSystemPreferredAuthenticationMethodEnabled = $true
                    }
                ) }
            }

            Get-MsecEntraMfaRegistration
        }

        $rows.Count | Should -Be 3

        $a = $rows | Where-Object UserId -eq 'u1'
        $a.UserPrincipalName     | Should -Be 'admin@example.com'
        $a.UserType              | Should -Be 'member'
        $a.IsAdmin               | Should -BeTrue
        $a.IsMfaCapable          | Should -BeTrue
        $a.IsPasswordlessCapable | Should -BeTrue
        $a.MethodsRegistered     | Should -Contain 'fido2SecurityKey'
        $a.LastUpdatedDateTime   | Should -BeOfType [datetime]

        # There is no defaultMfaMethod field in Graph v1.0 - the effective default is
        # derived. With system-preferred ON, Entra's ranked first choice wins and the
        # user's own 'sms' preference is NOT what a sign-in would prompt for. Reading
        # the user field alone would report this admin as phishable when they are not.
        $a.DefaultMfaMethod            | Should -Be 'push'
        $a.UserPreferredMfaMethod      | Should -Be 'sms'
        $a.SystemPreferredMfaMethods   | Should -Contain 'push'
        $a.IsSystemPreferredMfaEnabled | Should -BeTrue
        $a.Raw.id                | Should -Be 'u1'
        $a.PSObject.TypeNames    | Should -Contain 'MsecEntraMfaRegistration'

        # The distinction that drives coverage reporting.
        $b = $rows | Where-Object UserId -eq 'u2'
        $b.IsMfaRegistered | Should -BeTrue
        $b.IsMfaCapable    | Should -BeFalse

        # System-preferred OFF: the user's own choice stands, even though Entra has a
        # stronger one on file. Reading the system list alone would report this user as
        # using push when every sign-in actually prompts for SMS.
        $b.DefaultMfaMethod            | Should -Be 'sms'
        $b.SystemPreferredMfaMethods   | Should -Contain 'push'
        $b.IsSystemPreferredMfaEnabled | Should -BeFalse

        # Missing methodsRegistered coerces to an empty ARRAY, not $null - a scriptblock
        # returning @() emits nothing and lands as $null unless comma-wrapped.
        $c = $rows | Where-Object UserId -eq 'u3'
        ($c.MethodsRegistered -is [array]) | Should -BeTrue
        $c.MethodsRegistered.Count         | Should -Be 0

        # System-preferred is ON but the ranked list is empty - nothing is registered.
        # Indexing [0] into that would throw or yield $null; the user's own 'none' is
        # both truthful and the more useful answer.
        $c.DefaultMfaMethod          | Should -Be 'none'
        # An empty array rather than $null, so -contains and .Count stay safe. Tested
        # with -is rather than a pipeline, which would unroll the empty array to $null.
        ($c.SystemPreferredMfaMethods -is [array]) | Should -BeTrue
        $c.SystemPreferredMfaMethods.Count         | Should -Be 0
        { $rows | Where-Object MethodsRegistered -contains 'sms' } | Should -Not -Throw
        ($rows | Where-Object MethodsRegistered -contains 'sms').UserId | Should -Be 'u2'
        $c.LastUpdatedDateTime | Should -BeNullOrEmpty
    }

    It 'reads legacy per-user MFA state only when asked, and never touches beta otherwise' {
        $result = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'userRegistrationDetails' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'u1'; userPrincipalName = 'admin@example.com'
                        isAdmin = $true; isMfaRegistered = $true; isMfaCapable = $true
                        userPreferredMethodForSecondaryAuthentication = 'push'
                    }
                    [pscustomobject]@{
                        id = 'u2'; userPrincipalName = 'legacy@example.com'
                        isAdmin = $false; isMfaRegistered = $true; isMfaCapable = $true
                        userPreferredMethodForSecondaryAuthentication = 'sms'
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/beta/users/u1/authentication/requirements' } -MockWith {
                [pscustomobject]@{ perUserMfaState = 'enforced' }
            }
            # One user's state is unreadable: the other rows must still come back, and
            # the run must say so rather than pass $null off as 'disabled'.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/beta/users/u2/authentication/requirements' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }

            $off = @(Get-MsecEntraMfaRegistration)
            # Default must make NO beta calls at all - it is an unsupported API and
            # one request per user, so it cannot be paid for silently.
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -match '/beta/' }

            $warnings = @()
            $on = @(Get-MsecEntraMfaRegistration -IncludePerUserMfaState -WarningVariable warnings -WarningAction SilentlyContinue)
            [pscustomobject]@{ Off = $off; On = $on; Warnings = @($warnings) }
        }

        # The property exists either way, so the shape does not change with the switch.
        $result.Off[0].PSObject.Properties.Name | Should -Contain 'PerUserMfaState'
        $result.Off[0].PerUserMfaState          | Should -BeNullOrEmpty

        # An 'enforced' user is challenged whatever Conditional Access says - the fact
        # that no other report in this module can see.
        ($result.On | Where-Object UserId -eq 'u1').PerUserMfaState | Should -Be 'enforced'

        # A failed read stays $null, and is counted rather than mistaken for 'disabled'.
        ($result.On | Where-Object UserId -eq 'u2').PerUserMfaState | Should -BeNullOrEmpty
        ($result.Warnings -join ' ') | Should -Match '1 user'
    }

    It 'retries a throttled per-user call instead of reporting it as unreadable' {
        # A one-call-per-user loop is exactly what Graph throttles. Before this, a 429
        # was caught and turned into $null - so a large tenant came back with mostly
        # empty states and a warning, which reads as a missing permission rather than
        # as backpressure.
        $result = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            # Never actually wait in a test; only prove the wait was asked for.
            Mock Start-Sleep -MockWith { }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'userRegistrationDetails' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'u1'; userPrincipalName = 'admin@example.com'; isAdmin = $true }
                ) }
            }

            $script:ThrottleCalls = 0
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/beta/users/u1/authentication/requirements' } -MockWith {
                $script:ThrottleCalls++
                if ($script:ThrottleCalls -lt 3) {
                    throw 'Response status code does not indicate success: 429 (Too Many Requests).'
                }
                [pscustomobject]@{ perUserMfaState = 'enabled' }
            }

            $warnings = @()
            $rows = @(Get-MsecEntraMfaRegistration -IncludePerUserMfaState -WarningVariable warnings -WarningAction SilentlyContinue)
            [pscustomobject]@{ Rows = $rows; Warnings = @($warnings); Calls = $script:ThrottleCalls }
        }

        # Two 429s, then the real answer - and the answer is what lands on the row.
        $result.Calls                  | Should -Be 3
        $result.Rows[0].PerUserMfaState | Should -Be 'enabled'
        # Nothing to warn about: backpressure is not a failure.
        $result.Warnings.Count         | Should -Be 0
    }

    It 'gives up on a persistently throttled call rather than retrying forever' {
        $result = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Start-Sleep -MockWith { }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'userRegistrationDetails' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'u1'; userPrincipalName = 'admin@example.com' }
                ) }
            }
            $script:AlwaysThrottled = 0
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/beta/users/u1/authentication/requirements' } -MockWith {
                $script:AlwaysThrottled++
                throw 'Response status code does not indicate success: 429 (Too Many Requests).'
            }

            $warnings = @()
            $rows = @(Get-MsecEntraMfaRegistration -IncludePerUserMfaState -WarningVariable warnings -WarningAction SilentlyContinue)
            [pscustomobject]@{ Rows = $rows; Warnings = @($warnings); Calls = $script:AlwaysThrottled }
        }

        # Bounded: 5 attempts, not an infinite loop, and the row still comes back.
        $result.Calls                   | Should -Be 5
        $result.Rows.Count              | Should -Be 1
        $result.Rows[0].PerUserMfaState  | Should -BeNullOrEmpty
        ($result.Warnings -join ' ')     | Should -Match '1 user'
    }

    It 'rewrites a bare 403 to mention the missing AuditLog.Read.All permission' {
        InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'userRegistrationDetails' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }

            { Get-MsecEntraMfaRegistration } | Should -Throw -ExpectedMessage '*AuditLog.Read.All*'
        }
    }

    It 'identifies the premium-licensing 403 and does NOT blame the permission' {
        InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'userRegistrationDetails' } -MockWith {
                $body = '{"error":{"code":"Authentication_RequestFromUnsupportedUserRole","message":"Tenant is not a B2C tenant and doesn''t have premium license"}}'
                $ex   = [System.Exception]::new('Response status code does not indicate success: 403 (Forbidden).')
                $rec  = [System.Management.Automation.ErrorRecord]::new($ex, 'HttpResponse403', 'PermissionDenied', $null)
                $rec.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($body)
                throw $rec
            }

            $msg = try { Get-MsecEntraMfaRegistration; $null } catch { $_.Exception.Message }

            $msg | Should -BeLike '*premium license*'
            $msg | Should -BeLike '*LICENSING limit*'
            $msg | Should -BeLike '*will not change it*'
            $msg | Should -BeLike '*not measurable in this tenant*'
        }
    }
}
