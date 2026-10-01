#Requires -Module Pester
#
# Tests for Get-MsecTeamsPolicyAssignment.
#
# The command exists for one reason: a policy list alone cannot tell a restrictive tenant from
# a tenant holding a restrictive policy that applies to nobody. So the behaviour worth pinning
# hardest is that a policy with ZERO holders is still returned - if it were omitted, the output
# would read exactly like the tenant where that policy does not exist.
#
# The second is that an unreadable user list reports null rather than 0. A failed read that
# prints "0 users" on every policy is both wrong and the most alarming possible misreading.
#
# Skipped wholesale without MicrosoftTeams installed: Pester's Mock requires the command being
# mocked to EXIST, and Get-Cs* only exist when that module is present. The CI images do not all
# carry it.

$script:HasTeams = $null -ne (Get-Module -ListAvailable MicrosoftTeams)

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecTeamsPolicyAssignment' -Skip:(-not $script:HasTeams) {

    BeforeEach {
        InModuleScope Msec {
            # No session: the command must not try to self-connect during a unit test.
            $script:MsecSession = $null
            $script:MsecTeamsAsCurrentUser = $null
        }
    }

    It 'returns a policy that applies to nobody, because that is the finding' {
        $rows = InModuleScope Msec {
            Mock Get-CsTeamsMeetingPolicy -MockWith {
                @(
                    [pscustomobject]@{ Identity = 'Global' }
                    [pscustomobject]@{ Identity = 'Tag:RestrictedAnonymousAccess' }
                    [pscustomobject]@{ Identity = 'Tag:NeverAssigned' }
                )
            }
            Mock Get-CsOnlineUser -MockWith {
                @(
                    [pscustomobject]@{ UserPrincipalName = 'a@x.com'; AccountType = 'User'; TeamsMeetingPolicy = $null }
                    [pscustomobject]@{ UserPrincipalName = 'b@x.com'; AccountType = 'User'; TeamsMeetingPolicy = $null }
                    [pscustomobject]@{ UserPrincipalName = 'c@x.com'; AccountType = 'User'
                                       TeamsMeetingPolicy = [pscustomobject]@{ Name = 'RestrictedAnonymousAccess'; Authority = 'Host' } }
                )
            }
            Get-MsecTeamsPolicyAssignment -PolicyType Meeting
        }

        # The whole point: three policies in, three rows out.
        $rows.Count | Should -Be 3

        $never = $rows | Where-Object PolicyName -eq 'NeverAssigned'
        $never | Should -Not -BeNullOrEmpty
        $never.UserCount | Should -Be 0
    }

    It 'counts users with no explicit assignment toward Global' {
        $rows = InModuleScope Msec {
            Mock Get-CsTeamsMeetingPolicy -MockWith {
                @([pscustomobject]@{ Identity = 'Global' }, [pscustomobject]@{ Identity = 'Tag:Strict' })
            }
            Mock Get-CsOnlineUser -MockWith {
                @(
                    [pscustomobject]@{ UserPrincipalName = 'a@x.com'; TeamsMeetingPolicy = $null }
                    [pscustomobject]@{ UserPrincipalName = 'b@x.com'; TeamsMeetingPolicy = $null }
                    [pscustomobject]@{ UserPrincipalName = 'c@x.com'; TeamsMeetingPolicy = [pscustomobject]@{ Name = 'Strict' } }
                )
            }
            Get-MsecTeamsPolicyAssignment -PolicyType Meeting
        }

        # Teams reports "no assignment" as null, not as the string 'Global'.
        ($rows | Where-Object IsGlobal).UserCount | Should -Be 2
        ($rows | Where-Object PolicyName -eq 'Strict').UserCount | Should -Be 1
        ($rows | Where-Object IsGlobal).TotalUsers | Should -Be 3
    }

    It 'accepts a plain string assignment as well as a UserPolicyDefinition' {
        $rows = InModuleScope Msec {
            Mock Get-CsTeamsMeetingPolicy -MockWith { @([pscustomobject]@{ Identity = 'Tag:Strict' }) }
            Mock Get-CsOnlineUser -MockWith {
                # Older MicrosoftTeams versions hand back a bare string here.
                @([pscustomobject]@{ UserPrincipalName = 'a@x.com'; TeamsMeetingPolicy = 'Tag:Strict' })
            }
            Get-MsecTeamsPolicyAssignment -PolicyType Meeting
        }

        ($rows | Where-Object PolicyName -eq 'Strict').UserCount | Should -Be 1
    }

    It 'reports null, not zero, when the user list cannot be read' {
        $rows = InModuleScope Msec {
            Mock Get-CsTeamsMeetingPolicy -MockWith { @([pscustomobject]@{ Identity = 'Global' }) }
            Mock Get-CsOnlineUser -MockWith { throw 'Authorization has been denied for this request.' }
            Get-MsecTeamsPolicyAssignment -PolicyType Meeting -WarningAction SilentlyContinue
        }

        # 0 would claim the policy applies to no one. It is not a measurement at all.
        $rows.Count | Should -Be 1
        $rows[0].UserCount | Should -BeNullOrEmpty
        $rows[0].PercentOfUsers | Should -BeNullOrEmpty
        $rows[0].TotalUsers | Should -BeNullOrEmpty
        # The policy itself is still named, so the row is not silently dropped either.
        $rows[0].PolicyName | Should -Be 'Global'
    }

    It 'reports a policy area it could not list instead of omitting it' {
        $rows = InModuleScope Msec {
            Mock Get-CsTeamsMessagingPolicy -MockWith { throw 'Access denied' }
            Mock Get-CsOnlineUser -MockWith { @([pscustomobject]@{ UserPrincipalName = 'a@x.com'; TeamsMessagingPolicy = $null }) }
            Get-MsecTeamsPolicyAssignment -PolicyType Messaging -WarningAction SilentlyContinue
        }

        $rows.Count | Should -Be 1
        $rows[0].PolicyName | Should -Be 'Unreadable'
        $rows[0].UserCount | Should -BeNullOrEmpty
    }

    It 'returns only explicit assignments with -IncludeUser' {
        $rows = InModuleScope Msec {
            Mock Get-CsTeamsMeetingPolicy -MockWith { @([pscustomobject]@{ Identity = 'Global' }, [pscustomobject]@{ Identity = 'Tag:Strict' }) }
            Mock Get-CsOnlineUser -MockWith {
                @(
                    [pscustomobject]@{ UserPrincipalName = 'a@x.com'; AccountType = 'User'; TeamsMeetingPolicy = $null }
                    [pscustomobject]@{ UserPrincipalName = 'c@x.com'; AccountType = 'User'; TeamsMeetingPolicy = [pscustomobject]@{ Name = 'Strict' } }
                )
            }
            Get-MsecTeamsPolicyAssignment -PolicyType Meeting -IncludeUser
        }

        # The users on Global are the whole tenant and are not the exceptions anyone is after.
        $rows.Count | Should -Be 1
        $rows[0].UserPrincipalName | Should -Be 'c@x.com'
        $rows[0].PolicyName | Should -Be 'Strict'
    }

    It 'does not offer Federation or Client, which have no per-user assignment' {
        # They are tenant-wide configuration. Accepting them would imply a count exists.
        $valid = (Get-Command Get-MsecTeamsPolicyAssignment).Parameters['PolicyType'].Attributes |
                 Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                 Select-Object -ExpandProperty ValidValues

        $valid | Should -Not -Contain 'Federation'
        $valid | Should -Not -Contain 'Client'
        $valid | Should -Contain 'Meeting'
    }
}
