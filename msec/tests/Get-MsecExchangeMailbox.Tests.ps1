#Requires -Module Pester
#
# Tests for Get-MsecExchangeMailbox.
#
# Every trap here is a value that would read as a measurement when nothing was measured:
#
#   A Recipient forward cannot be judged external without resolving the recipient, so
#   IsForwardingExternal is $null - NOT $false, which would claim it stays inside the tenant.
#
#   The per-mailbox SMTP AUTH setting is usually $null, meaning "inherit the tenant default".
#   Read as a boolean that is false, so an unresolved value reports SMTP AUTH disabled on every
#   mailbox that never set it - the protocol that bypasses MFA, reported safe by default.
#
#   A mailbox with no CAS record has no protocols to report. Measured live: five Bookings
#   (SchedulingMailbox) mailboxes, which genuinely have none.

BeforeAll {
    $script:StubbedExoCommands = @()
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop

    # ExchangeOnlineManagement is not a dependency of msec, and is absent from some CI images.
    # Pester's Mock needs the command to EXIST; stubs carry real parameter names so any
    # -ParameterFilter binds the way it would against the real cmdlet.
    $exoStubs = @{
        'Get-ConnectionInformation' = { [CmdletBinding()] param() }
        'Get-AcceptedDomain'        = { [CmdletBinding()] param() }
        'Get-TransportConfig'       = { [CmdletBinding()] param() }
        'Get-EXOCasMailbox'         = { [CmdletBinding()] param($ResultSize) }
        'Get-EXOMailbox'            = { [CmdletBinding()] param($RecipientTypeDetails, $PropertySets, $ResultSize) }
    }
    foreach ($exoCmd in $exoStubs.Keys) {
        if (-not (Get-Command $exoCmd -ErrorAction SilentlyContinue)) {
            Set-Item "function:global:$exoCmd" -Value $exoStubs[$exoCmd] -Force
            $script:StubbedExoCommands += $exoCmd
        }
    }
}
AfterAll {
    foreach ($exoCmd in $script:StubbedExoCommands) {
        Remove-Item "function:global:$exoCmd" -ErrorAction SilentlyContinue
    }
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecExchangeMailbox' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith {
                [pscustomobject]@{ ConnectionUri = 'https://outlook.office365.com'; TenantID = 't'; AppId = 'c'; ConnectionId = 'x' }
            }
            Mock Get-AcceptedDomain  -MockWith { @([pscustomobject]@{ DomainName = 'contoso.com' }) }
            Mock Get-TransportConfig -MockWith { [pscustomobject]@{ SmtpClientAuthenticationDisabled = $true } }
            Mock Get-EXOCasMailbox   -MockWith {
                @([pscustomobject]@{
                    ExternalDirectoryObjectId = 'oid-1'; PopEnabled = $true; ImapEnabled = $false
                    ActiveSyncEnabled = $true; OWAEnabled = $true
                    SmtpClientAuthenticationDisabled = $null      # inherits the tenant
                })
            }
        }
    }

    It 'separates a raw SMTP forward from one naming a recipient object' {
        $rows = InModuleScope msec {
            Mock Get-EXOMailbox -MockWith {
                @(
                    [pscustomobject]@{ ExternalDirectoryObjectId = 'oid-1'; UserPrincipalName = 'a@contoso.com'
                                       ForwardingSmtpAddress = 'smtp:thief@evil.example'; DeliverToMailboxAndForward = $false }
                    [pscustomobject]@{ ExternalDirectoryObjectId = 'oid-2'; UserPrincipalName = 'b@contoso.com'
                                       ForwardingAddress = 'Ticketing system'; DeliverToMailboxAndForward = $true }
                    [pscustomobject]@{ ExternalDirectoryObjectId = 'oid-3'; UserPrincipalName = 'c@contoso.com' }
                )
            }
            @(Get-MsecExchangeMailbox)
        }

        $a = $rows | Where-Object UserPrincipalName -eq 'a@contoso.com'
        $a.ForwardingKind       | Should -Be 'SmtpAddress'
        $a.ForwardingTarget     | Should -Be 'thief@evil.example'   # the smtp: prefix is stripped
        $a.IsForwardingExternal | Should -BeTrue
        # No copy kept: the mail leaves and the owner cannot notice.
        $a.DeliverToMailboxAndForward | Should -BeFalse

        $b = $rows | Where-Object UserPrincipalName -eq 'b@contoso.com'
        $b.ForwardingKind | Should -Be 'Recipient'
        # NOT $false: judging it needs a recipient lookup this command does not do.
        $b.IsForwardingExternal | Should -BeNullOrEmpty

        $c = $rows | Where-Object UserPrincipalName -eq 'c@contoso.com'
        $c.ForwardingKind             | Should -Be 'None'
        $c.DeliverToMailboxAndForward | Should -BeNullOrEmpty
    }

    It 'treats a forward inside an accepted domain as internal' {
        $row = InModuleScope msec {
            Mock Get-EXOMailbox -MockWith {
                @([pscustomobject]@{ ExternalDirectoryObjectId = 'oid-1'; UserPrincipalName = 'a@contoso.com'
                                     ForwardingSmtpAddress = 'smtp:colleague@contoso.com'; DeliverToMailboxAndForward = $true })
            }
            @(Get-MsecExchangeMailbox)
        }
        $row[0].IsForwardingExternal | Should -BeFalse
    }

    It 'nulls IsForwardingExternal when the accepted domains could not be read' {
        $row = InModuleScope msec {
            Mock Get-AcceptedDomain -MockWith { throw 'denied' }
            Mock Get-EXOMailbox -MockWith {
                @([pscustomobject]@{ ExternalDirectoryObjectId = 'oid-1'; UserPrincipalName = 'a@contoso.com'
                                     ForwardingSmtpAddress = 'smtp:someone@elsewhere.example' })
            }
            @(Get-MsecExchangeMailbox -WarningAction SilentlyContinue)
        }
        # "not checked" must not render as "stays inside the tenant".
        $row[0].IsForwardingExternal | Should -BeNullOrEmpty
    }

    It 'resolves SMTP AUTH from the tenant when the mailbox does not set it' {
        $row = InModuleScope msec {
            Mock Get-EXOMailbox -MockWith {
                @([pscustomobject]@{ ExternalDirectoryObjectId = 'oid-1'; UserPrincipalName = 'a@contoso.com' })
            }
            @(Get-MsecExchangeMailbox)
        }
        $row[0].SmtpAuthEnabled | Should -BeFalse
        $row[0].SmtpAuthSource  | Should -Be 'Tenant'
    }

    It 'prefers the mailbox setting over the tenant default, and says which it used' {
        $row = InModuleScope msec {
            Mock Get-EXOCasMailbox -MockWith {
                @([pscustomobject]@{ ExternalDirectoryObjectId = 'oid-1'
                                     SmtpClientAuthenticationDisabled = $false })   # explicitly ON
            }
            Mock Get-EXOMailbox -MockWith {
                @([pscustomobject]@{ ExternalDirectoryObjectId = 'oid-1'; UserPrincipalName = 'a@contoso.com' })
            }
            @(Get-MsecExchangeMailbox)
        }
        # The tenant says disabled; this mailbox overrides it. SMTP AUTH bypasses MFA, so the
        # override is the answer that matters.
        $row[0].SmtpAuthEnabled | Should -BeTrue
        $row[0].SmtpAuthSource  | Should -Be 'Mailbox'
    }

    It 'nulls the protocol columns for a mailbox with no CAS record' {
        $row = InModuleScope msec {
            Mock Get-EXOCasMailbox -MockWith { @() }
            Mock Get-EXOMailbox -MockWith {
                @([pscustomobject]@{ ExternalDirectoryObjectId = 'oid-9'; UserPrincipalName = 'bookings@contoso.com'
                                     RecipientTypeDetails = 'SchedulingMailbox' })
            }
            @(Get-MsecExchangeMailbox)
        }
        # Bookings mailboxes genuinely have none - $false would claim they were checked and off.
        $row[0].PopEnabled      | Should -BeNullOrEmpty
        $row[0].ImapEnabled     | Should -BeNullOrEmpty
        $row[0].SmtpAuthEnabled | Should -BeNullOrEmpty
    }

    It 'returns only forwarding mailboxes with -ForwardingOnly' {
        $rows = InModuleScope msec {
            Mock Get-EXOMailbox -MockWith {
                @(
                    [pscustomobject]@{ ExternalDirectoryObjectId = 'oid-1'; UserPrincipalName = 'a@contoso.com'
                                       ForwardingSmtpAddress = 'smtp:x@y.example' }
                    [pscustomobject]@{ ExternalDirectoryObjectId = 'oid-2'; UserPrincipalName = 'b@contoso.com' }
                )
            }
            @(Get-MsecExchangeMailbox -ForwardingOnly)
        }
        $rows.Count | Should -Be 1
        $rows[0].UserPrincipalName | Should -Be 'a@contoso.com'
    }
}
