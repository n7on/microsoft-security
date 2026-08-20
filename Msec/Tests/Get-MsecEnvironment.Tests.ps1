#Requires -Module Pester
#
# Tests for Get-MsecEnvironment - the single resolver that turns an Azure environment
# name into the cloud-specific endpoints msec uses. Mocks Get-AzEnvironment/Get-AzContext
# so the tests are hermetic and don't depend on the installed Az.Accounts data.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEnvironment' {

    It 'resolves Azure China endpoints from Get-AzEnvironment' {
        $result = InModuleScope msec {
            Mock Get-AzEnvironment -MockWith {
                [pscustomobject]@{
                    Name                                   = 'AzureChinaCloud'
                    ActiveDirectoryAuthority               = 'https://login.chinacloudapi.cn/'
                    ResourceManagerUrl                     = 'https://management.chinacloudapi.cn/'
                    AzureKeyVaultServiceEndpointResourceId = 'https://vault.azure.cn'
                    AzureKeyVaultDnsSuffix                 = 'vault.azure.cn'
                    ExtendedProperties                     = @{ MicrosoftGraphUrl = 'https://microsoftgraph.chinacloudapi.cn/' }
                }
            }
            Get-MsecEnvironment -Name 'AzureChinaCloud'
        }

        $result.EnvironmentName   | Should -Be 'AzureChinaCloud'
        $result.AadAuthority      | Should -Be 'https://login.chinacloudapi.cn'
        $result.GraphResource     | Should -Be 'https://microsoftgraph.chinacloudapi.cn'
        $result.ArmResource       | Should -Be 'https://management.chinacloudapi.cn'
        $result.KeyVaultResource  | Should -Be 'https://vault.azure.cn'
        $result.KeyVaultDnsSuffix | Should -Be 'vault.azure.cn'
        # Defender (securitycenter) has no China endpoint - must be null so callers fail clearly.
        $result.DefenderResource  | Should -BeNullOrEmpty
    }

    It 'populates the Defender endpoint only for commercial AzureCloud' {
        $result = InModuleScope msec {
            Mock Get-AzEnvironment -MockWith {
                [pscustomobject]@{
                    Name                                   = 'AzureCloud'
                    ActiveDirectoryAuthority               = 'https://login.microsoftonline.com/'
                    ResourceManagerUrl                     = 'https://management.azure.com/'
                    AzureKeyVaultServiceEndpointResourceId = 'https://vault.azure.net'
                    AzureKeyVaultDnsSuffix                 = 'vault.azure.net'
                    ExtendedProperties                     = @{ MicrosoftGraphUrl = 'https://graph.microsoft.com/' }
                }
            }
            Get-MsecEnvironment -Name 'AzureCloud'
        }

        $result.DefenderResource | Should -Be 'https://api.securitycenter.microsoft.com'
        $result.GraphResource    | Should -Be 'https://graph.microsoft.com'
    }

    It 'defaults to the current Az context environment when -Name is omitted' {
        $name = InModuleScope msec {
            Mock Get-AzContext     -MockWith { [pscustomobject]@{ Environment = 'AzureChinaCloud' } }
            Mock Get-AzEnvironment -MockWith {
                [pscustomobject]@{
                    Name                                   = 'AzureChinaCloud'
                    ActiveDirectoryAuthority               = 'https://login.chinacloudapi.cn/'
                    ResourceManagerUrl                     = 'https://management.chinacloudapi.cn/'
                    AzureKeyVaultServiceEndpointResourceId = 'https://vault.azure.cn'
                    AzureKeyVaultDnsSuffix                 = 'vault.azure.cn'
                    ExtendedProperties                     = @{ MicrosoftGraphUrl = 'https://microsoftgraph.chinacloudapi.cn/' }
                }
            }
            (Get-MsecEnvironment).EnvironmentName
        }
        $name | Should -Be 'AzureChinaCloud'
    }

    It 'falls back to a per-cloud Graph URL when ExtendedProperties lacks MicrosoftGraphUrl (older Az)' {
        $result = InModuleScope msec {
            Mock Get-AzEnvironment -MockWith {
                [pscustomobject]@{
                    Name                                   = 'AzureChinaCloud'
                    ActiveDirectoryAuthority               = 'https://login.chinacloudapi.cn/'
                    ResourceManagerUrl                     = 'https://management.chinacloudapi.cn/'
                    AzureKeyVaultServiceEndpointResourceId = 'https://vault.azure.cn'
                    AzureKeyVaultDnsSuffix                 = 'vault.azure.cn'
                    ExtendedProperties                     = @{}   # no MicrosoftGraphUrl
                }
            }
            Get-MsecEnvironment -Name 'AzureChinaCloud'
        }
        $result.GraphResource | Should -Be 'https://microsoftgraph.chinacloudapi.cn'
    }
}
