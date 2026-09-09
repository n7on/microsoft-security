#Requires -Module Pester
#
# Tests for Get-MsecAzureDevOpsUser and the Invoke-MsecAzureDevOpsRequest helper behind it.
#
# The bug worth guarding hardest is pagination. The ADO graph APIs put the cursor in the
# X-MS-ContinuationToken RESPONSE HEADER, not in the body. Code that reads $response.value gets
# page one, no error, and no sign there was more - and in an access review the users that go
# missing look exactly like users who do not exist. The Reporting repo's version had this.
#
# The other two: a user in no group must still appear, and a user whose memberships could not be
# read must be distinguishable from one who genuinely has none.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureDevOpsUser' {

    BeforeEach {
        InModuleScope Msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-MsecAccessToken -MockWith { 'ADO.TOKEN' }

            # Shapes a response the way Azure DevOps returns one: a JSON body, and the paging
            # cursor in a HEADER rather than in the body. Defined inside the module scope so the
            # mock bodies - which also run there - can see it.
            function script:New-AdoResponse {
                param($Value, [string] $ContinuationToken)
                $headers = @{}
                if ($ContinuationToken) { $headers['X-MS-ContinuationToken'] = @($ContinuationToken) }
                [pscustomobject]@{
                    Content = (@{ value = @($Value) } | ConvertTo-Json -Depth 6)
                    Headers = $headers
                }
            }

            function script:New-AdoUser {
                param([string] $Descriptor, [string] $Name, [string] $Principal, [string] $Origin = 'aad')
                [pscustomobject]@{
                    descriptor = $Descriptor; displayName = $Name; principalName = $Principal
                    origin = $Origin; subjectKind = 'user'
                }
            }
        }
    }

    It 'follows the continuation header instead of stopping at page one' {
        $rows = InModuleScope Msec {
            Mock Invoke-WebRequest -MockWith {
                if ($Uri -match '/graph/groups') {
                    return New-AdoResponse -Value @([pscustomobject]@{ descriptor = 'g1'; displayName = 'Contributors'; principalName = '[org]\Contributors' })
                }
                if ($Uri -match '/graph/users') {
                    if ($Uri -match 'continuationToken=') {
                        return New-AdoResponse -Value @(New-AdoUser -Descriptor 'u2' -Name 'Page Two' -Principal 'two@contoso.com')
                    }
                    return New-AdoResponse -Value @(New-AdoUser -Descriptor 'u1' -Name 'Page One' -Principal 'one@contoso.com') -ContinuationToken 'CURSOR'
                }
                return New-AdoResponse -Value @([pscustomobject]@{ containerDescriptor = 'g1' })
            }
            Get-MsecAzureDevOpsUser -Organization 'contoso'
        }

        # Two users across two pages. Reading page one only returns one of them, with no error
        # and nothing to indicate the other exists.
        @($rows | ForEach-Object { $_.DisplayName }) | Should -Contain 'Page One'
        @($rows | ForEach-Object { $_.DisplayName }) | Should -Contain 'Page Two'
        ($rows | Where-Object DisplayName -eq 'Page Two').Group | Should -Be 'Contributors'
    }

    It 'resolves group names from one fetch, not one call per membership' {
        InModuleScope Msec {
            Mock Invoke-WebRequest -MockWith {
                if ($Uri -match '/graph/groups') {
                    return New-AdoResponse -Value @(
                        [pscustomobject]@{ descriptor = 'g1'; displayName = 'Project Collection Administrators'; principalName = '[org]\PCA' }
                        [pscustomobject]@{ descriptor = 'g2'; displayName = 'Contributors'; principalName = '[org]\Contributors' })
                }
                if ($Uri -match '/graph/users') {
                    return New-AdoResponse -Value @(
                        (New-AdoUser -Descriptor 'u1' -Name 'A' -Principal 'a@contoso.com'),
                        (New-AdoUser -Descriptor 'u2' -Name 'B' -Principal 'b@contoso.com'))
                }
                return New-AdoResponse -Value @(
                    [pscustomobject]@{ containerDescriptor = 'g1' }
                    [pscustomobject]@{ containerDescriptor = 'g2' })
            }

            Get-MsecAzureDevOpsUser -Organization 'contoso' | Out-Null

            # One groups call, one users call, one memberships call per user. Fetching the group
            # per membership - the direct translation - would add four more here, and thousands
            # on a real organization for a few dozen distinct groups.
            Should -Invoke Invoke-WebRequest -Times 4 -Exactly
        }
    }

    It 'does not filter by subjectTypes unless asked, because the obvious value returns nothing' {
        InModuleScope Msec {
            Mock Invoke-WebRequest -MockWith {
                if ($Uri -match '/graph/groups') { return New-AdoResponse -Value @() }
                if ($Uri -match '/graph/users')  { return New-AdoResponse -Value @(New-AdoUser -Descriptor 'u1' -Name 'A' -Principal 'a@contoso.com') }
                return New-AdoResponse -Value @()
            }

            Get-MsecAzureDevOpsUser -Organization 'contoso' | Out-Null

            # subjectTypes takes SUBTYPE codes - aad, msa, svc, imp - not subject kinds.
            # 'subjectTypes=user' is not rejected: it matches no subtype and returns an empty
            # list, indistinguishable from an organization the app cannot read.
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -match '/graph/users' -and $Uri -notmatch 'subjectTypes'
            }
        }
    }

    It 'passes the subtype codes through when one is asked for' {
        InModuleScope Msec {
            Mock Invoke-WebRequest -MockWith {
                if ($Uri -match '/graph/groups') { return New-AdoResponse -Value @() }
                if ($Uri -match '/graph/users')  { return New-AdoResponse -Value @(New-AdoUser -Descriptor 'u1' -Name 'Svc' -Principal 'svc' -Origin 'vsts') }
                return New-AdoResponse -Value @()
            }

            Get-MsecAzureDevOpsUser -Organization 'contoso' -SubjectType svc | Out-Null

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -match 'subjectTypes=svc'
            }
        }
    }
    It 'puts the descriptor in the memberships URL, where PowerShell nearly ate it' {
        InModuleScope Msec {
            Mock Invoke-WebRequest -MockWith {
                if ($Uri -match '/graph/groups') { return New-AdoResponse -Value @() }
                if ($Uri -match '/graph/users')  { return New-AdoResponse -Value @(New-AdoUser -Descriptor 'aad.ABC123' -Name 'A' -Principal 'a@contoso.com') }
                return New-AdoResponse -Value @()
            }

            Get-MsecAzureDevOpsUser -Organization 'contoso' | Out-Null

            # '?' is a legal PowerShell variable-name character, so "$descriptor?direction=up"
            # parses as the variable 'descriptor?direction' - undefined, therefore empty - and
            # the URL becomes '_apis/graph/memberships/=up'. Every user then 404s, which reads
            # like a missing identity rather than a mangled request.
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -match '/graph/memberships/aad\.ABC123\?direction=up'
            }
        }
    }
    It 'names the group, and says so when a container is not in the group list' {
        $rows = InModuleScope Msec {
            Mock Invoke-WebRequest -MockWith {
                if ($Uri -match '/graph/groups') { return New-AdoResponse -Value @() }
                if ($Uri -match '/graph/users')  { return New-AdoResponse -Value @(New-AdoUser -Descriptor 'u1' -Name 'A' -Principal 'a@contoso.com') }
                return New-AdoResponse -Value @([pscustomobject]@{ containerDescriptor = 'mystery' })
            }
            Get-MsecAzureDevOpsUser -Organization 'contoso'
        }

        # The membership is real whether or not the container resolved, so it must not read as
        # a user with no group.
        $rows.Group | Should -Be '(unresolved: mystery)'
    }

    It 'keeps a user who belongs to no group at all' {
        $rows = InModuleScope Msec {
            Mock Invoke-WebRequest -MockWith {
                if ($Uri -match '/graph/groups') { return New-AdoResponse -Value @() }
                if ($Uri -match '/graph/users')  { return New-AdoResponse -Value @(New-AdoUser -Descriptor 'u1' -Name 'Lonely' -Principal 'l@contoso.com') }
                return New-AdoResponse -Value @()
            }
            Get-MsecAzureDevOpsUser -Organization 'contoso'
        }

        # Emitting nothing would drop the account from the review entirely.
        @($rows).Count | Should -Be 1
        $rows.Group    | Should -Be '(none)'
    }

    It 'distinguishes memberships it could not read from memberships that are absent' {
        $warnings = @()
        $rows = InModuleScope Msec {
            Mock Invoke-WebRequest -MockWith {
                if ($Uri -match '/graph/groups') { return New-AdoResponse -Value @() }
                if ($Uri -match '/graph/users')  { return New-AdoResponse -Value @(New-AdoUser -Descriptor 'u1' -Name 'A' -Principal 'a@contoso.com') }
                throw 'boom'
            }
            Get-MsecAzureDevOpsUser -Organization 'contoso'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        # '(none)' would claim this account has no access. That is a claim we did not verify.
        $rows.Group | Should -Be '(unreadable)'
        ($warnings -join ' ') | Should -Match 'a@contoso.com'
    }

    It 'surfaces accounts that exist only inside Azure DevOps' {
        $rows = InModuleScope Msec {
            Mock Invoke-WebRequest -MockWith {
                if ($Uri -match '/graph/groups') { return New-AdoResponse -Value @() }
                if ($Uri -match '/graph/users')  { return New-AdoResponse -Value @(New-AdoUser -Descriptor 'u1' -Name 'Local' -Principal 'local' -Origin 'vsts') }
                return New-AdoResponse -Value @()
            }
            Get-MsecAzureDevOpsUser -Organization 'contoso'
        }

        # A 'vsts' account has no Conditional Access and no leaver process behind it.
        $rows.Origin | Should -Be 'vsts'
    }

    It 'warns rather than returning nothing when the identity graph is empty' {
        $warnings = @()
        $rows = InModuleScope Msec {
            Mock Invoke-WebRequest -MockWith { New-AdoResponse -Value @() }
            Get-MsecAzureDevOpsUser -Organization 'contoso'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        # An app that authenticates but cannot read the identity graph gets an empty list, which
        # would otherwise read as an organization with nobody in it.
        @($rows).Count | Should -Be 0
        ($warnings -join ' ') | Should -Match 'unread'
    }

    It 'explains a 401 as ADO membership, not as an Entra permission' {
        InModuleScope Msec {
            Mock Invoke-WebRequest -MockWith { throw 'Response status code does not indicate success: 401 (Unauthorized).' }
            # New-MsecApp cannot fix this one - the access is granted inside Azure DevOps - so an
            # error pointing at Entra permissions sends the reader somewhere useless.
            { Get-MsecAzureDevOpsUser -Organization 'contoso' } | Should -Throw '*Organization Settings*'
        }
    }

    It 'distinguishes a token failure from a membership failure' {
        InModuleScope Msec {
            Mock Get-MsecAccessToken -MockWith { throw 'certificate expired' }
            { Get-MsecAzureDevOpsUser -Organization 'contoso' } | Should -Throw '*Entra-side*'
        }
    }

    It 'throws a clear error when not connected' {
        InModuleScope Msec {
            $script:MsecSession = $null
            { Get-MsecAzureDevOpsUser -Organization 'contoso' } | Should -Throw '*Connect-Msec*'
        }
    }
}
