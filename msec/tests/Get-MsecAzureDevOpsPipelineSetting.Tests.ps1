#Requires -Module Pester
#
# Tests for Get-MsecAzureDevOpsPipelineSetting.
#
# Two things worth protecting.
#
# SecretsWithheldFromForks is named for the SAFE state while the API field it comes from,
# enforceNoAccessToSecretsFromForks, is a double negative. Getting that backwards would report an
# organization as safe when it is not, so the mapping is asserted rather than assumed.
#
# OtherSettings must name what has no column. On the first run against a live organization it
# surfaced enforceReferencedRepoScopedToken, which varied between projects and has since been
# promoted - that is the mechanism working, and it only works if unknown keys survive.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureDevOpsPipelineSetting' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }

            function script:Set-SettingsMock {
                param([hashtable] $Settings = @{}, [switch] $Fail)
                $script:MockSettings = [pscustomobject]$Settings
                $script:MockFail = [bool] $Fail
                Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                    if ($Path -eq '_apis/projects') { return @([pscustomobject]@{ id = 'p1'; name = 'Platform' }) }
                    if ($Path -match '/generalsettings$') {
                        if ($script:MockFail) { throw 'Response status code does not indicate success: 403 (Forbidden).' }
                        return $script:MockSettings
                    }
                    return @()
                }
            }
        }
    }

    It 'reports the fork settings separately, not as one verdict' {
        $rows = InModuleScope msec {
            . Set-SettingsMock -Settings @{
                forkProtectionEnabled             = $true
                buildsEnabledForForks             = $true
                enforceNoAccessToSecretsFromForks = $true
                enforceJobAuthScopeForForks       = $false
            }
            Get-MsecAzureDevOpsPipelineSetting -Organization 'contoso'
        }

        # Builds of forks being enabled is only dangerous if secrets are also available to them.
        # Collapsing the two into one column would lose which half to fix.
        $rows.BuildsEnabledForForks    | Should -BeTrue
        $rows.SecretsWithheldFromForks | Should -BeTrue
        $rows.ForkJobAuthScopeLimited  | Should -BeFalse
    }

    It 'maps the double-negative fork secret field to the safe-state name' {
        $rows = InModuleScope msec {
            # enforceNoAccessToSecretsFromForks = false means secrets ARE reachable from forks.
            . Set-SettingsMock -Settings @{ buildsEnabledForForks = $true; enforceNoAccessToSecretsFromForks = $false }
            Get-MsecAzureDevOpsPipelineSetting -Organization 'contoso'
        }

        # Reading this backwards would report the dangerous configuration as the safe one.
        $rows.SecretsWithheldFromForks | Should -BeFalse
    }

    It 'names settings it has no column for, with their values' {
        $rows = InModuleScope msec {
            . Set-SettingsMock -Settings @{
                enforceJobAuthScope = $true
                somethingAddedLastWeek = $true
                anotherNewKnob = $false
            }
            Get-MsecAzureDevOpsPipelineSetting -Organization 'contoso'
        }

        # Azure DevOps adds settings here. A column-per-known-key report loses them silently.
        $rows.OtherSettings | Should -Match 'somethingAddedLastWeek=True'
        $rows.OtherSettings | Should -Match 'anotherNewKnob=False'
        # Something with a column of its own must not also appear.
        $rows.OtherSettings | Should -Not -Match 'enforceJobAuthScope'
    }

    It 'reports the job token scoping settings' {
        $rows = InModuleScope msec {
            . Set-SettingsMock -Settings @{
                enforceJobAuthScope              = $true
                enforceJobAuthScopeForReleases   = $false
                enforceReferencedRepoScopedToken = $true
            }
            Get-MsecAzureDevOpsPipelineSetting -Organization 'contoso'
        }

        $rows.JobAuthScopeLimited             | Should -BeTrue
        $rows.JobAuthScopeLimitedForReleases  | Should -BeFalse
        $rows.ReferencedRepoScopedToken       | Should -BeTrue
    }

    It 'reports a project whose settings could not be read' {
        $warnings = @()
        $rows = InModuleScope msec {
            . Set-SettingsMock -Fail
            Get-MsecAzureDevOpsPipelineSetting -Organization 'contoso'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        # A project that refused must not be absent without explanation - and must certainly not
        # read as configured safely.
        @($rows).Count | Should -Be 0
        ($warnings -join ' ') | Should -Match 'not as configured safely'
    }

    It 'throws a clear error when not connected' {
        InModuleScope msec {
            $script:MsecSession = $null
            { Get-MsecAzureDevOpsPipelineSetting -Organization 'contoso' } | Should -Throw '*Connect-Msec*'
        }
    }
}
