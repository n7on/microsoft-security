#Requires -Module Pester
#
# Tests for Get-MsecAccessToken's token cache: the second and third calls for the
# same resource must NOT re-hit Entra ID's /token endpoint while the cached entry
# is still fresh.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAccessToken caching' {
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

    It 'hits /token only once across multiple Get-MsecAccessToken calls for the same resource' {
        InModuleScope msec {
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
}
