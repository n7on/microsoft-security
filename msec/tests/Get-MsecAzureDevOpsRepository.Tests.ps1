#Requires -Module Pester
#
# Tests for Get-MsecAzureDevOpsRepository.
#
# The policy shape below was captured from a live organization: settings.scope carries a
# repositoryId (null meaning every repository in the project), a refName (empty meaning the whole
# repository) and a matchKind of Exact or Prefix.
#
# Three things worth pinning:
#
#   isBlocking decides whether a policy is protection. Azure DevOps allows enabled-but-advisory
#   policies that show in a pull request and stop nothing; counting those as protection
#   overstates the posture.
#
#   A project-wide policy protects a repository as surely as a per-repository one, so a null
#   repositoryId must match. Measured live, a single project-wide secrets-scanning rule applied
#   to every repository - which is why -Unprotected means "no reviewer requirement" rather than
#   "no blocking policy", a measure under which nothing was ever unprotected.
#
#   Policies that could not be read report $null, never 0. A project whose policies 403 must not
#   make its repositories look unprotected.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureDevOpsRepository' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }

            function script:New-Repo {
                param([string] $Id = 'r1', [string] $Name = 'Repo', [string] $Branch = 'refs/heads/main', [switch] $Disabled)
                [pscustomobject]@{
                    id = $Id; name = $Name; defaultBranch = $Branch; size = 5MB; isDisabled = [bool]$Disabled
                    project = [pscustomobject]@{ id = 'p1'; name = 'Platform' }
                }
            }

            function script:New-Policy {
                param(
                    [string] $Type, [hashtable] $Settings = @{}, [string] $RepoId = 'r1',
                    [string] $Ref = 'refs/heads/main', [string] $Match = 'Exact',
                    [bool] $Enabled = $true, [bool] $Blocking = $true
                )
                $Settings['scope'] = @([pscustomobject]@{ repositoryId = $RepoId; refName = $Ref; matchKind = $Match })
                [pscustomobject]@{
                    isEnabled = $Enabled; isBlocking = $Blocking
                    type = [pscustomobject]@{ displayName = $Type }
                    settings = [pscustomobject]$Settings
                }
            }

            function script:Set-RepoMock {
                param($Repos, $Policies, $Enablement = @(), [switch] $PolicyFails)
                Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                    if ($Path -eq '_apis/git/repositories') { return $Repos }
                    if ($Path -eq '_apis/management/enablement') { return [pscustomobject]@{ reposEnablementStatus = $Enablement } }
                    if ($Path -match '/_apis/policy/configurations') {
                        if ($PolicyFails) { throw 'Response status code does not indicate success: 403 (Forbidden).' }
                        return $Policies
                    }
                    return @()
                }
            }
        }
    }

    It 'counts a blocking policy as protection and an advisory one as not' {
        $rows = InModuleScope msec {
            . Set-RepoMock -Repos @(New-Repo) -Policies @(
                (New-Policy -Type 'Minimum number of reviewers' -Settings @{ minimumApproverCount = 2; creatorVoteCounts = $false })
                (New-Policy -Type 'Build' -Blocking $false)
            )
            Get-MsecAzureDevOpsRepository -Organization 'contoso'
        }

        $rows.MinimumReviewers | Should -Be 2
        # Enabled but not blocking: it shows in the pull request and stops nothing.
        $rows.RequireBuildValidation | Should -BeFalse
        $rows.PolicyCount         | Should -Be 2
        $rows.BlockingPolicyCount | Should -Be 1
    }

    It 'applies a project-wide policy to every repository' {
        $rows = InModuleScope msec {
            . Set-RepoMock -Repos @((New-Repo -Id 'r1' -Name 'One'), (New-Repo -Id 'r2' -Name 'Two')) `
                           -Policies @(New-Policy -Type 'Secrets scanning restriction' -RepoId $null -Ref '')
            Get-MsecAzureDevOpsRepository -Organization 'contoso'
        }

        # A null repositoryId means the whole project; an empty ref means the whole repository.
        @($rows | Where-Object BlockSecretPush).Count | Should -Be 2
    }

    It 'matches a prefix-scoped policy against the default branch' {
        $rows = InModuleScope msec {
            . Set-RepoMock -Repos @(New-Repo -Branch 'refs/heads/main') `
                           -Policies @(New-Policy -Type 'Minimum number of reviewers' -Settings @{ minimumApproverCount = 1 } -Ref 'refs/heads/' -Match 'Prefix')
            Get-MsecAzureDevOpsRepository -Organization 'contoso'
        }

        $rows.MinimumReviewers | Should -Be 1
    }

    It 'ignores a policy scoped to another branch' {
        $rows = InModuleScope msec {
            . Set-RepoMock -Repos @(New-Repo -Branch 'refs/heads/main') `
                           -Policies @(New-Policy -Type 'Minimum number of reviewers' -Settings @{ minimumApproverCount = 3 } -Ref 'refs/heads/release')
            Get-MsecAzureDevOpsRepository -Organization 'contoso'
        }

        # Protecting release says nothing about main.
        $rows.MinimumReviewers | Should -Be 0
    }

    It 'flags a reviewer policy the author can satisfy alone' {
        $rows = InModuleScope msec {
            . Set-RepoMock -Repos @(New-Repo) `
                           -Policies @(New-Policy -Type 'Minimum number of reviewers' -Settings @{ minimumApproverCount = 1; creatorVoteCounts = $true })
            Get-MsecAzureDevOpsRepository -Organization 'contoso'
        }

        # One reviewer, and the author's own vote counts: a self-approved pull request is a
        # direct push with more steps.
        $rows.MinimumReviewers    | Should -Be 1
        $rows.SelfApprovalAllowed | Should -BeTrue
    }

    It 'names blocking policy types it has no column for' {
        $rows = InModuleScope msec {
            . Set-RepoMock -Repos @(New-Repo) -Policies @(
                (New-Policy -Type 'Reserved names restriction')
                (New-Policy -Type 'Path Length restriction')
                (New-Policy -Type 'Build'))
            Get-MsecAzureDevOpsRepository -Organization 'contoso'
        }

        # Azure DevOps adds policy types and organizations write custom ones. A report with a
        # column per known type silently drops the rest - and these two turned up on a live
        # organization that a twelve-project sample had not shown.
        $rows.OtherPolicies | Should -Be 'Path Length restriction; Reserved names restriction'
        # Something with a column of its own must not also appear here.
        $rows.OtherPolicies | Should -Not -Match 'Build'
    }

    It 'reports every reviewer setting, not only the count' {
        $rows = InModuleScope msec {
            . Set-RepoMock -Repos @(New-Repo) -Policies @(
                New-Policy -Type 'Minimum number of reviewers' -Settings @{
                    minimumApproverCount = 2; creatorVoteCounts = $false; blockLastPusherVote = $true
                    resetOnSourcePush = $true; requireVoteOnLastIteration = $true
                    resetRejectionsOnSourcePush = $false; allowDownvotes = $false
                    requireVoteOnEachIteration = $false })
            Get-MsecAzureDevOpsRepository -Organization 'contoso'
        }

        # Each of these is a way a nominally-reviewed change reaches main unreviewed, and a
        # tenant that happens to have them all set is not a reason to stop reporting them.
        $rows.BlockLastPusherVote        | Should -BeTrue
        $rows.ResetVotesOnPush           | Should -BeTrue
        $rows.RequireVoteOnLastIteration | Should -BeTrue
        $rows.ResetRejectionsOnPush      | Should -BeFalse
        $rows.AllowDownvotes             | Should -BeFalse
    }

    It 'counts named required reviewers separately from the minimum' {
        $rows = InModuleScope msec {
            . Set-RepoMock -Repos @(New-Repo) -Policies @(
                (New-Policy -Type 'Minimum number of reviewers' -Settings @{ minimumApproverCount = 1 })
                (New-Policy -Type 'Required reviewers' -Settings @{ requiredReviewerIds = @('a', 'b') }))
            Get-MsecAzureDevOpsRepository -Organization 'contoso'
        }

        # "one approver" and "these two people must approve" are different controls.
        $rows.MinimumReviewers  | Should -Be 1
        $rows.RequiredReviewers | Should -Be 2
    }
    It 'reports $null, not 0, when policies could not be read' {
        $warnings = @()
        $rows = InModuleScope msec {
            . Set-RepoMock -Repos @(New-Repo) -Policies @() -PolicyFails
            Get-MsecAzureDevOpsRepository -Organization 'contoso'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        # 0 would mean "no reviewers required", which is a claim about the repository. $null
        # means we did not find out.
        $rows.MinimumReviewers    | Should -BeNullOrEmpty
        $rows.BlockingPolicyCount | Should -BeNullOrEmpty
        ($warnings -join ' ')     | Should -Match 'rather than none'
    }

    It 'excludes unread repositories from -Unprotected' {
        $rows = InModuleScope msec {
            . Set-RepoMock -Repos @(New-Repo) -Policies @() -PolicyFails
            Get-MsecAzureDevOpsRepository -Organization 'contoso' -Unprotected
        } -WarningAction SilentlyContinue

        # A repository whose policies could not be read is not evidence of being unprotected.
        @($rows).Count | Should -Be 0
    }

    It 'selects only repositories with no reviewer requirement under -Unprotected' {
        $rows = InModuleScope msec {
            . Set-RepoMock -Repos @((New-Repo -Id 'r1' -Name 'Guarded'), (New-Repo -Id 'r2' -Name 'Open')) `
                           -Policies @(
                                (New-Policy -Type 'Minimum number of reviewers' -Settings @{ minimumApproverCount = 1 } -RepoId 'r1')
                                (New-Policy -Type 'Secrets scanning restriction' -RepoId $null -Ref ''))
            Get-MsecAzureDevOpsRepository -Organization 'contoso' -Unprotected
        }

        # 'Open' has a blocking policy - the project-wide secret rule - and still requires no
        # reviewer. Measuring protection as "any blocking policy" would have hidden it.
        @($rows).Count   | Should -Be 1
        $rows.Repository | Should -Be 'Open'
    }

    It 'warns rather than returning nothing when no repository is readable' {
        $warnings = @()
        $rows = InModuleScope msec {
            . Set-RepoMock -Repos @() -Policies @()
            Get-MsecAzureDevOpsRepository -Organization 'contoso'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        @($rows).Count | Should -Be 0
        ($warnings -join ' ') | Should -Match 'nothing was read'
    }

    It 'throws a clear error when not connected' {
        InModuleScope msec {
            $script:MsecSession = $null
            { Get-MsecAzureDevOpsRepository -Organization 'contoso' } | Should -Throw '*Connect-Msec*'
        }
    }
}
