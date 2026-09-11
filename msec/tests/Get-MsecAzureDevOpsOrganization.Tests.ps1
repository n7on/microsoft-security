#Requires -Module Pester
#
# Tests for Get-MsecAzureDevOpsOrganization.
#
# The endpoint returns CSV, not JSON, and its headers contain spaces - 'Organization Id',
# 'Organization Name'. That is unusual enough to pin: a rename to camelCase would silently
# produce rows of nulls rather than an error.
#
# It is also an INTERNAL route with no documented equivalent, so an empty result must warn. A
# tenant with no Azure DevOps organizations is possible; a tenant whose enumeration route changed
# shape is far likelier, and reporting the second as the first would end an investigation that
# should have started.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureDevOpsOrganization' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 'tenant-1'; ClientId = 'c'; Tokens = @{} }
            Mock Get-MsecAccessToken -MockWith { 'ADO.TOKEN' }
        }
    }

    It 'parses the CSV the tenant endpoint returns' {
        $rows = InModuleScope msec {
            Mock Invoke-WebRequest -MockWith {
                [pscustomobject]@{ Content = @'
Organization Id, Organization Name, Url, Owner
c76c60d9-b74d-45ad-9cd8-7d94ea892f98, alpha, https://dev.azure.com/alpha/, ada@contoso.com
bffbbe1b-9b1e-4d3a-9efd-4b62a38df5c1, beta, https://dev.azure.com/beta/, bob@contoso.com
'@ }
            }
            Get-MsecAzureDevOpsOrganization
        }

        # Headers carry spaces. A well-meaning rename to camelCase would produce rows of nulls
        # rather than an error.
        @($rows).Count       | Should -Be 2
        $rows[0].Organization | Should -Be 'alpha'
        $rows[0].Owner        | Should -Be 'ada@contoso.com'
        $rows[0].Id           | Should -Be 'c76c60d9-b74d-45ad-9cd8-7d94ea892f98'
    }

    It 'queries the tenant of the session by default' {
        InModuleScope msec {
            Mock Invoke-WebRequest -MockWith {
                [pscustomobject]@{ Content = "Organization Id, Organization Name, Url, Owner`nid, o, u, e@x.com" }
            }

            Get-MsecAzureDevOpsOrganization | Out-Null

            # This is a TENANT query, not an organization one - the whole point is finding
            # organizations nobody told you about, so it cannot require naming one.
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -match 'EnterpriseCatalog/Organizations\?tenantId=tenant-1'
            }
        }
    }

    It 'asks Azure DevOps for a token, not Graph' {
        InModuleScope msec {
            Mock Invoke-WebRequest -MockWith {
                [pscustomobject]@{ Content = "Organization Id, Organization Name, Url, Owner`nid, o, u, e@x.com" }
            }
            Get-MsecAzureDevOpsOrganization | Out-Null
            Should -Invoke Get-MsecAccessToken -Times 1 -Exactly -ParameterFilter {
                $Resource -eq '499b84ac-1321-427f-aa17-267ca6975798'
            }
        }
    }

    It 'warns rather than reporting a tenant with no organizations' {
        $warnings = @()
        $rows = InModuleScope msec {
            Mock Invoke-WebRequest -MockWith { [pscustomobject]@{ Content = 'Organization Id, Organization Name, Url, Owner' } }
            Get-MsecAzureDevOpsOrganization
        } -WarningVariable warnings -WarningAction SilentlyContinue

        # The route is internal and undocumented. A changed shape must not read as an empty
        # tenant, because that ends an investigation instead of starting one.
        @($rows).Count | Should -Be 0
        ($warnings -join ' ') | Should -Match 'UNREAD'
    }

    It 'explains a 403 as a tenant-level permission, not organization membership' {
        InModuleScope msec {
            Mock Invoke-WebRequest -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            { Get-MsecAzureDevOpsOrganization } | Should -Throw '*tenant-level query*'
        }
    }

    It 'throws a clear error when not connected' {
        InModuleScope msec {
            $script:MsecSession = $null
            { Get-MsecAzureDevOpsOrganization } | Should -Throw '*Connect-Msec*'
        }
    }
}
