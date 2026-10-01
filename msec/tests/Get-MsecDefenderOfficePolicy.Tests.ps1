#Requires -Module Pester
#
# Tests for Get-MsecDefenderOfficePolicy.
#
# In Exchange Online Protection a policy and the rule that applies it are separate objects, so
# "does this policy do anything" is a real question with four different right answers. The traps:
#
#   A PRESET POLICY HAS NO RULE OF ITS OWN and is applied by the EOP/ATP protection policy rule.
#   Reporting 'Strict Preset Security Policy' as unapplied because Get-AntiPhishRule does not
#   mention it would cry wolf on the configuration Microsoft most recommends - and on a tenant
#   that uses presets, that is nearly every policy.
#
#   A DEFAULT POLICY HAS NO RULE EITHER, for a different reason: it is the fallback.
#
#   RULES UNREADABLE IS NOT RULES ABSENT. If the *Rule cmdlet fails, every custom policy would
#   otherwise be reported inert, which is both wrong and alarming.
#
# The stubs carry [CmdletBinding()] because the command calls them with -ErrorAction Stop, and a
# simple function has no common parameters - it would fail on the parameter, not on the data.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop

    foreach ($name in 'Get-AntiPhishPolicy','Get-AntiPhishRule','Get-SafeLinksPolicy','Get-SafeLinksRule',
                      'Get-SafeAttachmentPolicy','Get-SafeAttachmentRule','Get-HostedContentFilterPolicy',
                      'Get-HostedContentFilterRule','Get-MalwareFilterPolicy','Get-MalwareFilterRule',
                      'Get-HostedOutboundSpamFilterPolicy','Get-HostedOutboundSpamFilterRule',
                      'Get-EOPProtectionPolicyRule','Get-ATPProtectionPolicyRule',
                      'Get-PhishSimOverridePolicy','Get-SecOpsOverridePolicy') {
        Set-Item "function:global:$name" -Value ([scriptblock]::Create('[CmdletBinding()] param()'))
    }
}
AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
    foreach ($name in 'Get-AntiPhishPolicy','Get-AntiPhishRule','Get-SafeLinksPolicy','Get-SafeLinksRule',
                      'Get-SafeAttachmentPolicy','Get-SafeAttachmentRule','Get-HostedContentFilterPolicy',
                      'Get-HostedContentFilterRule','Get-MalwareFilterPolicy','Get-MalwareFilterRule',
                      'Get-HostedOutboundSpamFilterPolicy','Get-HostedOutboundSpamFilterRule',
                      'Get-EOPProtectionPolicyRule','Get-ATPProtectionPolicyRule',
                      'Get-PhishSimOverridePolicy','Get-SecOpsOverridePolicy') {
        Remove-Item "function:global:$name" -ErrorAction SilentlyContinue
    }
}

