#Requires -Module Pester
#
# Tests for Get-MsecExchangeInboxRule.
#
# This command exists for investigations, where the difference between "no rules" and "could not
# read the rules" decides whether a mailbox is cleared or still suspect. So the traps pinned here
# are all about not manufacturing a clean answer:
#
#   A MAILBOX THAT ERRORED MUST PRODUCE A ROW. Skipping it makes an unreadable mailbox look
#   identical to a clean one.
#
#   ACCEPTED DOMAINS UNREADABLE MEANS ForwardsExternally IS NULL. Saying $false claims the
#   forward stays inside the tenant when nothing ever checked.
#
#   RECIPIENTS ARE 'Display Name [SMTP:addr]', not bare addresses. Comparing the whole string
#   against a domain list matches nothing and reports every forward as internal.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop

    # Only stub what is genuinely missing, and remember what was stubbed, so this file never
    # replaces a stub another test file depends on. Get-EXOMailbox carries the same parameter
    # set as the one in Get-MsecExchangeMailbox.Tests.ps1: a narrower stub winning the race
    # makes that file's -PropertySets call fail to bind, which reads as a broken command.
    $script:StubbedExoCommands = @()
    $exoStubs = @{
        'Get-InboxRule'      = { [CmdletBinding()] param($Mailbox) }
        'Get-AcceptedDomain' = { [CmdletBinding()] param() }
        'Get-EXOMailbox'     = { [CmdletBinding()] param($RecipientTypeDetails, $PropertySets, $ResultSize) }
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
Describe 'Get-MsecExchangeInboxRule' {

    It 'extracts the SMTP address out of a display-name recipient and calls it external' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-AcceptedDomain -MockWith { @([pscustomobject]@{ DomainName = 'contoso.com' }) }
            Mock Get-InboxRule -MockWith {
                @([pscustomobject]@{
                    Name = 'Exfil'; Enabled = $true; Priority = 1; IsValid = $true
                    ForwardTo = @('"Bad Person" [SMTP:attacker@evil.example]')
                    Description = 'forward everything'
                })
            }
            Get-MsecExchangeInboxRule -Mailbox 'alice@contoso.com'
        }

        $rows[0].ForwardTo | Should -Be 'attacker@evil.example'
        $rows[0].ForwardsExternally | Should -BeTrue
        $rows[0].ExternalTargets | Should -Be 'attacker@evil.example'
        $rows[0].IsRisky | Should -BeTrue
        $rows[0].RiskReasons | Should -Match 'outside the tenant'
    }

    It 'does not flag a forward that stays inside an accepted domain' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-AcceptedDomain -MockWith { @([pscustomobject]@{ DomainName = 'contoso.com' }) }
            Mock Get-InboxRule -MockWith {
                @([pscustomobject]@{ Name = 'To my colleague'; Enabled = $true; IsValid = $true
                                     ForwardTo = @('"Bob" [SMTP:bob@contoso.com]') })
            }
            Get-MsecExchangeInboxRule -Mailbox 'alice@contoso.com'
        }

        $rows[0].ForwardsExternally | Should -BeFalse
        $rows[0].IsRisky | Should -BeFalse
    }

    It 'reports ForwardsExternally and IsRisky as null when accepted domains cannot be read' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-AcceptedDomain -MockWith { throw 'Access denied' }
            Mock Get-InboxRule -MockWith {
                @([pscustomobject]@{ Name = 'Forward'; Enabled = $true; IsValid = $true
                                     ForwardTo = @('"X" [SMTP:x@somewhere.example]') })
            }
            Get-MsecExchangeInboxRule -Mailbox 'alice@contoso.com' -WarningAction SilentlyContinue
        }

        # $false here would be a clean bill of health nothing earned.
        $rows[0].ForwardsExternally | Should -BeNullOrEmpty
        $rows[0].IsRisky | Should -BeNullOrEmpty
        $rows[0].ExternalTargets | Should -BeNullOrEmpty
    }

    It 'produces a row for a mailbox whose rules could not be read' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-AcceptedDomain -MockWith { @([pscustomobject]@{ DomainName = 'contoso.com' }) }
            Mock Get-InboxRule -MockWith { throw 'The operation could not be performed' }
            Get-MsecExchangeInboxRule -Mailbox 'alice@contoso.com' -WarningAction SilentlyContinue
        }

        $rows.Count | Should -Be 1
        $rows[0].RuleName | Should -Be 'Unreadable'
        $rows[0].Mailbox | Should -Be 'alice@contoso.com'
        $rows[0].IsRisky | Should -BeNullOrEmpty
    }

    It 'emits nothing for a mailbox that genuinely holds no rules' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-AcceptedDomain -MockWith { @([pscustomobject]@{ DomainName = 'contoso.com' }) }
            Mock Get-InboxRule -MockWith { @() }
            Get-MsecExchangeInboxRule -Mailbox 'alice@contoso.com'
        }

        # A real measurement, and distinct from the Unreadable row above.
        $rows | Should -BeNullOrEmpty
    }

    It 'flags the file-away-and-mark-read pattern even with no forwarding' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-AcceptedDomain -MockWith { @([pscustomobject]@{ DomainName = 'contoso.com' }) }
            Mock Get-InboxRule -MockWith {
                @([pscustomobject]@{ Name = 'Invoices'; Enabled = $true; IsValid = $true
                                     MoveToFolder = 'RSS Feeds'; MarkAsRead = $true })
            }
            Get-MsecExchangeInboxRule -Mailbox 'alice@contoso.com'
        }

        $rows[0].IsRisky | Should -BeTrue
        $rows[0].RiskReasons | Should -Match 'RSS Feeds'
        $rows[0].ForwardsExternally | Should -BeFalse
    }

    It 'does not flag filing into an ordinary project folder and marking it read' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-AcceptedDomain -MockWith { @([pscustomobject]@{ DomainName = 'contoso.com' }) }
            Mock Get-InboxRule -MockWith {
                @([pscustomobject]@{ Name = 'Study filing'; Enabled = $true; IsValid = $true
                                     MoveToFolder = 'AML-FLT3 (RJM Group)/2886601'; MarkAsRead = $true })
            }
            Get-MsecExchangeInboxRule -Mailbox 'alice@contoso.com'
        }

        # Measured: flagging any folder fired on 292 of 1373 real rules, nearly all of them
        # ordinary per-study filing. Only a concealing folder counts.
        $rows[0].IsRisky | Should -BeFalse
        $rows[0].MarkAsRead | Should -BeTrue
        $rows[0].RiskReasons | Should -BeNullOrEmpty
    }

    It 'flags an invalid rule' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-AcceptedDomain -MockWith { @([pscustomobject]@{ DomainName = 'contoso.com' }) }
            Mock Get-InboxRule -MockWith {
                @([pscustomobject]@{ Name = 'Broken'; Enabled = $true; IsValid = $false; ErrorType = 'ParseError' })
            }
            Get-MsecExchangeInboxRule -Mailbox 'alice@contoso.com'
        }

        $rows[0].IsRisky | Should -BeTrue
        $rows[0].RiskReasons | Should -Match 'invalid'
        $rows[0].ErrorType | Should -Be 'ParseError'
    }

    It 'returns only risky rules with -RiskyOnly, and drops ordinary mail management' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-AcceptedDomain -MockWith { @([pscustomobject]@{ DomainName = 'contoso.com' }) }
            Mock Get-InboxRule -MockWith {
                @(
                    [pscustomobject]@{ Name = 'Project filing'; Enabled = $true; IsValid = $true
                                       MoveToFolder = 'Project X'; StopProcessingRules = $true }
                    [pscustomobject]@{ Name = 'Delete traces'; Enabled = $true; IsValid = $true
                                       DeleteMessage = $true }
                )
            }
            Get-MsecExchangeInboxRule -Mailbox 'alice@contoso.com' -RiskyOnly
        }

        # A plain MoveToFolder plus StopProcessingRules is normal and must not be flagged.
        $rows.Count | Should -Be 1
        $rows[0].RuleName | Should -Be 'Delete traces'
    }
}
