#Requires -Module Pester
#
# Tests for Get-MsecAzureDevOpsOrganizationPolicy.
#
# These policies are the ORGANIZATION's ceiling - the same role the SharePoint tenant settings
# and the Teams Global policy play.
#
# THERE IS NO REST API. _apis/organizationpolicy/policies 404s on every api-version and on both
# hosts; the only source is the data provider behind the portal's own settings page. The shape
# below was captured from a live organization, not invented, because the first version of this
# command was written against a documented-looking endpoint that does not exist and passed its
# mocked tests regardless.
#
# Two things worth pinning hardest. isValueUndefined is OMITTED for a policy someone set and
# present-and-true for one on its default, so absence means "explicitly configured" - reading a
# missing property as unknown reported every configured policy as blank. And an empty provider
# must warn rather than return nothing, because this route is internal and can change shape.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureDevOpsOrganizationPolicy' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-MsecAccessToken -MockWith { 'ADO.TOKEN' }

            # The provider payload, shaped as a live organization returns it.
            function script:New-PolicyResponse {
                param($Policies, $Inverted = @(), [switch] $Empty)
                $data = if ($Empty) {
                    @{ 'ms.vss-admin-web.organization-policies-data-provider' = $null }
                }
                else {
                    @{ 'ms.vss-admin-web.organization-policies-data-provider' = @{
                        policies         = $Policies
                        invertedPolicies = @($Inverted)
                    } }
                }
                [pscustomobject]@{
                    Content = (@{ fps = @{ dataProviders = @{ data = $data } } } | ConvertTo-Json -Depth 12)
                }
            }
        }
    }

    It 'reads the portal data provider, not the REST route that does not exist' {
        InModuleScope msec {
            Mock Invoke-WebRequest -MockWith {
                New-PolicyResponse -Policies @{ security = @(
                    @{ description = 'Log audit events'; policy = @{ name = 'Policy.LogAuditEvents'; effectiveValue = $true } }) }
            }

            Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' | Out-Null

            # _apis/organizationpolicy/policies 404s. An api-version on this route 404s too.
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -match '_settings/organizationPolicy\?__rt=fps&__ver=2' -and
                $Uri -notmatch 'api-version' -and
                $Headers.Authorization -eq 'Bearer ADO.TOKEN'
            }
        }
    }

    It 'asks Azure DevOps for a token, not Graph' {
        InModuleScope msec {
            Mock Invoke-WebRequest -MockWith { New-PolicyResponse -Policies @{ security = @() } }
            Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' | Out-Null
            Should -Invoke Get-MsecAccessToken -Times 1 -Exactly -ParameterFilter {
                $Resource -eq '499b84ac-1321-427f-aa17-267ca6975798'
            }
        }
    }

    It 'groups by the provider own categories and uses the portal label' {
        $rows = InModuleScope msec {
            Mock Invoke-WebRequest -MockWith {
                New-PolicyResponse -Policies @{
                    applicationConnection = @(
                        @{ description = 'Third-party application access via OAuth'
                           policy = @{ name = 'Policy.DisallowOAuthAuthentication'; effectiveValue = $true; isValueUndefined = $true } })
                    privacy = @(
                        @{ description = 'Allow Microsoft to collect feedback from users'
                           policy = @{ name = 'Policy.AllowFeedbackCollection'; effectiveValue = $true; isValueUndefined = $true } })
                } -Inverted @('Policy.DisallowOAuthAuthentication')
            }
            Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso'
        }

        # The category comes from the payload, so there is no table here to drift out of date.
        ($rows | Where-Object Policy -eq 'DisallowOAuthAuthentication').Category | Should -Be 'Application connection'
        ($rows | Where-Object Policy -eq 'AllowFeedbackCollection').Category     | Should -Be 'Privacy'
        # 'DisallowOAuthAuthentication' means nothing to a reviewer; the portal's label does.
        ($rows | Where-Object Policy -eq 'DisallowOAuthAuthentication').Setting  | Should -Be 'Third-party application access via OAuth'
    }

    It 'flags the policies the settings page renders inverted' {
        $rows = InModuleScope msec {
            Mock Invoke-WebRequest -MockWith {
                New-PolicyResponse -Policies @{ applicationConnection = @(
                    @{ description = 'SSH authentication'; policy = @{ name = 'Policy.DisallowSecureShell'; effectiveValue = $true } }
                    @{ description = 'Validate SSH key expiration'; policy = @{ name = 'Policy.ValidateSshKeyExpiration'; effectiveValue = $true } })
                } -Inverted @('Policy.DisallowSecureShell')
            }
            Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso'
        }

        # Value is raw. Read with the policy NAME it is unambiguous; read against the page's
        # label it is backwards, and IsInverted is what says which.
        ($rows | Where-Object Policy -eq 'DisallowSecureShell').IsInverted      | Should -BeTrue
        ($rows | Where-Object Policy -eq 'ValidateSshKeyExpiration').IsInverted | Should -BeFalse
    }

    It 'treats a MISSING isValueUndefined as explicitly configured' {
        $rows = InModuleScope msec {
            Mock Invoke-WebRequest -MockWith {
                New-PolicyResponse -Policies @{ security = @(
                    # Someone set this one: the provider omits isValueUndefined entirely.
                    @{ description = 'Log audit events'; policy = @{ name = 'Policy.LogAuditEvents'; effectiveValue = $true } }
                    # Still on its default: present, and true.
                    @{ description = 'Restrict PAT creation'; policy = @{ name = 'Policy.DisablePATCreation'; effectiveValue = $false; isValueUndefined = $true } })
                }
            }
            Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso'
        }

        # Reading the absent property as "unknown" reported every configured policy as blank -
        # which is the opposite of what it means.
        ($rows | Where-Object Policy -eq 'LogAuditEvents').IsExplicit    | Should -BeTrue
        ($rows | Where-Object Policy -eq 'DisablePATCreation').IsExplicit | Should -BeFalse
    }

    It 'keeps a category this module has never heard of' {
        $rows = InModuleScope msec {
            Mock Invoke-WebRequest -MockWith {
                New-PolicyResponse -Policies @{ somethingNew = @(
                    @{ description = 'A setting added last week'; policy = @{ name = 'Policy.Whatever'; effectiveValue = $true } }) }
            }
            Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso'
        }

        # Dropping it would hide exactly the new policy nobody has reviewed yet.
        @($rows).Count | Should -Be 1
        $rows.Category | Should -Be 'somethingNew'
    }

    It 'warns rather than returning nothing when the provider is absent' {
        $warnings = @()
        $rows = InModuleScope msec {
            Mock Invoke-WebRequest -MockWith { New-PolicyResponse -Empty }
            Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        # This route is internal to the portal. If it changes shape, an empty list would read as
        # an organization with no policies set.
        @($rows).Count | Should -Be 0
        ($warnings -join ' ') | Should -Match 'UNREAD|internal'
    }

    It 'explains a 401 as ADO membership, not as an Entra permission' {
        InModuleScope msec {
            Mock Invoke-WebRequest -MockWith { throw 'Response status code does not indicate success: 401 (Unauthorized).' }
            { Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' } | Should -Throw '*Organization Settings*'
        }
    }

    It 'distinguishes a token failure from a membership failure' {
        InModuleScope msec {
            Mock Get-MsecAccessToken -MockWith { throw 'certificate expired' }
            { Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' } | Should -Throw '*Entra-side*'
        }
    }

    It 'throws a clear error when not connected' {
        InModuleScope msec {
            $script:MsecSession = $null
            { Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' } | Should -Throw '*Connect-Msec*'
        }
    }
}
