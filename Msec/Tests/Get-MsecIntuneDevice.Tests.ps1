#Requires -Module Pester
#
# Tests for Get-MsecIntuneDevice. The function GETs /deviceManagement/managedDevices
# with a $select filter and projects each device row to a flat PSCustomObject.
# Tests cover:
#   - Field projection (Graph camelCase -> output PascalCase).
#   - The 9999-sentinel for ComplianceGraceUntil becomes $null.
#   - DateTime strings are converted to [datetime] (so callers can compare with
#     (Get-Date).AddDays(...) without manual parsing).
#   - 403 is rewritten to mention DeviceManagementManagedDevices.Read.All.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecIntuneDevice' {
    BeforeEach {
        InModuleScope Msec -Parameters @{ Thumb = $script:TestThumbBytes } {
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

    It 'projects every Graph row to the documented flat shape, with DateTime conversion and grace-sentinel nullification' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceManagement/managedDevices' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'd-1'; deviceName = 'lap-01'
                        userPrincipalName = 'admin@contoso.com'; userDisplayName = 'Admin'
                        operatingSystem = 'Windows'; osVersion = '10.0.26100.5074'
                        model = 'XPS 13'; manufacturer = 'Dell'
                        complianceState = 'compliant'
                        # 9999 sentinel = no grace period -> ComplianceGraceUntil must be $null.
                        complianceGracePeriodExpirationDateTime = '9999-12-31T23:59:59.9999999Z'
                        managementState = 'managed'; managementAgent = 'mdm'
                        managedDeviceOwnerType = 'company'
                        isEncrypted = $true; jailBroken = 'False'; azureADRegistered = $true
                        enrolledDateTime = '2025-09-01T10:00:00Z'
                        lastSyncDateTime = '2026-06-07T15:30:00Z'
                        serialNumber = 'SN-001'
                    }
                    [pscustomobject]@{
                        id = 'd-2'; deviceName = 'phone-01'
                        userPrincipalName = 'admin@contoso.com'; userDisplayName = 'Admin'
                        operatingSystem = 'iOS'; osVersion = '18.5'
                        model = 'iPhone 16 Pro'; manufacturer = 'Apple'
                        # In-grace device: grace expiration is a REAL future date, not the sentinel.
                        complianceState = 'inGracePeriod'
                        complianceGracePeriodExpirationDateTime = '2026-06-15T00:00:00Z'
                        managementState = 'managed'; managementAgent = 'mdm'
                        managedDeviceOwnerType = 'personal'
                        isEncrypted = $true; jailBroken = 'False'; azureADRegistered = $true
                        enrolledDateTime = '2026-01-10T12:00:00Z'
                        lastSyncDateTime = '2026-06-08T11:00:00Z'
                        serialNumber = 'SN-002'
                    }
                ) }
            }

            Get-MsecIntuneDevice
        }

        $rows.Count | Should -Be 2

        # Row 1: Windows laptop, fully compliant, sentinel grace.
        $win = $rows | Where-Object Id -eq 'd-1'
        $win.DeviceName        | Should -Be 'lap-01'
        $win.Os                | Should -Be 'Windows'
        $win.ComplianceState   | Should -Be 'compliant'
        $win.Manufacturer      | Should -Be 'Dell'
        $win.Ownership         | Should -Be 'company'
        $win.IsEncrypted       | Should -BeTrue
        $win.ComplianceGraceUntil | Should -BeNullOrEmpty   # 9999 sentinel -> null
        $win.EnrolledDateTime  | Should -BeOfType [datetime]
        $win.LastSyncDateTime  | Should -BeOfType [datetime]

        # Row 2: in-grace, real future grace date.
        $ios = $rows | Where-Object Id -eq 'd-2'
        $ios.Os                | Should -Be 'iOS'
        $ios.ComplianceState   | Should -Be 'inGracePeriod'
        $ios.Ownership         | Should -Be 'personal'
        $ios.ComplianceGraceUntil | Should -BeOfType [datetime]
        $ios.ComplianceGraceUntil | Should -Be ([datetime]'2026-06-15T00:00:00Z')
    }

    It 'sends a $select trimming the request to the documented columns (so we do not pull all 80+ fields)' {
        InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            $script:CapturedUri = $null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceManagement/managedDevices' } -MockWith {
                $script:CapturedUri = $Uri
                [pscustomobject]@{ value = @() }
            }

            Get-MsecIntuneDevice | Out-Null

            $script:CapturedUri | Should -Match '\$select='
            # Spot-check that key documented columns are in the $select.
            $script:CapturedUri | Should -Match 'complianceState'
            $script:CapturedUri | Should -Match 'lastSyncDateTime'
            $script:CapturedUri | Should -Match 'azureADRegistered'
        }
    }

    It 'rewrites a 403 to mention the missing DeviceManagementManagedDevices.Read.All permission' {
        InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceManagement/managedDevices' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }

            { Get-MsecIntuneDevice } |
                Should -Throw -ExpectedMessage '*DeviceManagementManagedDevices.Read.All*'
        }
    }
}