Describe 'Get-MsecDefenderOfficePolicy' {

    It 'does not report a preset policy as unapplied just because no AntiPhishRule names it' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-EOPProtectionPolicyRule -MockWith {
                @([pscustomobject]@{ Name = 'Strict Preset Security Policy'; State = 'Enabled'; Priority = 0
                                     AntiPhishPolicy = 'Strict Preset Security Policy'
                                     SentToMemberOf = @('ITOperations@contoso.com') })
            }
            Mock Get-ATPProtectionPolicyRule -MockWith { @() }
            Mock Get-AntiPhishPolicy -MockWith {
                @([pscustomobject]@{ Name = 'Strict Preset Security Policy'; IsDefault = $false; Enabled = $true })
            }
            Mock Get-AntiPhishRule -MockWith { @() }
            Get-MsecDefenderOfficePolicy -PolicyType AntiPhish
        }

        $rows | Should -Not -BeNullOrEmpty
        $rows[0].IsApplied | Should -BeTrue
        $rows[0].AppliedBy | Should -Match '^Preset: Strict Preset Security Policy'
        $rows[0].AppliedTo | Should -Match 'ITOperations@contoso.com'
    }

    It 'treats a default policy as applied, not as a policy nobody references' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-EOPProtectionPolicyRule -MockWith { @() }
            Mock Get-ATPProtectionPolicyRule -MockWith { @() }
            Mock Get-AntiPhishPolicy -MockWith {
                @([pscustomobject]@{ Name = 'Office365 AntiPhish Default'; IsDefault = $true; Enabled = $true })
            }
            Mock Get-AntiPhishRule -MockWith { @() }
            Get-MsecDefenderOfficePolicy -PolicyType AntiPhish
        }

        $rows[0].IsApplied | Should -BeTrue
        $rows[0].AppliedBy | Should -Be 'Default'
    }

    It 'reports a custom policy no rule references as unapplied' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-EOPProtectionPolicyRule -MockWith { @() }
            Mock Get-ATPProtectionPolicyRule -MockWith { @() }
            Mock Get-AntiPhishPolicy -MockWith {
                @([pscustomobject]@{ Name = 'Carefully Written And Inert'; IsDefault = $false; Enabled = $true })
            }
            Mock Get-AntiPhishRule -MockWith { @() }
            Get-MsecDefenderOfficePolicy -PolicyType AntiPhish
        }

        $rows[0].IsApplied | Should -BeFalse
        $rows[0].AppliedBy | Should -BeNullOrEmpty
    }

    It 'reports a custom policy whose rule is disabled as unapplied, but names the rule' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-EOPProtectionPolicyRule -MockWith { @() }
            Mock Get-ATPProtectionPolicyRule -MockWith { @() }
            Mock Get-AntiPhishPolicy -MockWith {
                @([pscustomobject]@{ Name = 'Pilot'; IsDefault = $false; Enabled = $true })
            }
            Mock Get-AntiPhishRule -MockWith {
                @([pscustomobject]@{ Name = 'Pilot rule'; State = 'Disabled'; AntiPhishPolicy = 'Pilot'
                                     SentTo = @('a@contoso.com') })
            }
            Get-MsecDefenderOfficePolicy -PolicyType AntiPhish
        }

        $rows[0].IsApplied | Should -BeFalse
        $rows[0].AppliedBy | Should -Be 'Rule: Pilot rule'
        $rows[0].AppliedTo | Should -Match 'a@contoso.com'
    }

    It 'leaves IsApplied null when the rules could not be read at all' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-EOPProtectionPolicyRule -MockWith { @() }
            Mock Get-ATPProtectionPolicyRule -MockWith { @() }
            Mock Get-AntiPhishPolicy -MockWith {
                @([pscustomobject]@{ Name = 'Custom'; IsDefault = $false; Enabled = $true })
            }
            Mock Get-AntiPhishRule -MockWith { throw 'Access denied' }
            Get-MsecDefenderOfficePolicy -PolicyType AntiPhish -WarningAction SilentlyContinue
        }

        # $false would assert the policy was checked and found inert.
        $rows[0].IsApplied | Should -BeNullOrEmpty
    }

    It 'reports a policy area it could not read instead of omitting it' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-EOPProtectionPolicyRule -MockWith { @() }
            Mock Get-ATPProtectionPolicyRule -MockWith { @() }
            Mock Get-AntiPhishPolicy -MockWith { throw 'Insufficient privileges' }
            Mock Get-AntiPhishRule -MockWith { @() }
            Get-MsecDefenderOfficePolicy -PolicyType AntiPhish -WarningAction SilentlyContinue
        }

        $rows.Count | Should -Be 1
        $rows[0].PolicyName | Should -Be 'Unreadable'
        $rows[0].IsApplied | Should -BeNullOrEmpty
    }

    It 'reports advanced delivery as unreadable rather than as not configured' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-EOPProtectionPolicyRule -MockWith { @() }
            Mock Get-ATPProtectionPolicyRule -MockWith { @() }
            # This is the real failure on an app-only session.
            Mock Get-PhishSimOverridePolicy -MockWith { throw 'A server side error has occurred' }
            Mock Get-SecOpsOverridePolicy -MockWith { @() }
            Get-MsecDefenderOfficePolicy -PolicyType AdvancedDelivery -WarningAction SilentlyContinue
        }

        $phishSim = $rows | Where-Object PolicyName -match 'Phishing simulation'
        $phishSim.IsApplied | Should -BeNullOrEmpty    # unreadable
        $secOps = $rows | Where-Object PolicyName -match 'SecOps'
        $secOps.Value | Should -Be 'False'             # genuinely read, genuinely absent
        $secOps.IsApplied | Should -BeFalse
    }

    It 'returns only inert policies with -UnappliedOnly' {
        $rows = InModuleScope msec {
            Mock Initialize-MsecExoSession -MockWith { }
            Mock Get-EOPProtectionPolicyRule -MockWith { @() }
            Mock Get-ATPProtectionPolicyRule -MockWith { @() }
            Mock Get-AntiPhishPolicy -MockWith {
                @(
                    [pscustomobject]@{ Name = 'Office365 AntiPhish Default'; IsDefault = $true; Enabled = $true }
                    [pscustomobject]@{ Name = 'Inert'; IsDefault = $false; Enabled = $true }
                )
            }
            Mock Get-AntiPhishRule -MockWith { @() }
            Get-MsecDefenderOfficePolicy -PolicyType AntiPhish -UnappliedOnly
        }

        @($rows | Select-Object -ExpandProperty PolicyName -Unique) | Should -Be 'Inert'
    }
}
