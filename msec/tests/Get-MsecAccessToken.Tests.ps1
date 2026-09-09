#Requires -Module Pester
#
# Tests for Get-MsecAccessToken's token cache: the second and third calls for the
# same resource must NOT re-hit Entra ID's /token endpoint while the cached entry
# is still fresh.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAccessToken caching' {
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

    It 'hits /token only once across multiple Get-MsecAccessToken calls for the same resource' {
        InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'cached'; expires_in = 3600 }
            }

            [void](Get-MsecAccessToken -Resource 'https://graph.microsoft.com')
            [void](Get-MsecAccessToken -Resource 'https://graph.microsoft.com')
            [void](Get-MsecAccessToken -Resource 'https://graph.microsoft.com')

            Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -Times 1 -Exactly
        }
    }

    It 'posts to the China AAD authority and stamps a matching aud when the session is Azure China' {
        InModuleScope Msec {
            # Pin the session to Azure China endpoints.
            $script:MsecSession.Endpoints = [pscustomobject]@{
                EnvironmentName = 'AzureChinaCloud'
                AadAuthority    = 'https://login.chinacloudapi.cn'
                GraphResource   = 'https://microsoftgraph.chinacloudapi.cn'
            }

            $script:CapturedAuthority = $null
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            # Capture the authority the assertion was built with - it MUST match the token URL.
            Mock New-MsecClientAssertion -MockWith {
                $script:CapturedAuthority = $Authority
                'fake.jwt.assertion'
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'login\.chinacloudapi\.cn/.+/oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'cn'; expires_in = 3600 }
            }

            [void](Get-MsecAccessToken -Resource 'https://microsoftgraph.chinacloudapi.cn')

            $script:CapturedAuthority | Should -Be 'https://login.chinacloudapi.cn'
            Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -match 'login\.chinacloudapi\.cn/.+/oauth2/v2.0/token' } -Times 1 -Exactly
        }
    }
}
