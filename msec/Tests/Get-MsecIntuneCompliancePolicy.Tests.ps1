#Requires -Module Pester
#
# Tests for Get-MsecIntuneCompliancePolicy. Verifies Platform is derived from
# @odata.type, AssignmentCount comes from $expand=assignments, and Status is
# omitted when -IncludeStatus is not passed.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecIntuneCompliancePolicy' {
    BeforeEach {
        InModuleScope msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId        = 'tenant'
                ClientId        = 'client'
                KeyVaultName    = 'kv-test'
                KeyName         = 'msec-app'
                ThumbprintBytes = $Thumb
                Tokens          = @{}
            }
        }
    }

    It 'lists compliance policies, deriving Platform from @odata.type and AssignmentCount from $expand' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceCompliancePolicies\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'cp-1'; displayName = 'Win10 Compliance'
                        '@odata.type' = '#microsoft.graph.windows10CompliancePolicy'
                        assignments = @(@{ target = @{ groupId = 'g-1' } })
                    }
                    [pscustomobject]@{
                        id = 'cp-2'; displayName = 'iOS Compliance'
                        '@odata.type' = '#microsoft.graph.iosCompliancePolicy'
                        assignments = @()
                    }
                ) }
            }

            Get-MsecIntuneCompliancePolicy
        }

        $rows.Count | Should -Be 2
        ($rows | Where-Object Id -eq 'cp-1').Platform        | Should -Be 'windows10'
        ($rows | Where-Object Id -eq 'cp-1').Type            | Should -Be 'windows10CompliancePolicy'
        ($rows | Where-Object Id -eq 'cp-1').AssignmentCount | Should -Be 1
        ($rows | Where-Object Id -eq 'cp-2').Platform        | Should -Be 'iOS'
        ($rows | Where-Object Id -eq 'cp-2').AssignmentCount | Should -Be 0

        # No -IncludeStatus -> no Status column at all (not even for AssignmentCount=0 rows).
        ($rows | Where-Object Id -eq 'cp-1').PSObject.Properties.Name | Should -Not -Contain 'Status'
        ($rows | Where-Object Id -eq 'cp-2').PSObject.Properties.Name | Should -Not -Contain 'Status'
    }
}
