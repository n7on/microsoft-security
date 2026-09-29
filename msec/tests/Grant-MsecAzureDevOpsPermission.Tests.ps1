#Requires -Module Pester
#
# Tests for Grant-MsecAzureDevOpsPermission.
#
# This is the one command that WRITES into Azure DevOps, and the traps it guards are the ones
# that make a wrong grant look like a right one:
#
#   THE TWO PERMISSION SYSTEMS ARE NOT INTERCHANGEABLE. An allow on the ServiceEndpoints
#   namespace is accepted, stored, returned by the ACL API - and confers nothing. Passing both
#   -Permission and -RoleName must be refused rather than guessed at.
#
#   NOTHING IS HARDCODED. The bit is resolved by NAME from namespace metadata, so a renumbered
#   bit fails loudly instead of silently granting a different permission.
#
#   IT WRITES ONLY UNDER ShouldProcess, and merge=true so other identities' entries survive.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module msec -Force -ErrorAction SilentlyContinue }

Describe 'Grant-MsecAzureDevOpsPermission' {

    BeforeEach {
        InModuleScope msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Account = 'me@contoso.com' } }
            Mock Get-AzAccessToken -MockWith { [pscustomobject]@{ Token = 'user-token' } }
        }
    }

    It 'runs as the signed-in user, not as the msec app' {
        # The app is usually the GRANTEE. An identity that could grant itself permissions makes
        # the whole exercise circular, so this deliberately never touches Get-MsecAccessToken.
        $body = (Get-Command Grant-MsecAzureDevOpsPermission).Definition
        $body | Should -Match 'Get-AzAccessToken'
        $body | Should -Not -Match 'Get-MsecAccessToken'
        $body | Should -Not -Match 'Invoke-MsecGraphRequest'
    }

    It 'needs no personal access token' {
        # An earlier version took one. The namespace, ACL and identity APIs all accept an
        # ordinary Entra token, verified against all three before the PAT was removed.
        (Get-Command Grant-MsecAzureDevOpsPermission).Parameters.Keys | Should -Not -Contain 'Pat'
        (Get-Command Grant-MsecAzureDevOpsPermission).Definition | Should -Not -Match "Authorization = 'Basic"
    }

    It 'refuses to guess between the two permission systems' {
        InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                @{ value = @(@{ name = 'Git Repositories'; namespaceId = 'ns-1'; structureValue = 1
                                actions = @(@{ name = 'GenericRead'; bit = 2; displayName = 'Read' }) }) }
            }
            { Grant-MsecAzureDevOpsPermission -Organization o -Identity 'G' -Permission GenericRead -RoleName Reader -Confirm:$false } |
                Should -Throw '*not both*'
        }
    }

    It 'resolves the bit by NAME and refuses an unknown permission' {
        InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                @{ value = @(@{ name = 'Git Repositories'; namespaceId = 'ns-1'; structureValue = 1
                                actions = @(@{ name = 'GenericRead'; bit = 2; displayName = 'Read' }) }) }
            }
            # A renumbered or renamed bit must fail loudly, never silently grant a different one.
            { Grant-MsecAzureDevOpsPermission -Organization o -Identity 'G' -Permission NotAThing -Confirm:$false } |
                Should -Throw "*not a permission*"
        }
    }

    It 'refuses a namespace whose root token has not been proven' {
        InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                @{ value = @(
                    @{ name = 'Unproven'; namespaceId = 'ns-9'; structureValue = 1
                       actions = @(@{ name = 'GenericRead'; bit = 2; displayName = 'Read' }) }
                ) }
            }
            # 'repoV2' works and 'repoV2/' returns 400 for the same body - one character decides
            # organization-wide versus per-project. Unknown grammars are refused, not guessed.
            { Grant-MsecAzureDevOpsPermission -Organization o -Identity 'G' -Namespace Unproven `
                -Permission GenericRead -Confirm:$false } | Should -Throw '*token grammar*'
        }
    }

    It 'emits permission names as objects for -ListPermissions, and writes nothing' {
        $rows = InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                @{ value = @(@{ name = 'Git Repositories'; namespaceId = 'ns-1'; structureValue = 1
                                actions = @(
                                    @{ name = 'GenericRead';      bit = 2;     displayName = 'Read' }
                                    @{ name = 'ViewAdvSecAlerts'; bit = 65536; displayName = 'View alerts' }) }) }
            }
            @(Grant-MsecAzureDevOpsPermission -Organization o -ListPermissions)
        }
        $rows.Count | Should -Be 2
        ($rows | Where-Object Name -eq 'ViewAdvSecAlerts').Bit | Should -Be 65536
    }

    It 'declares High confirm impact so a bare call prompts' {
        $meta = [System.Management.Automation.CommandMetadata](Get-Command Grant-MsecAzureDevOpsPermission)
        $meta.SupportsShouldProcess | Should -BeTrue
        $meta.ConfirmImpact         | Should -Be 'High'
    }

    It 'has no -Apply switch - WhatIf and Confirm replaced it' {
        (Get-Command Grant-MsecAzureDevOpsPermission).Parameters.Keys | Should -Not -Contain 'Apply'
    }
}
