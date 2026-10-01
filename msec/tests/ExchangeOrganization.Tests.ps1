#Requires -Module Pester
#
# Tests for Get-MsecExchangeTransportRule and Get-MsecExchangeOrganizationSetting.
#
#   SCL -1 is "skip all filtering", which the number does not say. BypassesFiltering does.
#
#   A rule can be Enabled and inert, because Mode Audit does not act. IsActive needs both.
#
#   There are FOUR redirect properties, not one. Checking RedirectMessageTo alone misses
#   BlindCopyTo, CopyTo and AddToRecipients - three ways to copy mail elsewhere.
#
#   There are TWO auto-forwarding controls and both must be closed. Fixing one is the common
#   half-fix, so they belong on the same row.

BeforeAll {
    $script:StubbedExoCommands = @()
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop

    $exoStubs = @{
        'Get-ConnectionInformation'        = { [CmdletBinding()] param() }
        'Get-AcceptedDomain'               = { [CmdletBinding()] param() }
        'Get-TransportRule'                = { [CmdletBinding()] param() }
        'Get-TransportConfig'              = { [CmdletBinding()] param() }
        'Get-RemoteDomain'                 = { [CmdletBinding()] param() }
        'Get-AdminAuditLogConfig'          = { [CmdletBinding()] param() }
        'Get-InboundConnector'             = { [CmdletBinding()] param() }
        'Get-OutboundConnector'            = { [CmdletBinding()] param() }
        'Get-HostedOutboundSpamFilterPolicy' = { [CmdletBinding()] param() }
    }
    foreach ($exoCmd in $exoStubs.Keys) {
        if (-not (Get-Command $exoCmd -ErrorAction SilentlyContinue)) {
            Set-Item "function:global:$exoCmd" -Value $exoStubs[$exoCmd] -Force
            $script:StubbedExoCommands += $exoCmd
        }
    }
}
AfterAll {
    foreach ($exoCmd in $script:StubbedExoCommands) { Remove-Item "function:global:$exoCmd" -ErrorAction SilentlyContinue }
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecExchangeTransportRule' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith {
                [pscustomobject]@{ ConnectionUri = 'https://outlook.office365.com'; TenantID = 't'; AppId = 'c'; ConnectionId = 'x' }
            }
            Mock Get-AcceptedDomain -MockWith { @([pscustomobject]@{ DomainName = 'contoso.com' }) }
        }
    }

    It 'says in words that SCL -1 means filtering is skipped' {
        $rows = InModuleScope msec {
            Mock Get-TransportRule -MockWith {
                @(
                    [pscustomobject]@{ Name = 'Bypass'; State = 'Enabled'; Mode = 'Enforce'; SetSCL = -1 }
                    [pscustomobject]@{ Name = 'Normal'; State = 'Enabled'; Mode = 'Enforce'; SetSCL = $null }
                )
            }
            @(Get-MsecExchangeTransportRule)
        }
        ($rows | Where-Object Name -eq 'Bypass').BypassesFiltering | Should -BeTrue
        ($rows | Where-Object Name -eq 'Normal').BypassesFiltering | Should -BeFalse
    }

    It 'treats an Enabled rule in Audit mode as not active' {
        $rows = InModuleScope msec {
            Mock Get-TransportRule -MockWith {
                @(
                    [pscustomobject]@{ Name = 'Enforcing'; State = 'Enabled';  Mode = 'Enforce' }
                    [pscustomobject]@{ Name = 'Auditing';  State = 'Enabled';  Mode = 'Audit' }
                    [pscustomobject]@{ Name = 'Off';       State = 'Disabled'; Mode = 'Enforce' }
                )
            }
            @(Get-MsecExchangeTransportRule)
        }
        # Enabled is not enough: an Audit-mode rule is live and does nothing.
        ($rows | Where-Object Name -eq 'Enforcing').IsActive | Should -BeTrue
        ($rows | Where-Object Name -eq 'Auditing').IsActive  | Should -BeFalse
        ($rows | Where-Object Name -eq 'Off').IsActive       | Should -BeFalse
    }

    It 'checks all four ways a rule can send mail elsewhere' {
        $rows = InModuleScope msec {
            Mock Get-TransportRule -MockWith {
                @(
                    [pscustomobject]@{ Name = 'R'; State = 'Enabled'; Mode = 'Enforce'; RedirectMessageTo = @('a@contoso.com') }
                    [pscustomobject]@{ Name = 'B'; State = 'Enabled'; Mode = 'Enforce'; BlindCopyTo       = @('b@evil.example') }
                    [pscustomobject]@{ Name = 'C'; State = 'Enabled'; Mode = 'Enforce'; CopyTo            = @('c@contoso.com') }
                    [pscustomobject]@{ Name = 'A'; State = 'Enabled'; Mode = 'Enforce'; AddToRecipients   = @('d@contoso.com') }
                    [pscustomobject]@{ Name = 'N'; State = 'Enabled'; Mode = 'Enforce' }
                )
            }
            @(Get-MsecExchangeTransportRule)
        }
        foreach ($n in 'R', 'B', 'C', 'A') {
            ($rows | Where-Object Name -eq $n).RedirectsMail | Should -BeTrue -Because "$n sets one of the four"
        }
        ($rows | Where-Object Name -eq 'N').RedirectsMail | Should -BeFalse
        # Only the one outside an accepted domain is named.
        ($rows | Where-Object Name -eq 'B').ExternalRecipients | Should -Contain 'b@evil.example'
        ($rows | Where-Object Name -eq 'C').ExternalRecipients | Should -BeNullOrEmpty
    }

    It 'nulls ExternalRecipients when accepted domains could not be read' {
        $rows = InModuleScope msec {
            Mock Get-AcceptedDomain -MockWith { throw 'denied' }
            Mock Get-TransportRule -MockWith {
                @([pscustomobject]@{ Name = 'R'; State = 'Enabled'; Mode = 'Enforce'; BlindCopyTo = @('x@elsewhere.example') })
            }
            @(Get-MsecExchangeTransportRule -WarningAction SilentlyContinue)
        }
        # Not an empty list, which would read as "checked, all internal".
        $rows[0].ExternalRecipients | Should -BeNullOrEmpty
        $rows[0].RedirectsMail      | Should -BeTrue
    }

    It 'returns only bypassing or redirecting rules with -RiskyOnly' {
        $rows = InModuleScope msec {
            Mock Get-TransportRule -MockWith {
                @(
                    [pscustomobject]@{ Name = 'Bypass'; State = 'Enabled'; Mode = 'Enforce'; SetSCL = -1 }
                    [pscustomobject]@{ Name = 'Plain';  State = 'Enabled'; Mode = 'Enforce' }
                )
            }
            @(Get-MsecExchangeTransportRule -RiskyOnly)
        }
        $rows.Count   | Should -Be 1
        $rows[0].Name | Should -Be 'Bypass'
    }
}

