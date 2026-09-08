#Requires -Module Pester
#
# Tests for Get-MsecAzureRoleAssignment.
#
# The design this pins down is the identity split. Get-AzRoleAssignment resolves principal
# names by calling Graph ITSELF, using whatever identity holds the Az context - which works for
# a person, who has directory read by default, and silently returns blank names for a service
# principal without Graph permissions. A pipeline running that code produces a report full of
# GUIDs and no error.
#
# So the lookups are deliberately separate: assignments and role names through ARM, principals
# through the msec Graph session. That is also what lets the ARM identity hold no directory
# permissions at all.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureRoleAssignment' {

    BeforeEach {
        InModuleScope Msec {
            $script:MsecSession = @{
                TenantId = 't'; ClientId = 'c'; KeyVaultName = 'kv'; KeyName = 'k'
                ThumbprintBytes = [byte[]](1..20); Tokens = @{}
                Endpoints = @{ GraphResource = 'https://graph.microsoft.com'; EnvironmentName = 'AzureCloud' }
            }
            Mock Search-MsecAzureResourceGraph -MockWith {
                [pscustomobject]@{ PrincipalId = 'p1'; PrincipalType = 'User';  RoleDefinitionGuid = 'r1'
                                   ScopeLevel = 'Subscription'; ScopeName = 'sub-1'; Scope = '/subscriptions/sub-1'
                                   SubscriptionName = 'PROD'; SubscriptionId = 'sub-1'; Id = 'a1'; CreatedOn = $null }
                [pscustomobject]@{ PrincipalId = 'p2'; PrincipalType = 'ServicePrincipal'; RoleDefinitionGuid = 'r1'
                                   ScopeLevel = 'ResourceGroup'; ScopeName = 'rg'; Scope = '/subscriptions/sub-1/resourceGroups/rg'
                                   SubscriptionName = 'PROD'; SubscriptionId = 'sub-1'; Id = 'a2'; CreatedOn = $null }
                # A principal that no longer exists - its assignment outlived it.
                [pscustomobject]@{ PrincipalId = 'gone'; PrincipalType = 'ServicePrincipal'; RoleDefinitionGuid = 'r2'
                                   ScopeLevel = 'Subscription'; ScopeName = 'sub-1'; Scope = '/subscriptions/sub-1'
                                   SubscriptionName = 'PROD'; SubscriptionId = 'sub-1'; Id = 'a3'; CreatedOn = $null }
            }
            # Role names come from ARM REST, not Get-AzRoleDefinition - that cmdlet is in
            # Az.Resources, which msec does not depend on, so it is present on a developer's
            # machine and absent on a clean agent.
            Mock Invoke-AzRestMethod -MockWith {
                $guid = ($Path -split '/')[-1] -replace '\?.*$', ''
                $name = switch ($guid) { 'r1' { 'Owner' } 'r2' { 'Contributor' } default { 'Unknown' } }
                [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ roleName = $name } } | ConvertTo-Json) }
            }
        }
    }

    It 'resolves principals in bulk, not one call per assignment' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'p1'; displayName = 'Ada'; userPrincipalName = 'ada@x.com'; '@odata.type' = '#microsoft.graph.user' }
                    [pscustomobject]@{ id = 'p2'; displayName = 'ci-runner'; '@odata.type' = '#microsoft.graph.servicePrincipal' }
                ) }
            }
            $result = Get-MsecAzureRoleAssignment

            # ONE call for all three ids. Per-assignment lookups would be 2415 round trips on a
            # real tenant.
            Should -Invoke Invoke-MsecGraphRequest -Times 1 -Exactly -ParameterFilter {
                $Path -match 'getByIds' -and $Method -eq 'POST'
            }
            $result
        }

        ($rows | Where-Object PrincipalId -eq 'p1').PrincipalName | Should -Be 'Ada'
        ($rows | Where-Object PrincipalId -eq 'p1').RoleName      | Should -Be 'Owner'
        ($rows | Where-Object PrincipalId -eq 'p2').PrincipalName | Should -Be 'ci-runner'
    }

    It 'keeps an assignment whose principal no longer exists' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                # Graph returns nothing for 'gone' - a deleted service principal. Verified
                # against a live tenant: 85 of 94 unresolved subscription-scope assignments
                # were exactly this.
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'p1'; displayName = 'Ada' }
                    [pscustomobject]@{ id = 'p2'; displayName = 'ci-runner' }
                ) }
            }
            Get-MsecAzureRoleAssignment
        }

        $orphan = $rows | Where-Object PrincipalId -eq 'gone'
        # Dropping it would hide standing Azure rights held by nothing - the finding itself.
        $orphan               | Should -Not -BeNullOrEmpty
        $orphan.IsResolved    | Should -BeFalse
        $orphan.PrincipalName | Should -BeNullOrEmpty
        $orphan.RoleName      | Should -Be 'Contributor'
    }

    It 'warns rather than silently returning GUIDs when there is no msec session' {
        $warnings = @()
        $rows = InModuleScope Msec {
            # This is precisely how Get-AzRoleAssignment fails in a pipeline: names come back
            # blank and nothing says why.
            $script:MsecSession = $null
            Get-MsecAzureRoleAssignment
        } -WarningVariable warnings -WarningAction SilentlyContinue

        @($rows).Count | Should -Be 3
        @($rows | Where-Object IsResolved).Count | Should -Be 0
        ($warnings -join ' ') | Should -Match 'principal names cannot be resolved'
        # Role names still work - they come from ARM, not Graph.
        ($rows | Where-Object PrincipalId -eq 'p1').RoleName | Should -Be 'Owner'
    }

    It 'resolves each distinct role once, not once per assignment' {
        InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith { [pscustomobject]@{ value = @() } }
            Get-MsecAzureRoleAssignment -WarningAction SilentlyContinue | Out-Null
            # Two distinct roles across three assignments. An estate has thousands of
            # assignments and a few dozen roles.
            Should -Invoke Invoke-AzRestMethod -Times 2 -Exactly
        }
    }

    It 'filters by scope level, which is what makes a row actionable' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith { [pscustomobject]@{ value = @() } }
            Get-MsecAzureRoleAssignment -ScopeLevel Subscription -WarningAction SilentlyContinue
        }

        # Owner at subscription scope is a different finding from Owner on one storage account.
        @($rows).Count | Should -Be 2
        @($rows | ForEach-Object { $_.ScopeLevel } | Select-Object -Unique) | Should -Be @('Subscription')
    }
}
