#Requires -Module Pester
#
# Tests for Get-MsecAdoServiceConnection. The function makes two kinds of REST
# calls to dev.azure.com:
#   1. /_apis/projects                              -> list projects
#   2. /{project}/_apis/serviceendpoint/endpoints   -> list connections per project
# We mock the token + both endpoints. Coverage:
#   - Dedupe across projects (shared service connections appear in multiple
#     projects but should produce one row)
#   - Projects column lists every project the endpoint is exposed to
#   - Auth-scheme + type + IsShared flow through
#   - PSTypeName tagged for default Format-Table display
#   - 401/403 on the projects call rewrites to a helpful org-membership hint

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAdoServiceConnection' {
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

    It 'walks all projects, dedupes shared endpoints, and projects flat rows with Projects[] populated' {
        $rows = InModuleScope msec {
            Mock Get-MsecAccessToken -MockWith { 'mock-ado-token' }

            # /_apis/projects - org has two projects
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/_apis/projects' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ name = 'Proj-A' }
                    [pscustomobject]@{ name = 'Proj-B' }
                ) }
            }

            # Proj-A's endpoints: 2 connections, one project-scoped, one shared.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/Proj-A/_apis/serviceendpoint/endpoints' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ep-1'; name = 'AzureRM-Prod';   type = 'azurerm'
                        url = 'https://management.azure.com/'; description = 'Prod sub'
                        isShared = $false; isReady = $true
                        authorization = [pscustomobject]@{ scheme = 'ServicePrincipal' }
                        createdBy = [pscustomobject]@{ displayName = 'admin' }
                        serviceEndpointProjectReferences = @(
                            [pscustomobject]@{ projectReference = [pscustomobject]@{ name = 'Proj-A' } }
                        )
                        data = [pscustomobject]@{ subscriptionId = 'sub-prod-guid' }
                    }
                    [pscustomobject]@{
                        id = 'ep-2'; name = 'Docker-Registry'; type = 'docker'
                        url = 'https://docker.io'; description = 'Shared docker'
                        isShared = $true; isReady = $true
                        authorization = [pscustomobject]@{ scheme = 'UsernamePassword' }
                        createdBy = [pscustomobject]@{ displayName = 'admin' }
                        # Shared to BOTH projects
                        serviceEndpointProjectReferences = @(
                            [pscustomobject]@{ projectReference = [pscustomobject]@{ name = 'Proj-A' } }
                            [pscustomobject]@{ projectReference = [pscustomobject]@{ name = 'Proj-B' } }
                        )
                    }
                ) }
            }

            # Proj-B's endpoints: the SAME shared docker connection (should dedupe) +
            # one new GitHub connection that Proj-A doesn't see.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/Proj-B/_apis/serviceendpoint/endpoints' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ep-2'; name = 'Docker-Registry'; type = 'docker'
                        url = 'https://docker.io'; description = 'Shared docker'
                        isShared = $true; isReady = $true
                        authorization = [pscustomobject]@{ scheme = 'UsernamePassword' }
                        createdBy = [pscustomobject]@{ displayName = 'admin' }
                        serviceEndpointProjectReferences = @(
                            [pscustomobject]@{ projectReference = [pscustomobject]@{ name = 'Proj-A' } }
                            [pscustomobject]@{ projectReference = [pscustomobject]@{ name = 'Proj-B' } }
                        )
                    }
                    [pscustomobject]@{
                        id = 'ep-3'; name = 'GitHub-OAuth'; type = 'github'
                        url = 'https://github.com'; description = $null
                        isShared = $false; isReady = $true
                        authorization = [pscustomobject]@{ scheme = 'OAuth' }
                        createdBy = [pscustomobject]@{ displayName = 'admin' }
                        serviceEndpointProjectReferences = @(
                            [pscustomobject]@{ projectReference = [pscustomobject]@{ name = 'Proj-B' } }
                        )
                    }
                ) }
            }

            Get-MsecAdoServiceConnection -Organization 'contoso'
        }

        # 3 unique endpoints (Docker-Registry dedup'd to one row even though it
        # appeared in two projects' responses).
        $rows.Count | Should -Be 3

        # AzureRM
        $azurerm = $rows | Where-Object Id -eq 'ep-1'
        $azurerm.Name        | Should -Be 'AzureRM-Prod'
        $azurerm.Type        | Should -Be 'azurerm'
        $azurerm.AuthScheme  | Should -Be 'ServicePrincipal'
        $azurerm.IsShared    | Should -BeFalse
        $azurerm.Projects    | Should -Be @('Proj-A')
        # Raw retains everything Graph returned - including subscription id buried
        # in .data, which downstream callers can extract for auditing.
        $azurerm.Raw.data.subscriptionId | Should -Be 'sub-prod-guid'

        # Docker - shared, dedup'd, with both projects listed
        $docker = $rows | Where-Object Id -eq 'ep-2'
        $docker.IsShared    | Should -BeTrue
        $docker.Projects    | Should -Contain 'Proj-A'
        $docker.Projects    | Should -Contain 'Proj-B'
        $docker.Projects.Count | Should -Be 2

        # GitHub - only seen in Proj-B walk
        $gh = $rows | Where-Object Id -eq 'ep-3'
        $gh.Type        | Should -Be 'github'
        $gh.AuthScheme  | Should -Be 'OAuth'

        # PSTypeName tag set so the .psm1 DefaultDisplayPropertySet works.
        $azurerm.PSObject.TypeNames | Should -Contain 'MsecAdoServiceConnection'
    }

    It 'passes the bare ADO resource ID to Get-MsecAccessToken (no /.default suffix)' {
        # Regression guard: Get-MsecAccessToken appends /.default itself. Passing
        # '<resource>/.default' to it produces a malformed scope and Entra 400s.
        # This test fails if anyone re-introduces the bug by hardcoding the suffix.
        InModuleScope msec {
            $script:CapturedResource = $null
            Mock Get-MsecAccessToken -MockWith {
                $script:CapturedResource = $Resource
                'mock-token'
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/_apis/projects\?' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            Get-MsecAdoServiceConnection -Organization 'contoso' | Out-Null

            $script:CapturedResource | Should -Not -BeNullOrEmpty
            $script:CapturedResource | Should -Be '499b84ac-1321-427f-aa17-267ca6975798'
            $script:CapturedResource | Should -Not -Match '/\.default'
        }
    }

    It '-Project restricts to a single project (no /projects call needed)' {
        InModuleScope msec {
            Mock Get-MsecAccessToken -MockWith { 'mock' }
            $script:ProjectsListCalls = 0
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/_apis/projects\?' } -MockWith {
                $script:ProjectsListCalls++
                [pscustomobject]@{ value = @() }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/MyProject/_apis/serviceendpoint/endpoints' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ep-1'; name = 'X'; type = 'azurerm'
                        authorization = [pscustomobject]@{ scheme = 'ServicePrincipal' }
                        createdBy = [pscustomobject]@{ displayName = 'x' }
                        serviceEndpointProjectReferences = @(
                            [pscustomobject]@{ projectReference = [pscustomobject]@{ name = 'MyProject' } }
                        )
                    }
                ) }
            }

            $r = Get-MsecAdoServiceConnection -Organization 'contoso' -Project 'MyProject'
            $r.Count                       | Should -Be 1
            # The /_apis/projects list endpoint should NOT have been called.
            $script:ProjectsListCalls      | Should -Be 0
        }
    }

    It 'rewrites a 401/403 on the projects-list call to mention ADO org membership' {
        InModuleScope msec {
            Mock Get-MsecAccessToken -MockWith { 'mock' }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/_apis/projects\?' } -MockWith {
                throw 'Response status code does not indicate success: 401 (Unauthorized).'
            }

            { Get-MsecAdoServiceConnection -Organization 'contoso' } |
                Should -Throw -ExpectedMessage '*added as a member of the ADO organization*'
        }
    }
}
