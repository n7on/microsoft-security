#Requires -Module Pester
#
# Tests for Connect-MsecGraphSdk.
#
# This is the bridge that lets the Microsoft.Graph SDK run as the msec app WITHOUT the
# certificate's private key ever leaving Key Vault. What matters:
#
#   * the token is handed over as a SecureString - the SDK's v2 signature
#   * the cloud comes from the msec session and is matched on the ENDPOINT, because the SDK
#     names clouds differently from Azure (China, not AzureChinaCloud)
#   * a token too close to expiry is refused UP FRONT. The SDK is given a static token and
#     cannot renew it, so a long report would start working and fail partway through - much
#     harder to diagnose than a refusal.

$script:HasGraphSdk = $null -ne (Get-Module -ListAvailable Microsoft.Graph.Authentication)

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Connect-MsecGraphSdk' -Skip:(-not $script:HasGraphSdk) {

    BeforeEach {
        InModuleScope Msec {
            $script:MsecSession = @{
                TenantId = 'tenant-1'; ClientId = 'client-1'; KeyVaultName = 'kv'
                KeyName = 'msec-app'; ThumbprintBytes = [byte[]](1..20)
                Endpoints = @{ GraphResource = 'https://graph.microsoft.com'; EnvironmentName = 'AzureCloud' }
                Tokens = @{}
            }
        }
    }

    It 'hands the session token to the SDK as a SecureString' {
        InModuleScope Msec {
            $script:MsecSession.Tokens['https://graph.microsoft.com'] = @{
                Token = 'THE.SESSION.TOKEN'; ExpiresOn = [DateTimeOffset]::UtcNow.AddMinutes(55)
            }
            Mock Get-MsecAccessToken -MockWith { 'THE.SESSION.TOKEN' }
            Mock Connect-MgGraph -MockWith { }

            Connect-MsecGraphSdk

            Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter {
                # v2 of the SDK takes a SecureString, not a plain string.
                $AccessToken -is [System.Security.SecureString] -and
                [System.Net.NetworkCredential]::new('', $AccessToken).Password -eq 'THE.SESSION.TOKEN' -and
                $Environment -eq 'Global'
            }
        }
    }

    It 'matches the cloud on the endpoint, not on the Azure environment name' {
        InModuleScope Msec {
            # The Chinese cloud: Az calls it AzureChinaCloud, the SDK calls it China. Mapping
            # by name would need a lookup table that goes stale as clouds are added; the
            # endpoint is what actually has to agree.
            $script:MsecSession.Endpoints = @{
                GraphResource = 'https://microsoftgraph.chinacloudapi.cn'
                EnvironmentName = 'AzureChinaCloud'
            }
            $script:MsecSession.Tokens['https://microsoftgraph.chinacloudapi.cn'] = @{
                Token = 'cn'; ExpiresOn = [DateTimeOffset]::UtcNow.AddMinutes(55)
            }
            Mock Get-MsecAccessToken -MockWith { 'cn' }
            Mock Connect-MgGraph -MockWith { }

            Connect-MsecGraphSdk

            Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter { $Environment -eq 'China' }
            # ...and the token was requested for the sovereign endpoint, not the commercial one.
            Should -Invoke Get-MsecAccessToken -Times 1 -Exactly -ParameterFilter {
                $Resource -eq 'https://microsoftgraph.chinacloudapi.cn'
            }
        }
    }

    It 'refuses a token too close to expiry rather than failing mid-report' {
        InModuleScope Msec {
            $script:MsecSession.Tokens['https://graph.microsoft.com'] = @{
                Token = 'nearly-done'; ExpiresOn = [DateTimeOffset]::UtcNow.AddMinutes(3)
            }
            Mock Get-MsecAccessToken -MockWith { 'nearly-done' }
            Mock Connect-MgGraph -MockWith { }

            # Three minutes left, thirty wanted: a long report must not start.
            { Connect-MsecGraphSdk -MinimumMinutes 30 } | Should -Throw '*cannot renew*'
            Should -Invoke Connect-MgGraph -Times 0 -Exactly

            # ...but the default is small enough that an ordinary call still goes through.
            Connect-MsecGraphSdk -MinimumMinutes 1
            Should -Invoke Connect-MgGraph -Times 1 -Exactly
        }
    }

    It 'warns rather than silently signing in to the wrong cloud' {
        $warnings = @()
        InModuleScope Msec {
            # An endpoint no SDK environment knows: falling back to Global silently would
            # surface later as a wall of 401s that read as a permission problem.
            $script:MsecSession.Endpoints = @{ GraphResource = 'https://graph.example.invalid'; EnvironmentName = 'Custom' }
            $script:MsecSession.Tokens['https://graph.example.invalid'] = @{
                Token = 'x'; ExpiresOn = [DateTimeOffset]::UtcNow.AddMinutes(55)
            }
            Mock Get-MsecAccessToken -MockWith { 'x' }
            Mock Connect-MgGraph -MockWith { }

            Connect-MsecGraphSdk
        } -WarningVariable warnings -WarningAction SilentlyContinue

        ($warnings -join ' ') | Should -Match 'probably wrong for this cloud'
    }

    It 'throws a clear error when not connected' {
        InModuleScope Msec {
            $script:MsecSession = $null
            { Connect-MsecGraphSdk } | Should -Throw '*Connect-Msec*'
        }
    }
}
