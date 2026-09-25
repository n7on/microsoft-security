#Requires -Module Pester
#
# Tests for Get-MsecEntraMfaRegistrationStats. The behaviours that matter:
#   - coverage counts IsMfaCapable, not IsMfaRegistered (registered-but-disabled must not
#     be reported as covered)
#   - admins without MFA are counted AND named, since a bare count isn't actionable
#   - PhoneOnlyMfaCapable catches the "100% covered, all of it SMS" case
#   - an empty population yields $null percentages, never 0

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEntraMfaRegistrationStats' {
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

    It 'aggregates coverage, names the admins without MFA, and flags phone-only users' {
        $s = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'userRegistrationDetails' } -MockWith {
                [pscustomobject]@{ value = @(
                    # admin, strong MFA
                    [pscustomobject]@{ id='a1'; userPrincipalName='ga1@x.com'; userType='member'; isAdmin=$true
                                       isMfaRegistered=$true; isMfaCapable=$true; isPasswordlessCapable=$true
                                       isSsprCapable=$true
                                       methodsRegistered=@('microsoftAuthenticatorPush','fido2SecurityKey') }
                    # admin, phone-only MFA - capable, but phishable
                    [pscustomobject]@{ id='a2'; userPrincipalName='ga2@x.com'; userType='member'; isAdmin=$true
                                       isMfaRegistered=$true; isMfaCapable=$true; isPasswordlessCapable=$false
                                       isSsprCapable=$true
                                       methodsRegistered=@('sms','mobilePhone') }
                    # admin, NOTHING registered - the headline finding
                    [pscustomobject]@{ id='a3'; userPrincipalName='breakglass@x.com'; userType='member'; isAdmin=$true
                                       isMfaRegistered=$false; isMfaCapable=$false; isPasswordlessCapable=$false
                                       isSsprCapable=$false
                                       methodsRegistered=@() }
                    # admin, registered but the method is DISABLED by policy -> not capable
                    [pscustomobject]@{ id='a4'; userPrincipalName='stale-admin@x.com'; userType='member'; isAdmin=$true
                                       isMfaRegistered=$true; isMfaCapable=$false; isPasswordlessCapable=$false
                                       isSsprCapable=$false
                                       methodsRegistered=@('sms') }
                    # ordinary member, strong
                    [pscustomobject]@{ id='u1'; userPrincipalName='user1@x.com'; userType='member'; isAdmin=$false
                                       isMfaRegistered=$true; isMfaCapable=$true; isPasswordlessCapable=$false
                                       isSsprCapable=$true
                                       methodsRegistered=@('microsoftAuthenticatorPush') }
                    # guest, no MFA
                    [pscustomobject]@{ id='g1'; userPrincipalName='guest@partner.test'; userType='guest'; isAdmin=$false
                                       isMfaRegistered=$false; isMfaCapable=$false; isPasswordlessCapable=$false
                                       isSsprCapable=$false
                                       methodsRegistered=@() }
                ) }
            }

            Get-MsecEntraMfaRegistrationStats
        }

        $s.TotalUsers | Should -Be 6
        $s.Members    | Should -Be 5
        $s.Guests     | Should -Be 1

        # 5 registered (a1,a2,a4,u1 ... a4 registered but not capable) -> registered 4, capable 3
        $s.MfaRegistered        | Should -Be 4
        $s.MfaCapable           | Should -Be 3
        $s.NotMfaCapable        | Should -Be 3
        $s.MfaCapablePercent    | Should -Be 50.0

        # Admins: 4 total, 2 capable (a1, a2), 2 not (a3, a4)
        $s.AdminTotal             | Should -Be 4
        $s.AdminMfaCapable        | Should -Be 2
        $s.AdminMfaCapablePercent | Should -Be 50.0
        $s.AdminsNotMfaCapable    | Should -Be 2
        # Named, not just counted - a count alone can't be acted on.
        $s.AdminsNotMfaCapableUpn | Should -Be @('breakglass@x.com','stale-admin@x.com')

        # a2 is MFA-capable but only via phone methods.
        $s.PhoneOnlyMfaCapable        | Should -Be 1
        $s.PhoneOnlyMfaCapablePercent | Should -Be 33.33
        # a3's empty method list must NOT satisfy "all methods are phone" vacuously.
        $s.PhoneOnlyMfaCapable        | Should -Not -Be 2

        $s.PasswordlessCapable | Should -Be 1
        $s.GuestsMfaCapable    | Should -Be 0
        $s.SsprCapable         | Should -Be 3   # a1, a2, u1

        # Method mix, users counted once per method they hold.
        $s.ByMethod['microsoftAuthenticatorPush'] | Should -Be 2
        $s.ByMethod['sms']                        | Should -Be 2
        $s.ByMethod['fido2SecurityKey']           | Should -Be 1
    }

    It 'returns null percentages rather than 0 when there are no users' {
        $s = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'userRegistrationDetails' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            Get-MsecEntraMfaRegistrationStats
        }

        $s.TotalUsers             | Should -Be 0
        $s.MfaCapable             | Should -Be 0
        # 0% would read as "measured, nobody covered"; null says "no population".
        $s.MfaCapablePercent      | Should -BeNullOrEmpty
        $s.AdminMfaCapablePercent | Should -BeNullOrEmpty
        $s.AdminsNotMfaCapable    | Should -Be 0
        $s.AdminsNotMfaCapableUpn | Should -BeNullOrEmpty
    }

    It 'scopes the member percentages to members, so guests cannot dilute them' {
        # Measured on a live tenant: 177 members, 202 guests. All-user SSPR coverage read
        # 44.33% against a true member figure of 94.92%, and MFA 61.48% against 95.48%. A
        # guest-heavy tenant is the normal case, not an edge case, so the denominator is
        # the whole finding.
        $s = InModuleScope Msec {
            Mock Get-MsecEntraMfaRegistration -MockWith {
                # 2 members, both covered on everything.
                [pscustomobject]@{ UserType = 'member'; IsMfaCapable = $true;  IsMfaRegistered = $true
                                   IsPasswordlessCapable = $true; IsSsprCapable = $true; IsAdmin = $false
                                   MethodsRegistered = @('fido2SecurityKey') }
                [pscustomobject]@{ UserType = 'member'; IsMfaCapable = $true;  IsMfaRegistered = $true
                                   IsPasswordlessCapable = $true; IsSsprCapable = $true; IsAdmin = $false
                                   MethodsRegistered = @('fido2SecurityKey') }
                # 6 guests. A guest resets their password in their HOME tenant, so none is
                # ever SSPR-capable here - that is structural, not a gap to close.
                1..6 | ForEach-Object {
                    [pscustomobject]@{ UserType = 'guest'; IsMfaCapable = $false; IsMfaRegistered = $false
                                       IsPasswordlessCapable = $false; IsSsprCapable = $false; IsAdmin = $false
                                       MethodsRegistered = @() }
                }
            }
            Get-MsecEntraMfaRegistrationStats
        }

        $s.Members | Should -Be 2
        $s.Guests  | Should -Be 6

        # The member view: full coverage, which is the truth about the workforce.
        $s.MembersMfaCapablePercent          | Should -Be 100
        $s.MembersSsprCapablePercent         | Should -Be 100
        $s.MembersPasswordlessCapablePercent | Should -Be 100

        # The all-user view, kept for continuity of an existing workbook's history, is
        # diluted by exactly the guests - 2 of 8.
        $s.MfaCapablePercent  | Should -Be 25
        $s.SsprCapablePercent | Should -Be 25

        # Visible rather than implied: guests contribute nothing to SSPR.
        $s.GuestsSsprCapable  | Should -Be 0
        $s.MembersSsprCapable | Should -Be 2

        # The count somebody reads out in a meeting. All-user says 6 cannot do MFA; the
        # truth about the workforce is 0. Measured live the same shape gave 146 against 8.
        $s.NotMfaCapable        | Should -Be 6
        $s.MembersNotMfaCapable | Should -Be 0
    }

    It 'propagates the licensing 403 from the underlying report' {
        InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'userRegistrationDetails' } -MockWith {
                $body = '{"error":{"message":"Tenant is not a B2C tenant and doesn''t have premium license"}}'
                $ex   = [System.Exception]::new('Response status code does not indicate success: 403 (Forbidden).')
                $rec  = [System.Management.Automation.ErrorRecord]::new($ex, 'HttpResponse403', 'PermissionDenied', $null)
                $rec.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($body)
                throw $rec
            }

            { Get-MsecEntraMfaRegistrationStats } | Should -Throw -ExpectedMessage '*LICENSING limit*'
        }
    }
}
