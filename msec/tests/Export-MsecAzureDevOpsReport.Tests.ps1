#Requires -Module Pester
#
# Tests for Export-MsecAzureDevOpsReport.
#
# The workbook machinery itself is covered by the other report tests. What is specific here is
# the counting, and the distinction the whole report is built around:
#
#   "collected, found none" and "could not collect" must not look the same. An area that was
#   read and held nothing gets a block of zeros and a chart. An area that FAILED gets neither -
#   only a RunLog row - because a chart of zeros drawn for a 403 turns a permission gap into a
#   clean bill of health.
#
# The other trap is $null. Every one of these commands reports $null for "not measured" and a
# real value for "measured", so a selector that treats $null as the unsafe state invents
# findings and one that treats it as safe hides them. Both directions are tested.

$script:HasExcel = $null -ne (Get-Module -ListAvailable ImportExcel)

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Export-MsecAzureDevOpsReport' -Skip:(-not $script:HasExcel) {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
        }
        $script:Book = Join-Path ([System.IO.Path]::GetTempPath()) "msec-ado-$([guid]::NewGuid().Guid).xlsx"
    }

    AfterEach {
        if ($script:Book -and (Test-Path $script:Book)) { Remove-Item $script:Book -Force -ErrorAction SilentlyContinue }
    }

    It 'gives a collected-but-empty area zeros, and a failed area no block at all' {
        InModuleScope msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecAzureDevOpsSecureFile  -MockWith { }                       # read, held nothing
            Mock Get-MsecAzureDevOpsEnvironment -MockWith { throw 'TF400813: denied' }

            Export-MsecAzureDevOpsReport -Path $Book -Organization 'contoso' `
                -Area SecureFiles, Environments -Force -WarningAction SilentlyContinue | Out-Null
        }

        $summary = @(Import-Excel -Path $script:Book -WorksheetName 'Summary')
        $runLog  = @(Import-Excel -Path $script:Book -WorksheetName 'RunLog')

        # Collected and empty: every category present, all zero. That IS the measurement.
        $secureFiles = @($summary | Where-Object Area -eq 'Secure files')
        $secureFiles.Count | Should -BeGreaterThan 0
        @($secureFiles | Where-Object { [int] $_.Count -ne 0 }).Count | Should -Be 0

        # Failed: no block, so no chart. A row of zeros here would read as "no environments
        # are unprotected" when the truth is that nobody was allowed to look.
        @($summary | Where-Object Area -eq 'Environments').Count | Should -Be 0

        ($runLog | Where-Object Area -eq 'SecureFiles').Status  | Should -Be 'Collected'
        ($runLog | Where-Object Area -eq 'Environments').Status | Should -Be 'Failed'
        ($runLog | Where-Object Area -eq 'Environments').Detail | Should -BeLike '*TF400813*'
    }

    It 'keeps unreadable protection apart from absent protection' {
        InModuleScope msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecAzureDevOpsRepository -MockWith {
                # Branch policies could not be read for this project - every column $null.
                [pscustomobject]@{ Repository = 'unreadable'; IsDisabled = $false
                                   MinimumReviewers = $null; RequireBuildValidation = $null; BlockSecretPush = $null }
                # Read, and there is genuinely no reviewer requirement.
                [pscustomobject]@{ Repository = 'open'; IsDisabled = $false
                                   MinimumReviewers = 0; RequireBuildValidation = $false; BlockSecretPush = $false }
                [pscustomobject]@{ Repository = 'reviewed'; IsDisabled = $false
                                   MinimumReviewers = 2; RequireBuildValidation = $false; BlockSecretPush = $true }
                [pscustomobject]@{ Repository = 'guarded'; IsDisabled = $false
                                   MinimumReviewers = 2; RequireBuildValidation = $true; BlockSecretPush = $true }
                [pscustomobject]@{ Repository = 'retired'; IsDisabled = $true
                                   MinimumReviewers = 0; RequireBuildValidation = $false; BlockSecretPush = $false }
            }

            Export-MsecAzureDevOpsReport -Path $Book -Organization 'contoso' `
                -Area Repositories -Force -WarningAction SilentlyContinue | Out-Null
        }

        $summary = @(Import-Excel -Path $script:Book -WorksheetName 'Summary')
        $count = { param($area, $category)
            [int] ($summary | Where-Object { $_.Area -eq $area -and $_.Category -eq $category }).Count }

        # The one that must never merge: a repository whose policies 403'd is NOT a repository
        # with no reviewer requirement.
        & $count 'Branch protection' 'Protection unreadable'          | Should -Be 1
        & $count 'Branch protection' 'No reviewer requirement'        | Should -Be 1
        & $count 'Branch protection' 'Reviewers, no build validation' | Should -Be 1
        & $count 'Branch protection' 'Reviewers and build validation' | Should -Be 1
        # Checked before protection, so a disabled repository is not also counted as unguarded.
        & $count 'Branch protection' 'Disabled repository'            | Should -Be 1

        & $count 'Secret push protection' 'Unreadable'   | Should -Be 1
        & $count 'Secret push protection' 'Enforced'     | Should -Be 2
        & $count 'Secret push protection' 'Not enforced' | Should -Be 2
    }

    It 'gives a value no category was written for its own bar' {
        InModuleScope msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecAzureDevOpsSecureFile -MockWith {
                [pscustomobject]@{ Name = 'a.pfx'; Kind = 'Certificate' }
                # A kind this report has never heard of - Azure DevOps adds things.
                [pscustomobject]@{ Name = 'b.zzz'; Kind = 'SomethingNew' }
            }
            Export-MsecAzureDevOpsReport -Path $Book -Organization 'contoso' `
                -Area SecureFiles -Force -WarningAction SilentlyContinue | Out-Null
        }

        $summary = @(Import-Excel -Path $script:Book -WorksheetName 'Summary')

        # Visible as itself rather than folded into 'Other' or dropped, which is the only way a
        # reader finds out the category list has fallen behind the product.
        ($summary | Where-Object Category -eq 'SomethingNew').Count | Should -Be 1
        ($summary | Where-Object Category -eq 'Other').Count        | Should -Be 0
        # And the fixed ones are still all there at zero, so two runs' charts line up.
        @($summary.Category) | Should -Contain 'Keystore'
    }

    It 'reads an inverted policy the way the settings page shows it' {
        InModuleScope msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecAzureDevOpsOrganizationPolicy -MockWith {
                # Named for what it FORBIDS: value true means the toggle on the page is OFF.
                [pscustomobject]@{ Setting = 'SSH authentication'; Policy = 'DisallowSecureShell'
                                   Value = $true; IsInverted = $true }
                [pscustomobject]@{ Setting = 'Allow public projects'; Policy = 'AllowAnonymousAccess'
                                   Value = $true; IsInverted = $false }
            }
            Export-MsecAzureDevOpsReport -Path $Book -Organization 'contoso' `
                -Area OrganizationPolicies -Force -WarningAction SilentlyContinue | Out-Null
        }

        $summary = @(Import-Excel -Path $script:Book -WorksheetName 'Summary')
        ([int] ($summary | Where-Object Category -eq 'SSH authentication').Count)    | Should -Be 0
        ([int] ($summary | Where-Object Category -eq 'Allow public projects').Count) | Should -Be 1
    }

    It 'counts a pipeline setting as a risk only where it was actually read' {
        InModuleScope msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecAzureDevOpsPipelineSetting -MockWith {
                [pscustomobject]@{ Project = 'risky'; BuildsEnabledForForks = $true;  JobAuthScopeLimited = $false }
                [pscustomobject]@{ Project = 'safe';  BuildsEnabledForForks = $false; JobAuthScopeLimited = $true }
                # Not collected. $null is not false, and counting it as a risk invents a finding.
                [pscustomobject]@{ Project = 'unknown'; BuildsEnabledForForks = $null; JobAuthScopeLimited = $null }
            }
            Export-MsecAzureDevOpsReport -Path $Book -Organization 'contoso' `
                -Area PipelineSettings -Force -WarningAction SilentlyContinue | Out-Null
        }

        $summary = @(Import-Excel -Path $script:Book -WorksheetName 'Summary')
        ([int] ($summary | Where-Object Category -eq 'Fork builds enabled').Count)        | Should -Be 1
        ([int] ($summary | Where-Object Category -eq 'Job auth scope not limited').Count) | Should -Be 1
    }

    It 'counts a member once however many groups they are in' {
        InModuleScope msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecAzureDevOpsUser -MockWith {
                # One row per (user, group) - three rows, two people.
                [pscustomobject]@{ DisplayName = 'Ada'; Descriptor = 'aad.ada'; Origin = 'aad';  Group = 'Contributors' }
                [pscustomobject]@{ DisplayName = 'Ada'; Descriptor = 'aad.ada'; Origin = 'aad';  Group = 'Readers' }
                [pscustomobject]@{ DisplayName = 'Svc'; Descriptor = 'vss.svc'; Origin = 'vsts'; Group = 'Build Admins' }
            }
            Export-MsecAzureDevOpsReport -Path $Book -Organization 'contoso' `
                -Area Users -Force -WarningAction SilentlyContinue | Out-Null
        }

        $summary = @(Import-Excel -Path $script:Book -WorksheetName 'Summary')
        ([int] ($summary | Where-Object Category -eq 'Entra (aad)').Count) | Should -Be 1
        # 'vsts' is an account that exists only inside Azure DevOps - no Conditional Access and
        # no leaver process reaches it, which is why it gets its own bar rather than a total.
        ([int] ($summary | Where-Object Category -eq 'Azure DevOps local (vsts)').Count) | Should -Be 1
    }

    It 'does not write the raw endpoint object to the service connection sheet' {
        InModuleScope msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecAzureDevOpsServiceConnection -MockWith {
                [pscustomobject]@{ Name = 'prod-arm'; AuthScheme = 'WorkloadIdentityFederation'
                                   OpenToAllPipelines = $true; AuthorizedPipelineCount = 0
                                   Raw = [pscustomobject]@{ data = @{ deep = 'nested' } } }
            }
            Export-MsecAzureDevOpsReport -Path $Book -Organization 'contoso' `
                -Area ServiceConnections -Force -WarningAction SilentlyContinue | Out-Null
        }

        # Raw exists so a caller can reach an unmodelled field; in a cell it is noise.
        $sheet = @(Import-Excel -Path $script:Book -WorksheetName 'ServiceConnections')
        @($sheet[0].PSObject.Properties.Name) | Should -Not -Contain 'Raw'
        @($sheet[0].PSObject.Properties.Name) | Should -Contain 'AuthScheme'

        $summary = @(Import-Excel -Path $script:Book -WorksheetName 'Summary')
        ([int] ($summary | Where-Object Category -eq 'WorkloadIdentityFederation').Count) | Should -Be 1
        ([int] ($summary | Where-Object Category -eq 'Open to all pipelines').Count)      | Should -Be 1
    }

    It 'charts alerts by type as well as severity' {
        InModuleScope msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecAzureDevOpsAlert -MockWith {
                # Azure DevOps rates EVERY secret alert critical. An organization running secret
                # scanning and nothing else therefore produces exactly this shape, and severity
                # alone would read as "no medium or low findings" rather than "no scanner that
                # emits them is on".
                1..3 | ForEach-Object {
                    [pscustomobject]@{ AlertId = $_; Severity = 'critical'; AlertType = 'secret' }
                }
            }
            Export-MsecAzureDevOpsReport -Path $Book -Organization 'contoso' `
                -Area Alerts -Force -WarningAction SilentlyContinue | Out-Null
        }

        $summary = @(Import-Excel -Path $script:Book -WorksheetName 'Summary')

        ([int] ($summary | Where-Object { $_.Area -eq 'Alerts' -and $_.Category -eq 'Critical' }).Count) | Should -Be 3
        ([int] ($summary | Where-Object { $_.Area -eq 'Alert type' -and $_.Category -eq 'secret' }).Count) | Should -Be 3
        # The bars that say a scanner is off rather than a codebase is clean.
        ([int] ($summary | Where-Object { $_.Area -eq 'Alert type' -and $_.Category -eq 'dependency' }).Count) | Should -Be 0
        ([int] ($summary | Where-Object { $_.Area -eq 'Alert type' -and $_.Category -eq 'code' }).Count) | Should -Be 0
    }

    It 'throws a clear error when not connected' {
        InModuleScope msec -Parameters @{ Book = $script:Book } {
            param($Book)
            $script:MsecSession = $null
            { Export-MsecAzureDevOpsReport -Path $Book -Organization 'contoso' -Force } | Should -Throw '*Connect-Msec*'
        }
    }
}
