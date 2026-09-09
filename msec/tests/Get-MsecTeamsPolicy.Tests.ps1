#Requires -Module Pester
#
# Tests for Get-MsecTeamsPolicy and Connect-MsecTeams.
#
# Teams is the third workload msec reaches through someone else's module, and it has a wrinkle
# the other two do not: Connect-MicrosoftTeams -AccessTokens takes an ARRAY of two tokens, for
# Microsoft Graph and for the 'Skype and Teams Tenant Admin API'. They are separate audiences
# with separate app roles, and passing only the Graph one fails in a way that reads as a
# permission problem rather than a missing token.
#
# The other thing worth pinning: a policy area that cannot be read must produce a row saying so.
# A missing federation configuration reads as a tenant with no external access, which is the
# opposite of the truth.

$script:HasTeams = $null -ne (Get-Module -ListAvailable MicrosoftTeams)

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Connect-MsecTeams' -Skip:(-not $script:HasTeams) {

    BeforeEach {
        InModuleScope Msec {
            $script:MsecSession = @{
                TenantId = 't'; ClientId = 'client-1'; KeyVaultName = 'kv'; KeyName = 'k'
                ThumbprintBytes = [byte[]](1..20)
                Endpoints = @{ GraphResource = 'https://graph.microsoft.com'; EnvironmentName = 'AzureCloud' }
                Tokens = @{}
            }
        }
    }

    It 'passes two tokens, Graph first then the Teams admin API' {
        InModuleScope Msec {
            foreach ($r in 'https://graph.microsoft.com', '48ac35b8-9aa8-4d74-927d-1f4a14a0b239') {
                $script:MsecSession.Tokens[$r] = @{ Token = "tok-$r"; ExpiresOn = [DateTimeOffset]::UtcNow.AddMinutes(50) }
            }
            Mock Get-MsecAccessToken -MockWith { "tok-$Resource" }
            Mock Connect-MicrosoftTeams -MockWith { }

            Connect-MsecTeams

            # Both audiences, not just Graph.
            Should -Invoke Get-MsecAccessToken -Times 1 -Exactly -ParameterFilter { $Resource -eq 'https://graph.microsoft.com' }
            Should -Invoke Get-MsecAccessToken -Times 1 -Exactly -ParameterFilter { $Resource -eq '48ac35b8-9aa8-4d74-927d-1f4a14a0b239' }

            # Order matters - the module does not identify them by inspection.
            Should -Invoke Connect-MicrosoftTeams -Times 1 -Exactly -ParameterFilter {
                $AccessTokens.Count -eq 2 -and
                $AccessTokens[0] -eq 'tok-https://graph.microsoft.com' -and
                $AccessTokens[1] -eq 'tok-48ac35b8-9aa8-4d74-927d-1f4a14a0b239'
            }
        }
    }

    It 'names the Teams admin API when its token cannot be minted' {
        InModuleScope Msec {
            Mock Connect-MicrosoftTeams -MockWith { }
            Mock Get-MsecAccessToken -MockWith {
                if ($Resource -eq '48ac35b8-9aa8-4d74-927d-1f4a14a0b239') { throw 'AADSTS500011: resource principal not found' }
                'graph-token'
            }
            # Having Graph permissions and not the Teams resource ones is the state someone
            # will actually be in, so the message has to distinguish them.
            { Connect-MsecTeams } | Should -Throw '*Skype and Teams Tenant Admin API*'
        }
    }

    It 'borrows the Az session under -AsCurrentUser, so no interactive sign-in happens' {
        InModuleScope Msec {
            # The reason this mode exists: Connect-MicrosoftTeams's browser flow calls into
            # kernel32.dll and dies on macOS, and device code flow is refused by Conditional
            # Access policies requiring a compliant device. The Az session already cleared CA.
            $script:MsecSession = $null
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{
                    Account = [pscustomobject]@{ Id = 'me@contoso.com' }
                    Environment = [pscustomobject]@{ Name = 'AzureCloud'; ExtendedProperties = @{} }
                }
            }
            Mock Get-AzAccessToken -MockWith {
                [pscustomobject]@{ Token = "user-token-for-$ResourceUrl"; ExpiresOn = [DateTimeOffset]::UtcNow.AddHours(1) }
            }
            Mock Get-MsecAccessToken -MockWith { throw 'the app path must not be used here' }
            Mock Connect-MicrosoftTeams -MockWith { }

            Connect-MsecTeams -AsCurrentUser

            Should -Invoke Connect-MicrosoftTeams -Times 1 -Exactly -ParameterFilter {
                $AccessTokens.Count -eq 2 -and
                $AccessTokens[0] -eq 'user-token-for-https://graph.microsoft.com' -and
                $AccessTokens[1] -eq 'user-token-for-48ac35b8-9aa8-4d74-927d-1f4a14a0b239'
            }
        }
    }

    It 'unwraps a SecureString token, because Az.Accounts 5 returns one' {
        InModuleScope Msec {
            $script:MsecSession = $null
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{
                    Account = [pscustomobject]@{ Id = 'me@contoso.com' }
                    Environment = [pscustomobject]@{ Name = 'AzureCloud'; ExtendedProperties = @{} }
                }
            }
            Mock Get-AzAccessToken -MockWith {
                [pscustomobject]@{
                    Token     = (ConvertTo-SecureString 'secret-token' -AsPlainText -Force)
                    ExpiresOn = [DateTimeOffset]::UtcNow.AddHours(1)
                }
            }
            Mock Connect-MicrosoftTeams -MockWith { }

            Connect-MsecTeams -AsCurrentUser

            # -AccessTokens is String[]. Handing it the SecureString gives an authentication
            # failure with 'System.Security.SecureString' where the token should be - which
            # reads as a permission problem.
            Should -Invoke Connect-MicrosoftTeams -Times 1 -Exactly -ParameterFilter {
                $AccessTokens[0] -eq 'secret-token'
            }
        }
    }

    It 'refuses -AsCurrentUser with no Azure context' {
        InModuleScope Msec {
            $script:MsecSession = $null
            Mock Get-AzContext -MockWith { $null }
            { Connect-MsecTeams -AsCurrentUser } | Should -Throw '*Connect-AzAccount*'
        }
    }
    It 'throws a clear error when not connected' {
        InModuleScope Msec {
            $script:MsecSession = $null
            { Connect-MsecTeams } | Should -Throw '*Connect-Msec*'
        }
    }
}

