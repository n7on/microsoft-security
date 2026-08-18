#Requires -Module Pester
#
# Tests for Get-MsecEntraLicense. Verifies the /subscribedSkus projection, and in
# particular that ServicePlans contains ONLY successfully-provisioned plans - the
# capability flags in Get-MsecEntraTenantSecuritySetting are derived from that
# field, so a plan that is present-but-disabled must not read as available.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEntraLicense' {
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

    It 'projects SKUs and keeps only successfully-provisioned service plans' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/subscribedSkus' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        skuId            = 'sku-e5'
                        skuPartNumber    = 'SPE_E5'
                        appliesTo        = 'User'
                        capabilityStatus = 'Enabled'
                        consumedUnits    = 18
                        prepaidUnits     = [pscustomobject]@{ enabled = 20; warning = 1; suspended = 0 }
                        servicePlans     = @(
                            [pscustomobject]@{ servicePlanName = 'AAD_PREMIUM';    provisioningStatus = 'Success' }
                            [pscustomobject]@{ servicePlanName = 'AAD_PREMIUM_P2'; provisioningStatus = 'Success' }
                            [pscustomobject]@{ servicePlanName = 'INTUNE_A';       provisioningStatus = 'Success' }
                            # Present but NOT usable - must be excluded from ServicePlans.
                            [pscustomobject]@{ servicePlanName = 'WINDEFATP';      provisioningStatus = 'PendingProvisioning' }
                        )
                    }
                    [pscustomobject]@{
                        skuId            = 'sku-pbi'
                        skuPartNumber    = 'POWER_BI_STANDARD'
                        appliesTo        = 'User'
                        capabilityStatus = 'Enabled'
                        consumedUnits    = 2
                        prepaidUnits     = [pscustomobject]@{ enabled = 1000000; warning = 0; suspended = 0 }
                        servicePlans     = @(
                            [pscustomobject]@{ servicePlanName = 'BI_AZURE_P0'; provisioningStatus = 'Success' }
                        )
                    }
                ) }
            }

            Get-MsecEntraLicense
        }

        $rows.Count | Should -Be 2

        $e5 = $rows | Where-Object SkuPartNumber -eq 'SPE_E5'
        $e5.SkuId            | Should -Be 'sku-e5'
        $e5.Enabled          | Should -Be 20
        $e5.Assigned         | Should -Be 18
        $e5.WarningUnits     | Should -Be 1
        $e5.CapabilityStatus | Should -Be 'Enabled'

        # Only Success plans surface in ServicePlans...
        $e5.ServicePlans | Should -Contain 'AAD_PREMIUM'
        $e5.ServicePlans | Should -Contain 'INTUNE_A'
        $e5.ServicePlans | Should -Not -Contain 'WINDEFATP'
        # ...but ServicePlanDetail keeps everything, so the difference is visible.
        $e5.ServicePlanDetail.servicePlanName | Should -Contain 'WINDEFATP'

        $e5.Raw.skuId              | Should -Be 'sku-e5'
        $e5.PSObject.TypeNames     | Should -Contain 'MsecEntraLicense'
    }

    It 'coerces a SKU with no service plans to an empty array, not $null' {
        $row = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/subscribedSkus' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        skuId         = 'sku-empty'
                        skuPartNumber = 'WINDOWS_STORE'
                        consumedUnits = 0
                        prepaidUnits  = [pscustomobject]@{ enabled = 1000000; warning = 0; suspended = 0 }
                        servicePlans  = $null
                    }
                ) }
            }
            Get-MsecEntraLicense
        }

        # The -contains pattern downstream code uses must not blow up.
        { $row | Where-Object ServicePlans -contains 'AAD_PREMIUM' } | Should -Not -Throw
        ($row | Where-Object ServicePlans -contains 'AAD_PREMIUM')   | Should -BeNullOrEmpty
    }

    It 'rewrites a 403 to mention the missing Organization.Read.All permission' {
        InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/subscribedSkus' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }

            { Get-MsecEntraLicense } | Should -Throw -ExpectedMessage '*Organization.Read.All*'
        }
    }
}
