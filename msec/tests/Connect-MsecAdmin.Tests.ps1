#Requires -Module Pester
#
# Tests for Connect-MsecAdmin.
#
# This command exists because the app CANNOT write - every permission New-MsecApp consents is
# *.Read.All - so writes run as a person instead. Two things it must get right, both of which
# fail silently otherwise:
#
#   A declined scope is not an error. Connect-MgGraph returns a context without it and the
#   first write 403s naming nothing, so the granted set is checked against the requested one
#   here, while there is still something useful to say.
#
#   Signing in to a different tenant than Connect-Msec is reading is invisible at the time and
#   obvious afterwards. It is refused, and the half-open Graph session is closed on the way out.

BeforeAll {
    $script:StubbedGraphCommands = @()
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop

    # Microsoft.Graph.Authentication is NOT a dependency of msec - only Connect-MsecAdmin needs
    # it, and it checks at run time. It is preinstalled on the Windows and Ubuntu GitHub images
    # but NOT on the macOS one, so these tests passed on two runners and failed on the third:
    # Pester's Mock requires the command to EXIST, and a missing one fails as "Could not find
    # Command Get-MgContext" rather than as anything pointing at the real cause.
    #
    # Stubbed only when absent, so a machine that has the real module still mocks the real
    # command and the two behave identically.
    foreach ($graphCmd in 'Get-MgContext', 'Connect-MgGraph', 'Disconnect-MgGraph') {
        if (-not (Get-Command $graphCmd -ErrorAction SilentlyContinue)) {
            Set-Item "function:global:$graphCmd" -Value { param() } -Force
            $script:StubbedGraphCommands += $graphCmd
        }
    }
}
AfterAll {
    foreach ($graphCmd in $script:StubbedGraphCommands) {
        Remove-Item "function:global:$graphCmd" -ErrorAction SilentlyContinue
    } Remove-Module msec -Force -ErrorAction SilentlyContinue }

Describe 'Connect-MsecAdmin' {

    It 'refuses when the tenant granted fewer scopes than were asked for' {
        InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Connect-MgGraph -MockWith { }
            # Asked for two, granted one - which Connect-MgGraph reports as success.
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.com'; TenantId = 't1'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            $script:MsecSession = $null

            { Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All', 'SecurityIncident.ReadWrite.All' } |
                Should -Throw '*SecurityIncident.ReadWrite.All*'
        }
    }

    It 'refuses a tenant different from the one being read, and closes the session' {
        InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Connect-MgGraph -MockWith { }
            Mock Disconnect-MgGraph -MockWith { }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.com'; TenantId = 'OTHER-TENANT'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            # Reading tenant-1; the sign-in landed somewhere else.
            $script:MsecSession = @{ TenantId = 'tenant-1' }

            { Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All' -TenantId 'OTHER-TENANT' } |
                Should -Throw '*different tenant*'
            # The half-open session must not be left behind for a later command to find.
            Should -Invoke Disconnect-MgGraph -Times 1 -Exactly
        }
    }

    It 'defaults to the tenant Connect-Msec is reading' {
        InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Connect-MgGraph -MockWith { }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.com'; TenantId = 'tenant-1'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            $script:MsecSession = @{ TenantId = 'tenant-1' }

            $null = Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All'

            Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter { $TenantId -eq 'tenant-1' }
        }
    }

    It 'records the write session separately from the read session' {
        $session = InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Connect-MgGraph -MockWith { }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.com'; TenantId = 'tenant-1'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            $script:MsecSession = @{ TenantId = 'tenant-1' }
            $null = Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All'
            # A Set-* has to tell "no write session" from "app session" - so they are distinct.
            $script:MsecAdminSession
        }

        $session.Account      | Should -Be 'me@contoso.com'
        $session.GrantedScope | Should -Contain 'SecurityAlert.ReadWrite.All'
    }

    It 'names the module to install when the Graph SDK is absent' {
        InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { $null }
            { Connect-MsecAdmin } | Should -Throw '*Microsoft.Graph.Authentication*'
        }
    }
}