Describe 'Get-MsecExchangeOrganizationSetting' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith {
                [pscustomobject]@{ ConnectionUri = 'https://outlook.office365.com'; TenantID = 't'; AppId = 'c'; ConnectionId = 'x' }
            }
            Mock Get-HostedOutboundSpamFilterPolicy -MockWith { @([pscustomobject]@{ Name = 'Default'; IsDefault = $true; AutoForwardingMode = 'On' }) }
            Mock Get-RemoteDomain        -MockWith { @([pscustomobject]@{ Name = 'Default'; DomainName = '*'; AutoForwardEnabled = $true }) }
            Mock Get-TransportConfig     -MockWith { [pscustomobject]@{ SmtpClientAuthenticationDisabled = $true } }
            Mock Get-AdminAuditLogConfig -MockWith { [pscustomobject]@{ UnifiedAuditLogIngestionEnabled = $true; AdminAuditLogEnabled = $true } }
            Mock Get-AcceptedDomain      -MockWith { @([pscustomobject]@{ DomainName = 'contoso.com' }) }
            Mock Get-InboundConnector    -MockWith { @() }
            Mock Get-OutboundConnector   -MockWith { @() }
            Mock Get-TransportRule       -MockWith { @([pscustomobject]@{ Name = 'B'; State = 'Enabled'; Mode = 'Enforce'; SetSCL = -1 }) }
        }
    }

    It 'puts both auto-forwarding controls on the same row' {
        $row = InModuleScope msec { Get-MsecExchangeOrganizationSetting }
        # Closing one and leaving the other is the usual half-fix.
        $row.AutoForwardingMode             | Should -Be 'On'
        $row.RemoteDomainAutoForwardEnabled | Should -BeTrue
    }

    It 'reports SMTP AUTH in the positive, inverting the raw property' {
        $row = InModuleScope msec { Get-MsecExchangeOrganizationSetting }
        # Raw property is SmtpClientAuthenticationDisabled = $true.
        $row.SmtpAuthEnabledTenantWide | Should -BeFalse
    }

    It 'counts only the bypass rules that are actually active' {
        $row = InModuleScope msec {
            Mock Get-TransportRule -MockWith {
                @(
                    [pscustomobject]@{ Name = 'Live'; State = 'Enabled';  Mode = 'Enforce'; SetSCL = -1 }
                    [pscustomobject]@{ Name = 'Off';  State = 'Disabled'; Mode = 'Enforce'; SetSCL = -1 }
                )
            }
            Get-MsecExchangeOrganizationSetting
        }
        $row.FilterBypassRuleCount       | Should -Be 2
        $row.ActiveFilterBypassRuleCount | Should -Be 1
    }

    It 'nulls one column rather than failing the whole row when a lookup is refused' {
        $row = InModuleScope msec {
            Mock Get-AdminAuditLogConfig -MockWith { throw 'access denied' }
            Get-MsecExchangeOrganizationSetting -WarningAction SilentlyContinue
        }
        # A partial answer about tenant posture beats none, as long as the gap shows as a gap.
        $row.UnifiedAuditLogEnabled | Should -BeNullOrEmpty
        $row.AutoForwardingMode     | Should -Be 'On'
    }
}
