#Requires -Module Pester
#
# Tests for Get-MsecAzureDevOpsAlert.
#
# The alert shape below was captured from a live organization, not invented - the field list,
# the nested physicalLocations/tools arrays, and truncatedSecret are all real.
#
# Three things worth pinning hardest:
#
#   The repository list comes from ENABLEMENT, not from the git API. _apis/git/repositories
#   returns only what the caller can see, with a 200 - an app saw 95 repositories where a person
#   saw 220 - so building the work list from it silently skips repositories.
#
#   A repository that refuses its alerts is COUNTED AND NAMED. Alerts 403 rather than returning
#   an empty list, which is what makes this command trustworthy; measured live, 42 of 87 enabled
#   repositories refused.
#
#   truncatedSecret is NEVER emitted. It holds a fragment of the credential that was found, and
#   this output goes into mailboxes and spreadsheets.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureDevOpsAlert' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }

            function script:New-Alert {
                param([int] $Id, [string] $Type = 'secret', [string] $Sev = 'critical', [string] $State = 'active', [int] $AgeDays = 41)
                [pscustomobject]@{
                    alertId           = $Id
                    alertType         = $Type
                    severity          = $Sev
                    state             = $State
                    confidence        = 'high'
                    title             = 'LaunchDarkly API key'
                    firstSeenDate     = [DateTime]::UtcNow.AddDays(-$AgeDays)
                    lastSeenDate      = [DateTime]::UtcNow.AddDays(-$AgeDays)
                    fixedDate         = $null
                    isAutoFixable     = $false
                    truncatedSecret   = 'sdk-abc123...'
                    tools             = @([pscustomobject]@{ name = 'CredScan'; rules = @() })
                    physicalLocations = @([pscustomobject]@{ filePath = 'src/appsettings.json' })
                }
            }

            # Stands in for the ADO request helper so each route can be answered by path.
            function script:Set-AdoMock {
                param($Enabled, $Repos, $Alerts, [string[]] $Refuse = @())
                Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                    if ($Path -eq '_apis/management/enablement') {
                        return [pscustomobject]@{ reposEnablementStatus = $Enabled }
                    }
                    if ($Path -eq '_apis/git/repositories') { return $Repos }
                    if ($Path -match '/_apis/alert/repositories/([^/]+)/alerts') {
                        if ($Matches[1] -in $Refuse) { throw 'Response status code does not indicate success: 403 (Forbidden).' }
                        return $Alerts
                    }
                    return @()
                }
            }
        }
    }

    It 'builds the work list from enablement, not from the git repository list' {
        InModuleScope msec {
            # Two repositories have scanning on; the git API can only see one of them.
            . Set-AdoMock -Enabled @(
                [pscustomobject]@{ projectId = 'p1'; repositoryId = 'r1'; advSecEnabled = $true }
                [pscustomobject]@{ projectId = 'p1'; repositoryId = 'r2'; advSecEnabled = $true }
            ) -Repos @(
                [pscustomobject]@{ id = 'r1'; name = 'Visible'; project = [pscustomobject]@{ id = 'p1'; name = 'Platform' } }
            ) -Alerts @(New-Alert -Id 1)

            $rows = @(Get-MsecAzureDevOpsAlert -Organization 'contoso' -WarningAction SilentlyContinue)

            # Both repositories are queried. Driving off the git list would have dropped r2
            # entirely - with a 200, so nothing would have said so.
            @($rows).Count | Should -Be 2
            # And the one whose name could not be resolved is reported by id, not skipped.
            @($rows | Where-Object Repository -eq 'r2').Count | Should -Be 1
        }
    }

    It 'skips repositories where scanning is switched off' {
        InModuleScope msec {
            . Set-AdoMock -Enabled @(
                [pscustomobject]@{ projectId = 'p1'; repositoryId = 'r1'; advSecEnabled = $true }
                [pscustomobject]@{ projectId = 'p1'; repositoryId = 'r2'; advSecEnabled = $false }
            ) -Repos @() -Alerts @(New-Alert -Id 1)

            @(Get-MsecAzureDevOpsAlert -Organization 'contoso' -WarningAction SilentlyContinue).Count | Should -Be 1
        }
    }

    It 'never emits the secret fragment' {
        $rows = InModuleScope msec {
            . Set-AdoMock -Enabled @([pscustomobject]@{ projectId = 'p1'; repositoryId = 'r1'; advSecEnabled = $true }) `
                        -Repos @() -Alerts @(New-Alert -Id 1)
            Get-MsecAzureDevOpsAlert -Organization 'contoso' -WarningAction SilentlyContinue
        }

        # The API returns truncatedSecret. This output reaches mailboxes and spreadsheets, so a
        # partial credential in it is a second exposure.
        $rows[0].PSObject.Properties.Name | Should -Not -Contain 'truncatedSecret'
        ($rows[0] | ConvertTo-Json) | Should -Not -Match 'sdk-abc123'
        # The secret TYPE is what triage needs, and that is safe.
        $rows[0].Title | Should -Be 'LaunchDarkly API key'
    }

    It 'counts and names repositories that refuse their alerts' {
        $warnings = @()
        $rows = InModuleScope msec {
            . Set-AdoMock -Enabled @(
                [pscustomobject]@{ projectId = 'p1'; repositoryId = 'r1'; advSecEnabled = $true }
                [pscustomobject]@{ projectId = 'p1'; repositoryId = 'r2'; advSecEnabled = $true }
            ) -Repos @(
                [pscustomobject]@{ id = 'r2'; name = 'Refused'; project = [pscustomobject]@{ id = 'p1'; name = 'Platform' } }
            ) -Alerts @(New-Alert -Id 1) -Refuse @('r2')
            Get-MsecAzureDevOpsAlert -Organization 'contoso'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        # A refused repository must not pass as a repository with no findings.
        @($rows).Count | Should -Be 1
        ($warnings -join ' ') | Should -Match 'Platform/Refused'
        ($warnings -join ' ') | Should -Match 'NOT in this output'
    }

    It 'reports how long a finding has been sitting there' {
        $rows = InModuleScope msec {
            . Set-AdoMock -Enabled @([pscustomobject]@{ projectId = 'p1'; repositoryId = 'r1'; advSecEnabled = $true }) `
                        -Repos @() -Alerts @(New-Alert -Id 1 -AgeDays 41)
            Get-MsecAzureDevOpsAlert -Organization 'contoso' -WarningAction SilentlyContinue
        }

        # For a committed credential this is the number that matters: exposure is cumulative and
        # does not stop at detection.
        $rows[0].AgeDays | Should -BeGreaterOrEqual 40
        $rows[0].FilePath | Should -Be 'src/appsettings.json'
        $rows[0].Tool     | Should -Be 'CredScan'
    }

    It 'filters by alert type when asked' {
        $rows = InModuleScope msec {
            . Set-AdoMock -Enabled @([pscustomobject]@{ projectId = 'p1'; repositoryId = 'r1'; advSecEnabled = $true }) `
                        -Repos @() -Alerts @((New-Alert -Id 1 -Type 'secret'), (New-Alert -Id 2 -Type 'dependency'))
            Get-MsecAzureDevOpsAlert -Organization 'contoso' -AlertType secret -WarningAction SilentlyContinue
        }

        @($rows).Count  | Should -Be 1
        $rows[0].AlertType | Should -Be 'secret'
    }

    It 'warns rather than returning nothing when no repository reports scanning' {
        $warnings = @()
        $rows = InModuleScope msec {
            . Set-AdoMock -Enabled @() -Repos @() -Alerts @()
            Get-MsecAzureDevOpsAlert -Organization 'contoso'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        @($rows).Count | Should -Be 0
        ($warnings -join ' ') | Should -Match 'UNREAD'
    }

    It 'throws a clear error when not connected' {
        InModuleScope msec {
            $script:MsecSession = $null
            { Get-MsecAzureDevOpsAlert -Organization 'contoso' } | Should -Throw '*Connect-Msec*'
        }
    }
}
