#Requires -Module Pester
#
# Tests for Get-MsecAzureDevOpsOrganizationPolicy.
#
# These policies are the ORGANIZATION's ceiling - the same role the SharePoint tenant settings
# and the Teams Global policy play. A well-run project inside an org that allows third-party
# OAuth apps is still exposed, and reviewing projects one at a time never shows it.
#
# Three things worth pinning. The API has shipped more than one response shape, and guessing
# wrong produces empty rows that read as "no policies set". A policy nobody ever configured
# reports a DEFAULT, which is not a decision anyone made. And an empty response means the
# account cannot see organization settings, which must not read as a clean org.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureDevOpsOrganizationPolicy' {

    BeforeEach {
        InModuleScope Msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-MsecAccessToken -MockWith { 'ADO.TOKEN' }
        }
    }

    It 'asks Azure DevOps for a token, not Graph, and presents it as a bearer' {
        InModuleScope Msec {
            Mock Invoke-RestMethod -MockWith { [pscustomobject]@{ value = @(
                [pscustomobject]@{ policy = [pscustomobject]@{ name = 'Policy.DisallowOAuthAuthentication'; effectiveValue = $false; isValueUndefined = $false } }) } }

            Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' | Out-Null

            # ADO is its own Entra resource; a Graph token is rejected outright.
            Should -Invoke Get-MsecAccessToken -Times 1 -Exactly -ParameterFilter {
                $Resource -eq '499b84ac-1321-427f-aa17-267ca6975798'
            }
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri -match 'dev\.azure\.com/contoso/_apis/organizationpolicy/policies' -and
                $Headers.Authorization -eq 'Bearer ADO.TOKEN'
            }
        }
    }

    It 'reads the nested policy shape, and trims the prefix every name carries' {
        $rows = InModuleScope Msec {
            Mock Invoke-RestMethod -MockWith { [pscustomobject]@{ value = @(
                [pscustomobject]@{ policy = [pscustomobject]@{ name = 'Policy.DisallowAadGuestUserAccess'; effectiveValue = $true; isValueUndefined = $false } }) } }
            Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso'
        }

        $rows.Setting    | Should -Be 'DisallowAadGuestUserAccess'
        $rows.Value      | Should -Be 'True'
        $rows.Category   | Should -Be 'Access'
        $rows.IsExplicit | Should -BeTrue
    }

    It 'reads the flat shape too, because the API has shipped both' {
        $rows = InModuleScope Msec {
            # Guessing one shape and getting the other yields rows of nulls, which read as an
            # organization with nothing configured.
            Mock Invoke-RestMethod -MockWith { [pscustomobject]@{ value = @(
                [pscustomobject]@{ name = 'Policy.LogAuditEvents'; effectiveValue = $true; isValueUndefined = $false }) } }
            Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso'
        }

        $rows.Setting  | Should -Be 'LogAuditEvents'
        $rows.Category | Should -Be 'Auditing'
    }

    It 'marks a policy nobody ever set, because a safe default is not a decision' {
        $rows = InModuleScope Msec {
            Mock Invoke-RestMethod -MockWith { [pscustomobject]@{ value = @(
                [pscustomobject]@{ policy = [pscustomobject]@{ name = 'Policy.AllowAnonymousAccess'; effectiveValue = $false; isValueUndefined = $true } }) } }
            Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso'
        }

        # The value is safe today and nobody chose it, so nothing stops it changing.
        $rows.IsExplicit | Should -BeFalse
        $rows.Value      | Should -Be 'False'
    }

    It 'keeps a policy this table has never heard of' {
        $rows = InModuleScope Msec {
            Mock Invoke-RestMethod -MockWith { [pscustomobject]@{ value = @(
                [pscustomobject]@{ policy = [pscustomobject]@{ name = 'Policy.SomethingMicrosoftAddedLastWeek'; effectiveValue = $true; isValueUndefined = $false } }) } }
            Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso'
        }

        # Dropping it would hide exactly the new setting nobody has reviewed yet.
        @($rows).Count | Should -Be 1
        $rows.Category | Should -Be 'Other'
    }

    It 'warns rather than returning nothing when the response is empty' {
        $warnings = @()
        $rows = InModuleScope Msec {
            Mock Invoke-RestMethod -MockWith { [pscustomobject]@{ value = @() } }
            Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        # An account that authenticates but cannot see organization settings gets an empty list,
        # which would otherwise read as an organization with no policies to worry about.
        @($rows).Count | Should -Be 0
        ($warnings -join ' ') | Should -Match 'unread'
    }

    It 'explains a 401 as ADO membership, not as an Entra permission' {
        InModuleScope Msec {
            Mock Invoke-RestMethod -MockWith { throw 'Response status code does not indicate success: 401 (Unauthorized).' }

            # New-MsecApp cannot fix this one - the access is granted inside Azure DevOps - so
            # an error pointing at Entra permissions sends the reader somewhere useless.
            { Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' } |
                Should -Throw '*Organization Settings*'
        }
    }

    It 'distinguishes a token failure from a membership failure' {
        InModuleScope Msec {
            Mock Get-MsecAccessToken -MockWith { throw 'certificate expired' }
            { Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' } | Should -Throw '*Entra-side*'
        }
    }

    It 'throws a clear error when not connected' {
        InModuleScope Msec {
            $script:MsecSession = $null
            { Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' } | Should -Throw '*Connect-Msec*'
        }
    }
}
