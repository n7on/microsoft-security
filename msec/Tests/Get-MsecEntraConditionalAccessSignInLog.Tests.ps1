#Requires -Module Pester
#
# Tests for Get-MsecEntraConditionalAccessSignInLog. The function GETs
# /auditLogs/signIns?$filter=createdDateTime ge ...&$select=... and projects
# each event to a flat row.
# Coverage:
#   - $filter window flows through from -Days.
#   - Nested fields (location.city, deviceDetail.*, status.*) get flattened.
#   - AppliedPolicies stays as the nested array so consumer can filter on it.
#   - DateTime conversion.
#   - 403 -> AuditLog.Read.All hint.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEntraConditionalAccessSignInLog' {
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

    It 'projects each sign-in to a flat row with CA outcome, nested fields flattened, AppliedPolicies preserved' {
        $captured = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            $script:CapturedUri = $null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/auditLogs/signIns' } -MockWith {
                $script:CapturedUri = $Uri
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id                = 'evt-1'
                        createdDateTime   = '2026-06-07T09:14:00Z'
                        userPrincipalName = 'admin@contoso.com'
                        userDisplayName   = 'Admin'
                        userId            = 'user-guid'
                        appDisplayName    = 'Microsoft Graph PowerShell'
                        appId             = 'app-guid'
                        ipAddress         = '203.0.113.5'
                        location          = [pscustomobject]@{ city = 'Stockholm'; state = 'Stockholm'; countryOrRegion = 'SE' }
                        clientAppUsed     = 'Browser'
                        deviceDetail      = [pscustomobject]@{
                            operatingSystem = 'Windows10'; browser = 'Edge 126'; isCompliant = $true
                            trustType = 'Azure AD joined'
                        }
                        conditionalAccessStatus = 'success'
                        appliedConditionalAccessPolicies = @(
                            [pscustomobject]@{ id = 'pol-1'; displayName = 'Require MFA for all admins'; result = 'success' }
                        )
                        riskLevelAggregated    = 'none'
                        riskLevelDuringSignIn  = 'none'
                        status                 = [pscustomobject]@{ errorCode = 0; failureReason = '' }
                    }
                    [pscustomobject]@{
                        id                = 'evt-2'
                        createdDateTime   = '2026-06-07T11:00:00Z'
                        userPrincipalName = 'attacker@external.test'
                        appDisplayName    = 'Office 365'
                        ipAddress         = '198.51.100.42'
                        location          = [pscustomobject]@{ city = 'Unknown'; countryOrRegion = 'CN' }
                        clientAppUsed     = 'Mobile Apps and Desktop clients'
                        deviceDetail      = [pscustomobject]@{ operatingSystem = $null; browser = $null }
                        conditionalAccessStatus = 'failure'
                        appliedConditionalAccessPolicies = @(
                            [pscustomobject]@{ id = 'pol-1'; displayName = 'Require MFA for all admins'; result = 'failure' }
                            [pscustomobject]@{ id = 'pol-3'; displayName = 'Block from untrusted countries'; result = 'failure' }
                        )
                        riskLevelAggregated   = 'high'
                        riskLevelDuringSignIn = 'high'
                        status                = [pscustomobject]@{ errorCode = 53003; failureReason = 'Access has been blocked by Conditional Access policies.' }
                    }
                ) }
            }

            $rows = Get-MsecEntraConditionalAccessSignInLog -Days 1
            [pscustomobject]@{ Rows = $rows; Uri = $script:CapturedUri }
        }

        # Filter window flowed through to the URI.
        $captured.Uri | Should -Match 'createdDateTime ge'
        $captured.Uri | Should -Match '\$select=.+conditionalAccessStatus'

        $captured.Rows.Count | Should -Be 2

        # Event 1: clean success, all nested fields surfaced
        $e1 = $captured.Rows | Where-Object Id -eq 'evt-1'
        $e1.CreatedDateTime         | Should -BeOfType [datetime]
        $e1.UserPrincipalName       | Should -Be 'admin@contoso.com'
        $e1.City                    | Should -Be 'Stockholm'
        $e1.Country                 | Should -Be 'SE'
        $e1.DeviceOs                | Should -Be 'Windows10'
        $e1.DeviceCompliant         | Should -BeTrue
        $e1.ConditionalAccessStatus | Should -Be 'success'
        $e1.ResultCode              | Should -Be 0

        # AppliedPolicies preserved as an array of objects - consumer filters on .result
        ($e1.AppliedPolicies | Where-Object result -eq 'success').displayName |
            Should -Be 'Require MFA for all admins'

        # Event 2: CA failure, high risk, error 53003
        $e2 = $captured.Rows | Where-Object Id -eq 'evt-2'
        $e2.ConditionalAccessStatus | Should -Be 'failure'
        $e2.RiskLevelAggregated     | Should -Be 'high'
        $e2.ResultCode              | Should -Be 53003
        $e2.ResultFailureReason     | Should -Match 'Conditional Access'
        $e2.AppliedPolicies.Count   | Should -Be 2

        # The common audit query: "what CA failures happened?"
        ($captured.Rows |
            Where ConditionalAccessStatus -eq 'failure' |
            Select -ExpandProperty UserPrincipalName) | Should -Be 'attacker@external.test'
    }

    It 'rewrites a 403 to mention the missing AuditLog.Read.All permission' {
        InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/auditLogs/signIns' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }

            { Get-MsecEntraConditionalAccessSignInLog -Days 1 } |
                Should -Throw -ExpectedMessage '*AuditLog.Read.All*'
        }
    }
}