Describe 'Get-MsecTeamsPolicy' -Skip:(-not $script:HasTeams) {

    BeforeEach {
        InModuleScope Msec {
            $script:MsecSession = $null
            # Module state outlives a Describe: the -AsCurrentUser tests above set this, and
            # without the reset it silently suppresses the self-connect being tested here.
            $script:MsecTeamsAsCurrentUser = $null
        }
    }

    It 'flattens to one row per setting, keeping only the security-relevant ones' {
        $rows = InModuleScope Msec {
            Mock Get-CsTenantFederationConfiguration -MockWith {
                [pscustomobject]@{
                    Identity = 'Global'
                    AllowFederatedUsers = $true
                    AllowPublicUsers = $false
                    AllowedDomains = @('partner.com', 'vendor.com')
                    # Not a security control - must not appear in the default projection.
                    TreatDiscoveredPartnersAsUnverified = $false
                }
            }
            Get-MsecTeamsPolicy -PolicyType Federation
        }

        # A meeting policy carries ~80 properties; returning whole objects hides the handful
        # that matter.
        @($rows | ForEach-Object { $_.Setting }) | Should -Contain 'AllowFederatedUsers'
        @($rows | ForEach-Object { $_.Setting }) | Should -Not -Contain 'TreatDiscoveredPartnersAsUnverified'

        # Collections are joined, not rendered as System.Object[].
        ($rows | Where-Object Setting -eq 'AllowedDomains').Value | Should -Be 'partner.com; vendor.com'
        ($rows | Where-Object Setting -eq 'AllowFederatedUsers').IsGlobal | Should -BeTrue
    }

    It 'returns everything under -All, so the projection can be checked' {
        $rows = InModuleScope Msec {
            Mock Get-CsTenantFederationConfiguration -MockWith {
                [pscustomobject]@{ Identity = 'Global'; AllowFederatedUsers = $true; TreatDiscoveredPartnersAsUnverified = $false }
            }
            Get-MsecTeamsPolicy -PolicyType Federation -All
        }

        # Which settings count as security controls is this command's judgement, so there has
        # to be a way to see what it left out.
        @($rows | ForEach-Object { $_.Setting }) | Should -Contain 'TreatDiscoveredPartnersAsUnverified'
    }

    It 'marks the Global policy, because that is the one a user gets by default' {
        $rows = InModuleScope Msec {
            Mock Get-CsTeamsMeetingPolicy -MockWith {
                [pscustomobject]@{ Identity = 'Global'; AllowAnonymousUsersToJoinMeeting = $true }
                [pscustomobject]@{ Identity = 'Tag:Restricted'; AllowAnonymousUsersToJoinMeeting = $false }
            }
            Get-MsecTeamsPolicy -PolicyType Meeting
        }

        # A permissive Global is a tenant-wide finding; a permissive custom policy may apply to
        # nobody at all.
        ($rows | Where-Object PolicyName -eq 'Global').IsGlobal     | Should -BeTrue
        ($rows | Where-Object PolicyName -eq 'Restricted').IsGlobal | Should -BeFalse
        # The 'Tag:' prefix is noise in a table.
        @($rows | ForEach-Object { $_.PolicyName }) | Should -Not -Contain 'Tag:Restricted'
    }

    It 'reports a policy area it could not read, rather than omitting it' {
        $warnings = @()
        $rows = InModuleScope Msec {
            Mock Get-CsTenantFederationConfiguration -MockWith { throw 'Access Denied' }
            Get-MsecTeamsPolicy -PolicyType Federation
        } -WarningVariable warnings -WarningAction SilentlyContinue

        # Silently omitting it would read as a tenant with no external access configured - the
        # opposite of the truth.
        @($rows).Count      | Should -Be 1
        $rows.PolicyName    | Should -Be 'Unreadable'
        ($warnings -join ' ') | Should -Match 'directory role'
    }

    It 'skips a setting the installed module version does not carry' {
        $rows = InModuleScope Msec {
            # The property set differs between module versions. Asking for an absent one would
            # emit a row of nulls that reads as "configured off".
            Mock Get-CsTeamsMeetingPolicy -MockWith {
                [pscustomobject]@{ Identity = 'Global'; AllowAnonymousUsersToJoinMeeting = $true }
            }
            Get-MsecTeamsPolicy -PolicyType Meeting
        }

        @($rows).Count | Should -Be 1
        @($rows | Where-Object { $null -eq $_.Value -and $_.PolicyName -ne 'Unreadable' }).Count | Should -Be 0
    }

    It 'reads the files policy, which is a different surface from the storage switches' {
        $rows = InModuleScope Msec {
            Mock Get-CsTeamsFilesPolicy -MockWith {
                [pscustomobject]@{
                    Identity = 'Global'
                    FileSharingInChatswithExternalUsers = 'Enabled'
                    DefaultFileUploadAppId = 'Dropbox'
                    NativeFileEntryPoints = 'Enabled'
                }
            }
            Get-MsecTeamsPolicy -PolicyType Files
        }

        # AllowDropBox and friends under Client say which providers APPEAR in Teams. This says
        # whether a file can leave the tenant through a chat with someone outside it - a tenant
        # can have every third-party provider off and still allow that.
        ($rows | Where-Object Setting -eq 'FileSharingInChatswithExternalUsers').Value | Should -Be 'Enabled'
        ($rows | Where-Object Setting -eq 'FileSharingInChatswithExternalUsers').IsGlobal | Should -BeTrue
        ($rows | Where-Object Setting -eq 'DefaultFileUploadAppId').Value | Should -Be 'Dropbox'
    }
    It 'signs in to Teams itself when there is an msec session' {
        InModuleScope Msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c' }
            Mock Connect-MsecTeams -MockWith { }
            Mock Get-CsTenantFederationConfiguration -MockWith {
                [pscustomobject]@{ Identity = 'Global'; AllowFederatedUsers = $true }
            }

            Get-MsecTeamsPolicy -PolicyType Federation | Out-Null

            # Without this the command ran straight into five failed Get-Cs* calls, each
            # warning about a directory role, when the real answer was that nobody had
            # connected. Every other command in this module is one call after Connect-Msec.
            Should -Invoke Connect-MsecTeams -Times 1 -Exactly
        }
    }

    It 'does not replace a session the caller deliberately opened as themselves' {
        InModuleScope Msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c' }
            $script:MsecTeamsAsCurrentUser = $true
            Mock Connect-MsecTeams -MockWith { }
            Mock Get-CsTenantFederationConfiguration -MockWith {
                [pscustomobject]@{ Identity = 'Global'; AllowFederatedUsers = $true }
            }

            Get-MsecTeamsPolicy -PolicyType Federation | Out-Null

            # Reconnecting as the app would swap a session that can write for one that cannot,
            # and the caller's next Set-Cs* would fail on rights they do have.
            Should -Invoke Connect-MsecTeams -Times 0 -Exactly
        }
    }
    It 'throws when there is neither a Teams session nor an msec session to make one' {
        InModuleScope Msec {
            # Get-Command finding the cmdlet only proves MicrosoftTeams is INSTALLED - it says
            # nothing about whether anyone connected. That was the original guard, and it let
            # an unconnected run through.
            Mock Get-Command -MockWith { $null } -ParameterFilter { $Name -eq 'Get-CsTenantFederationConfiguration' }
            { Get-MsecTeamsPolicy } | Should -Throw '*Connect-Msec*'
        }
    }

    It 'does not blame the directory role for a failure that is not about permissions' {
        $warnings = @()
        InModuleScope Msec {
            Mock Get-CsTenantFederationConfiguration -MockWith { throw 'The remote server returned 503' }
            Get-MsecTeamsPolicy -PolicyType Federation
        } -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

        # The hint is a guess. Offered against an authorisation error it is usually right;
        # offered against anything else it sends the reader to check a role they already have.
        ($warnings -join ' ') | Should -Not -Match 'directory role|DIRECTORY ROLE'
        ($warnings -join ' ') | Should -Match '503'
    }
}
