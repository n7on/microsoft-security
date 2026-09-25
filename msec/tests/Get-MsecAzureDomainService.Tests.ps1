#Requires -Module Pester
#
# Tests for Get-MsecAzureDomainService.
#
# The settings themselves come straight out of Resource Graph and are the .kql file's business.
# What is specific to this command is the audit-log half, and the distinction it exists to keep:
#
#   AuditLogsEnabled $false means "security audit is off on this managed domain" - a real
#   finding, and the default state. $null means the diagnostic settings could not be READ, which
#   is a permission problem and not a finding at all. A command that collapsed the two would
#   report every domain it was refused as a domain nobody is auditing.
#
# The other trap is the category group. A diagnostic setting that selects a GROUP ('allLogs')
# leaves every per-category field null, so reading only `category` reports the most complete
# possible logging configuration as no logging at all.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureDomainService' {

    BeforeEach {
        InModuleScope msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Name = 'ctx' } }
            Mock Search-MsecAzureResourceGraph -MockWith {
                [pscustomobject]@{
                    Domain = 'contoso.local'
                    NtlmV1 = 'Enabled'
                    WeakSettings = 'NTLM v1 accepted'
                    Id = '/subscriptions/s1/resourceGroups/rg/providers/Microsoft.AAD/DomainServices/contoso.local'
                }
            }
            function script:Set-DiagnosticResponse {
                param([int] $Status = 200, [string] $Body, [switch] $Throw)
                Mock Invoke-AzRestMethod -MockWith {
                    if ($Throw) { throw 'AuthorizationFailed' }
                    [pscustomobject]@{ StatusCode = $Status; Content = $Body }
                }.GetNewClosure()
            }
        }
    }

    It 'reports a domain with no diagnostic setting as unaudited, not unknown' {
        $row = InModuleScope msec {
            . Set-DiagnosticResponse -Body '{"value":[]}'
            Get-MsecAzureDomainService
        }

        # The default state of a managed domain, and a real finding: every authentication
        # against it, including every failure, goes unrecorded.
        $row.AuditLogsEnabled  | Should -BeOfType [bool]
        $row.AuditLogsEnabled  | Should -BeFalse
        $row.AuditLogWorkspace | Should -BeNullOrEmpty
    }

    It 'reports a refused read as unknown, not as unaudited' {
        $row = InModuleScope msec {
            . Set-DiagnosticResponse -Throw
            Get-MsecAzureDomainService -WarningAction SilentlyContinue
        }

        # THE distinction this command turns on: $null is "could not measure".
        $row.AuditLogsEnabled | Should -BeNullOrEmpty
        $row.AuditLogsEnabled | Should -Not -BeOfType [bool]
    }

    It 'names the category group when no individual categories are selected' {
        $row = InModuleScope msec {
            # What a real managed domain returns: category null, categoryGroup set.
            . Set-DiagnosticResponse -Body (@'
{"value":[{"name":"aadds-audit","properties":{
  "workspaceId":"/subscriptions/s1/resourcegroups/rg/providers/microsoft.operationalinsights/workspaces/security-law",
  "logs":[{"category":null,"categoryGroup":"audit","enabled":true},
          {"category":null,"categoryGroup":"allLogs","enabled":true}]}}]}
'@)
            Get-MsecAzureDomainService
        }

        $row.AuditLogsEnabled   | Should -BeTrue
        # 'allLogs' and 'no categories' are opposite answers.
        $row.AuditLogCategories | Should -Match 'allLogs'
        $row.AuditLogCategories | Should -Match 'audit'
    }

    It 'hands back the workspace NAME, which is what Search-MsecLogAnalytics takes' {
        $row = InModuleScope msec {
            . Set-DiagnosticResponse -Body (@'
{"value":[{"name":"aadds-audit","properties":{
  "workspaceId":"/subscriptions/s1/resourcegroups/rg/providers/microsoft.operationalinsights/workspaces/security-law",
  "logs":[{"category":"AADDomainServicesAccountLogon","enabled":true}]}}]}
'@)
            Get-MsecAzureDomainService
        }

        # The whole point of the column: a tenant has dozens of workspaces and the one a managed
        # domain writes to is not guessable.
        $row.AuditLogWorkspace   | Should -Be 'security-law'
        $row.AuditLogWorkspaceId | Should -BeLike '/subscriptions/s1/*'
        $row.AuditLogCategories  | Should -Be 'AADDomainServicesAccountLogon'
    }

    It 'treats a setting whose logs are all switched off as no logging' {
        $row = InModuleScope msec {
            . Set-DiagnosticResponse -Body (@'
{"value":[{"name":"metrics-only","properties":{
  "workspaceId":"/subscriptions/s1/resourcegroups/rg/providers/microsoft.operationalinsights/workspaces/security-law",
  "logs":[{"category":null,"categoryGroup":"audit","enabled":false}],
  "metrics":[{"category":"AllMetrics","enabled":true}]}}]}
'@)
            Get-MsecAzureDomainService
        }

        # A diagnostic setting exists, so a check for one would pass - and nothing is being
        # logged. Matched on the enabled log entries rather than on the setting existing.
        $row.AuditLogsEnabled  | Should -BeFalse
        $row.AuditLogWorkspace | Should -BeNullOrEmpty
    }

    It 'carries every Resource Graph column through rather than a hand-picked subset' {
        $row = InModuleScope msec {
            . Set-DiagnosticResponse -Body '{"value":[]}'
            Get-MsecAzureDomainService
        }

        # A setting this command was never taught about is still worth seeing.
        $row.NtlmV1       | Should -Be 'Enabled'
        $row.WeakSettings | Should -Be 'NTLM v1 accepted'
    }

    It 'throws a clear error when there is no Azure context' {
        InModuleScope msec {
            Mock Get-AzContext -MockWith { $null }
            { Get-MsecAzureDomainService } | Should -Throw '*Connect-AzAccount*'
        }
    }
}
