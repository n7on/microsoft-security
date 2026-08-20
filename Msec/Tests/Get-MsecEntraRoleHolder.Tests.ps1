#Requires -Module Pester
#
# Tests for Get-MsecEntraRoleHolder. The behaviours that matter are the ones a
# partial implementation would get wrong and still look plausible: eligible
# assignments appearing at all, role-assignable groups expanding to the users inside
# them, nested groups not double-counting, AU-scoped assignments not being read as
# tenant-wide, and a tenant without Entra ID P2 degrading to a warning rather than
# either failing or silently reporting a short list.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)

    # Every run writes the directory-roles cache for the -Role completer. Redirected so
    # the suite cannot touch the developer's real cache.
    $script:PrevCacheEnv = $env:MSEC_CACHE_DIR
    $env:MSEC_CACHE_DIR  = Join-Path ([System.IO.Path]::GetTempPath()) "msec-test-cache-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $env:MSEC_CACHE_DIR -Force | Out-Null
    $script:CacheDir = $env:MSEC_CACHE_DIR
}

AfterAll {
    if ($script:CacheDir -and (Test-Path -LiteralPath $script:CacheDir)) {
        Remove-Item -LiteralPath $script:CacheDir -Recurse -Force
    }
    $env:MSEC_CACHE_DIR = $script:PrevCacheEnv
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEntraRoleHolder' {
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

    It 'merges active and eligible assignments, expands groups, and flags privileged roles by template id' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    # Renamed away from 'Global Administrator' to prove the privileged
                    # flag is a templateId lookup, not a display-name match.
                    [pscustomobject]@{
                        id = '62e90394-69f5-4237-9190-012177145e10'
                        templateId = '62e90394-69f5-4237-9190-012177145e10'
                        displayName = 'Tenant God Mode'; isBuiltIn = $true
                    }
                    [pscustomobject]@{
                        id = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
                        templateId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
                        displayName = 'Global Reader'; isBuiltIn = $true
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'u1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u1'; displayName = 'Anton'
                            userPrincipalName = 'anton@example.com'; accountEnabled = $true
                        }
                    }
                    # A role assigned to a role-assignable GROUP. The whole point: the
                    # users inside must surface, not just the group object.
                    [pscustomobject]@{
                        id = 'ra2'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'g1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.group'
                            id = 'g1'; displayName = 'Tier0 Admins'
                        }
                    }
                    [pscustomobject]@{
                        id = 'ra3'; roleDefinitionId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
                        principalId = 'u9'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u9'; userPrincipalName = 'auditor@example.com'; accountEnabled = $true
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 're1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'u2'; directoryScopeId = '/'
                        startDateTime = '2026-01-01T00:00:00Z'; endDateTime = $null
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u2'; displayName = 'Eligible Erik'
                            userPrincipalName = 'erik@example.com'; accountEnabled = $true
                        }
                    }
                ) }
            }
            # Members are fetched one type at a time via an OData cast, so the $select
            # can name user-only properties. A cast response omits @odata.type, which
            # the function must fill in from the cast it asked for.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/groups/g1/transitiveMembers/microsoft.graph.user' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'u3'; displayName = 'Nested Nina'
                        userPrincipalName = 'nina@example.com'; accountEnabled = $true
                        userType = 'Guest'; onPremisesSyncEnabled = $null
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/groups/g1/transitiveMembers/microsoft.graph.servicePrincipal' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'sp1'; displayName = 'break-glass-app'; accountEnabled = $true }
                ) }
            }
            # The uncast collection must not be used - it returns nested groups and a
            # property subset without userType or accountEnabled.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/groups/g1/transitiveMembers$' } -MockWith {
                throw 'the uncast transitiveMembers collection must not be queried'
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'privilegedAccess/group/eligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            Get-MsecEntraRoleHolder
        }

        # 2 direct user rows + 1 eligible + 2 expanded group members. The group itself
        # is REPLACED by its members, and the nested group row is skipped - so a group
        # of two contributes two rows, not three.
        $rows.Count | Should -Be 5

        $ga = @($rows | Where-Object RoleTemplateId -eq '62e90394-69f5-4237-9190-012177145e10')
        $ga.Count | Should -Be 4
        ($ga | Select-Object -Unique IsHighlyPrivileged).IsHighlyPrivileged | Should -BeTrue
        ($ga | Select-Object -Unique RoleName).RoleName | Should -Be 'Tenant God Mode'

        # The eligible administrator - invisible to the older /directoryRoles endpoint.
        $erik = $rows | Where-Object EffectiveId -eq 'u2'
        $erik.AssignmentType | Should -Be 'Eligible'
        $erik.MembershipType | Should -BeNullOrEmpty   # assignee and holder are one object
        $erik.EndDateTime    | Should -BeNullOrEmpty   # permanently eligible
        $erik.IsActiveNow    | Should -BeFalse         # eligibility must be activated

        # Active assignments carry no schedule, so EndDateTime must not be invented.
        $u1 = $rows | Where-Object EffectiveId -eq 'u1'
        $u1.AssignmentType | Should -Be 'Active'
        $u1.EndDateTime    | Should -BeNullOrEmpty
        $u1.IsActiveNow    | Should -BeTrue

        # On a direct assignment the assignee IS the holder - both sets of columns carry
        # the same identity rather than one of them being empty.
        $u1.PrincipalId    | Should -Be 'u1'
        $u1.PrincipalType  | Should -Be 'user'
        $u1.PrincipalName  | Should -Be 'anton@example.com'
        $u1.EffectiveName  | Should -Be 'anton@example.com'
        $u1.MembershipType | Should -BeNullOrEmpty

        # No row is left with an unknown holder: every group resolved.
        @($rows | Where-Object { -not $_.IsResolved }).Count | Should -Be 0

        $nina = $rows | Where-Object EffectiveId -eq 'u3'
        # The ASSIGNEE is the group the role is on - the object you would act on to
        # revoke the assignment - while the HOLDER is the person inside it.
        $nina.PrincipalName     | Should -Be 'Tier0 Admins'
        $nina.PrincipalType     | Should -Be 'group'
        $nina.PrincipalId       | Should -Be 'g1'
        $nina.EffectiveName     | Should -Be 'nina@example.com'
        # The cast response carried no @odata.type; the cast itself must supply it.
        $nina.EffectiveType     | Should -Be 'user'
        $nina.MembershipType    | Should -Be 'Active'
        $nina.RoleName          | Should -Be 'Tenant God Mode'
        # Detail columns describe the HOLDER, not the group it came through.
        $nina.UserPrincipalName | Should -Be 'nina@example.com'
        # A GUEST holding a privileged role through a group, and its enabled state -
        # both of which the uncast collection's property subset would have hidden.
        $nina.UserType          | Should -Be 'Guest'
        $nina.AccountEnabled    | Should -BeTrue
        $nina.IsDirectorySynced | Should -BeFalse   # Graph reports cloud-only as null

        # A service principal has no UPN - so UserPrincipalName stays null (it is
        # strictly a UPN, and the blank is how you spot an app), and DisplayName names
        # it - so a privileged application is never an anonymous row.
        $sp = $rows | Where-Object EffectiveId -eq 'sp1'
        $sp.EffectiveType     | Should -Be 'servicePrincipal'
        $sp.UserPrincipalName | Should -BeNullOrEmpty
        $sp.DisplayName       | Should -Be 'break-glass-app'
        # ...and EffectiveName falls back to that name, so the pair (type, name)
        # identifies an app as well as it identifies a person.
        $sp.EffectiveName     | Should -Be 'break-glass-app'
        $sp.IsResolved        | Should -BeTrue
        # UserType and IsDirectorySynced are user-only facts; inventing them for an
        # app would put 'Member' next to something that has no account type at all.
        $sp.UserType          | Should -BeNullOrEmpty
        $sp.IsDirectorySynced | Should -BeNullOrEmpty

        # The group is never its own holder when it resolved - counting both the group
        # and its members would inflate every report built on this.
        $rows | Where-Object EffectiveId -eq 'g1' | Should -BeNullOrEmpty
        # The nested group is structure, not a principal.
        $rows | Where-Object EffectiveId -eq 'g2' | Should -BeNullOrEmpty

        # Global Reader is read-only and deliberately not privileged.
        ($rows | Where-Object EffectiveId -eq 'u9').IsHighlyPrivileged | Should -BeFalse

        $rows[0].PSObject.TypeNames | Should -Contain 'MsecEntraRoleHolder'
    }

    It 'projects administrative-unit scope and does not read it as tenant-wide' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'fe930be7-5e62-47db-91af-98c3a49a38b1'
                        templateId = 'fe930be7-5e62-47db-91af-98c3a49a38b1'
                        displayName = 'User Administrator'
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = 'fe930be7-5e62-47db-91af-98c3a49a38b1'
                        principalId = 'u1'; directoryScopeId = '/administrativeUnits/au-guid'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u1'; userPrincipalName = 'scoped@example.com'
                        }
                    }
                    [pscustomobject]@{
                        id = 'ra2'; roleDefinitionId = 'fe930be7-5e62-47db-91af-98c3a49a38b1'
                        principalId = 'u2'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u2'; userPrincipalName = 'tenantwide@example.com'
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            Get-MsecEntraRoleHolder
        }

        $scoped = $rows | Where-Object PrincipalId -eq 'u1'
        $scoped.Scope            | Should -Be 'AdministrativeUnit:au-guid'
        $scoped.IsTenantScoped   | Should -BeFalse
        $scoped.DirectoryScopeId | Should -Be '/administrativeUnits/au-guid'

        $wide = $rows | Where-Object PrincipalId -eq 'u2'
        $wide.Scope          | Should -Be 'Tenant'
        $wide.IsTenantScoped | Should -BeTrue
    }

    It 'warns about the missing licence and still returns active assignments when the tenant has no Entra ID P2' {
        $result = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = '62e90394-69f5-4237-9190-012177145e10'
                        templateId = '62e90394-69f5-4237-9190-012177145e10'
                        displayName = 'Global Administrator'
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'u1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u1'; userPrincipalName = 'anton@example.com'
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                $err = [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new('Response status code does not indicate success: 403 (Forbidden).'),
                    'GraphError', 'InvalidOperation', $null)
                throw $err
            }

            # The 403 body is what tells licensing apart from permission; without
            # ErrorDetails the function must fall back to the permission wording.
            $warnings = @()
            $rows = Get-MsecEntraRoleHolder -WarningVariable warnings -WarningAction SilentlyContinue
            [pscustomobject]@{ Rows = @($rows); Warnings = @($warnings) }
        }

        # Active assignments survive - a failed eligibility read must not sink them.
        $result.Rows.Count       | Should -Be 1
        $result.Rows[0].RoleName | Should -Be 'Global Administrator'

        # And the incompleteness is stated, not swallowed.
        $result.Warnings.Count | Should -BeGreaterThan 0
        ($result.Warnings -join ' ') | Should -Match 'INCOMPLETE|licence'
    }

    It 'skips the eligibility call entirely with -AssignmentType Active' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = '62e90394-69f5-4237-9190-012177145e10'
                        templateId = '62e90394-69f5-4237-9190-012177145e10'
                        displayName = 'Global Administrator'
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'u1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u1'; userPrincipalName = 'anton@example.com'
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                throw 'eligibility must not be queried when -AssignmentType Active'
            }

            Get-MsecEntraRoleHolder -AssignmentType Active
        }

        $rows.Count              | Should -Be 1
        $rows[0].AssignmentType  | Should -Be 'Active'
    }

    It 'fetches a role definition the collection omits rather than reporting a bare GUID' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            # The collection knows nothing about the assigned definition...
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions\?' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            # ...but a direct read of it succeeds, as it does for hidden built-ins.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions/11111111' } -MockWith {
                [pscustomobject]@{
                    id = '11111111-2222-3333-4444-555555555555'
                    templateId = '11111111-2222-3333-4444-555555555555'
                    displayName = 'Some Hidden Built-In'; isBuiltIn = $true
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '11111111-2222-3333-4444-555555555555'
                        principalId = 'u1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u1'; userPrincipalName = 'anton@example.com'
                        }
                    }
                    # A second assignment of the same definition must not re-fetch it;
                    # if it did, the mock below would still answer, so assert the count.
                    [pscustomobject]@{
                        id = 'ra2'; roleDefinitionId = '11111111-2222-3333-4444-555555555555'
                        principalId = 'u2'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u2'; userPrincipalName = 'sam@example.com'
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            $result = @(Get-MsecEntraRoleHolder)
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly `
                -ParameterFilter { $Uri -match 'roleDefinitions/11111111' }
            $result
        }

        $rows.Count | Should -Be 2
        ($rows | Select-Object -Unique RoleName).RoleName | Should -Be 'Some Hidden Built-In'
    }

    It 'flags and counts principals Graph returns as id-only shells instead of emitting blank rows' {
        $result = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = '62e90394-69f5-4237-9190-012177145e10'
                        templateId = '62e90394-69f5-4237-9190-012177145e10'
                        displayName = 'Global Administrator'
                    }
                ) }
            }
            # Exactly what Graph returns when the app may read role assignments but not
            # the directory objects behind them: the full property schema, all null.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'u1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u1'; displayName = $null
                            userPrincipalName = $null; accountEnabled = $null
                        }
                    }
                    [pscustomobject]@{
                        id = 'ra2'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'sp1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.servicePrincipal'
                            id = 'sp1'; displayName = $null
                        }
                    }
                    # A readable one, to prove the flag is per-row and not global.
                    [pscustomobject]@{
                        id = 'ra3'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'u2'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u2'; displayName = 'Anton'
                            userPrincipalName = 'anton@example.com'; accountEnabled = $true
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            $warnings = @()
            $rows = Get-MsecEntraRoleHolder -WarningVariable warnings -WarningAction SilentlyContinue
            [pscustomobject]@{ Rows = @($rows); Warnings = @($warnings) }
        }

        # Nothing is dropped - the assignments are real even when the identities are opaque.
        $result.Rows.Count | Should -Be 3

        # An unnameable administrator reads as an unknown, not as a blank cell.
        ($result.Rows | Where-Object PrincipalId -eq 'u1').IsResolved  | Should -BeFalse
        ($result.Rows | Where-Object PrincipalId -eq 'sp1').IsResolved | Should -BeFalse
        ($result.Rows | Where-Object PrincipalId -eq 'u2').IsResolved  | Should -BeTrue
        # IsActiveNow must not claim an unknown identity can use the role.
        ($result.Rows | Where-Object PrincipalId -eq 'u1').IsActiveNow | Should -BeNullOrEmpty
        ($result.Rows | Where-Object PrincipalId -eq 'u2').IsActiveNow | Should -BeTrue

        # And the caller is told, with a count and the permission to grant.
        ($result.Warnings -join ' ') | Should -Match '2 privileged principal'
        ($result.Warnings -join ' ') | Should -Match 'User.Read.All'
    }

    It 'expands a PIM-governed group with no active members into its ELIGIBLE members' {
        # The real-tenant case that motivated this: a group named for the role it
        # carries, with an empty membership and a queue of people eligible to activate
        # into it. /transitiveMembers reports nothing, so without the PIM-for-Groups
        # endpoint the tenant looks like it has nobody in the role.
        $rows = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
                        templateId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
                        displayName = 'Global Reader'
                    }
                ) }
            }
            # The group is ACTIVELY assigned the role...
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
                        principalId = 'g-pim'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.group'
                            id = 'g-pim'; displayName = 'pim-group-global-reader'
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            # ...and has no actual members at all.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'transitiveMembers' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'privilegedAccess/group/eligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'g-pim_member_1'; accessId = 'member'; groupId = 'g-pim'
                        principalId = 'u1'; memberType = 'Direct'; endDateTime = $null
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u1'; displayName = 'Pim-Eligible Pia'
                            userPrincipalName = 'pia@example.com'
                            accountEnabled = $true; userType = 'Member'
                        }
                    }
                    # An OWNER can add themselves as a member and only then hold the
                    # role, so counting them here would overstate the population.
                    [pscustomobject]@{
                        id = 'g-pim_owner_2'; accessId = 'owner'; groupId = 'g-pim'
                        principalId = 'u2'; memberType = 'Direct'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u2'; userPrincipalName = 'owner@example.com'
                        }
                    }
                ) }
            }

            Get-MsecEntraRoleHolder
        }

        # The eligible member replaces the group, exactly as an active member would.
        $rows.Count              | Should -Be 1
        $rows[0].EffectiveName   | Should -Be 'pia@example.com'
        $rows[0].EffectiveType   | Should -Be 'user'
        $rows[0].RoleName        | Should -Be 'Global Reader'
        $rows[0].PrincipalName   | Should -Be 'pim-group-global-reader'
        $rows[0].PrincipalType   | Should -Be 'group'
        $rows[0].MembershipType  | Should -Be 'Eligible'
        $rows[0].IsResolved      | Should -BeTrue

        # Each link keeps its own truth: the ASSIGNMENT to the group is active, the
        # MEMBERSHIP is not. Folding them into one column would have to lie about one.
        $rows[0].AssignmentType  | Should -Be 'Active'
        # And the conjunction is the answer to "can they use it right now" - no.
        $rows[0].IsActiveNow     | Should -BeFalse

        # The group has a holder now, so it is not its own row.
        $rows | Where-Object EffectiveType -eq 'group' | Should -BeNullOrEmpty
        # And the owner is not a role holder.
        $rows | Where-Object EffectiveId -eq 'u2' | Should -BeNullOrEmpty
    }

    It 'keeps a role assigned to an EMPTY group as an unresolved row rather than dropping the assignment' {
        $result = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = '62e90394-69f5-4237-9190-012177145e10'
                        templateId = '62e90394-69f5-4237-9190-012177145e10'
                        displayName = 'Global Administrator'
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'g1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.group'
                            id = 'g1'; displayName = 'Empty Tier0 group'
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            # A group holding only an empty nested group: the per-type casts return no
            # user and no service principal, and PIM knows no eligible members either,
            # so the assignment has nobody at all to stand for.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'transitiveMembers' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'eligibilityScheduleInstances' -and $Uri -match 'groupId' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            $warnings = @()
            $rows = Get-MsecEntraRoleHolder -WarningVariable warnings -WarningAction SilentlyContinue
            [pscustomobject]@{ Rows = @($rows); Warnings = @($warnings) }
        }

        # Global Administrator is assigned to a group someone could populate tomorrow.
        # That must not vanish from a privileged-access report. The assignee is known;
        # the holder is not, which is exactly what the row says.
        $result.Rows.Count | Should -Be 1
        $row = $result.Rows[0]
        $row.PrincipalId   | Should -Be 'g1'
        $row.PrincipalType | Should -Be 'group'
        $row.PrincipalName | Should -Be 'Empty Tier0 group'
        $row.EffectiveId   | Should -BeNullOrEmpty
        $row.EffectiveName | Should -BeNullOrEmpty
        $row.EffectiveType | Should -BeNullOrEmpty
        $row.IsResolved    | Should -BeFalse
        $row.IsActiveNow   | Should -BeNullOrEmpty
        $row.RoleName      | Should -Be 'Global Administrator'

        # A blank EffectiveName in a table reads as a broken report, so the run must
        # account for the blanks rather than leave them to be interpreted - and must
        # name the permission that is the usual cause.
        $joined = $result.Warnings -join ' '
        $joined | Should -Match 'UNKNOWN HOLDER'
        $joined | Should -Match 'PrivilegedEligibilitySchedule.Read.AzureADGroup'
    }

    It 'leaves groups unexpanded with -NoGroupExpansion' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = '62e90394-69f5-4237-9190-012177145e10'
                        templateId = '62e90394-69f5-4237-9190-012177145e10'
                        displayName = 'Global Administrator'
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'g1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.group'
                            id = 'g1'; displayName = 'Tier0 Admins'
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'transitiveMembers' } -MockWith {
                throw 'group expansion must not happen with -NoGroupExpansion'
            }

            Get-MsecEntraRoleHolder -NoGroupExpansion
        }

        # The assignment-level view: assignee named, holders deliberately not looked up.
        $rows.Count            | Should -Be 1
        $rows[0].PrincipalType | Should -Be 'group'
        $rows[0].PrincipalName | Should -Be 'Tier0 Admins'
        $rows[0].EffectiveName | Should -BeNullOrEmpty
        $rows[0].IsResolved    | Should -BeFalse
    }

    It 'warns and keeps the group row when the group cannot be expanded' {
        $result = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = '62e90394-69f5-4237-9190-012177145e10'
                        templateId = '62e90394-69f5-4237-9190-012177145e10'
                        displayName = 'Global Administrator'
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'g1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.group'
                            id = 'g1'; displayName = 'Tier0 Admins'
                        }
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'transitiveMembers' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'eligibilityScheduleInstances' -and $Uri -match 'groupId' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            $warnings = @()
            $rows = Get-MsecEntraRoleHolder -WarningVariable warnings -WarningAction SilentlyContinue
            [pscustomobject]@{ Rows = @($rows); Warnings = @($warnings) }
        }

        # An unreadable group is an unknown, not a zero - the assignment stays visible.
        $result.Rows.Count             | Should -Be 1
        $result.Rows[0].PrincipalType  | Should -Be 'group'
        $result.Rows[0].IsResolved     | Should -BeFalse
        ($result.Warnings -join ' ')   | Should -Match 'Group.Read.All'
    }

    It 'falls back to per-role-definition filtering when Graph rejects the unfiltered list' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = '62e90394-69f5-4237-9190-012177145e10'
                        templateId = '62e90394-69f5-4237-9190-012177145e10'
                        displayName = 'Global Administrator'
                    }
                ) }
            }
            # The filtered retry (URI carries an escaped $filter) succeeds...
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' -and $Uri -match 'roleDefinitionId' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'ra1'; roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
                        principalId = 'u1'; directoryScopeId = '/'
                        principal = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.user'
                            id = 'u1'; userPrincipalName = 'anton@example.com'
                        }
                    }
                ) }
            }
            # ...while the unfiltered list is rejected the way Graph rejects it.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleAssignments' -and $Uri -notmatch 'roleDefinitionId' } -MockWith {
                throw 'A $filter query parameter is required for this request.'
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleEligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            Get-MsecEntraRoleHolder -AssignmentType Active
        }

        $rows.Count                 | Should -Be 1
        $rows[0].UserPrincipalName  | Should -Be 'anton@example.com'
    }

    It 'rewrites a 403 on roleDefinitions to name the missing permission' {
        InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'roleDefinitions' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }

            { Get-MsecEntraRoleHolder } |
                Should -Throw -ExpectedMessage '*RoleManagement.Read.Directory*'
        }
    }

    Context '-Role' {
        # The tenant used throughout this context. Note the Global Administrator
        # definition is reported by its LEGACY display name, which is what Graph is
        # observed to return - so every "by name" case here is also a test that the
        # canonical map is doing its job.
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

        BeforeAll {
            $script:RoleMocks = {
                Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                    [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
                }
                Mock Get-AzContext -MockWith { [pscustomobject]@{ Tenant = @{ Id = 'tenant-role-tests' } } }

                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleDefinitions' } -MockWith {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ id = 'def-ga'; displayName = 'Company Administrator'
                                           templateId = '62e90394-69f5-4237-9190-012177145e10'; isBuiltIn = $true }
                        [pscustomobject]@{ id = 'def-ua'; displayName = 'User Administrator'
                                           templateId = 'fe930be7-5e62-47db-91af-98c3a49a38b1'; isBuiltIn = $true }
                        [pscustomobject]@{ id = 'def-reader'; displayName = 'Global Reader'
                                           templateId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'; isBuiltIn = $true }
                        # Custom role: no templateId, so only its id or display name can name it.
                        [pscustomobject]@{ id = 'def-custom'; displayName = 'Contoso Vault Reader'
                                           templateId = $null; isBuiltIn = $false }
                    ) }
                }

                # Honours the $filter the command sends, so a test can tell server-side
                # filtering from a client-side Where-Object.
                #
                # Matched against the FULLY DECODED uri. Invoke-RestMethod's -Uri is typed
                # [System.Uri], so PowerShell coerces the string the command built and
                # .NET's canonicalisation unescapes %20 back to a literal space while
                # leaving %27 alone - the mock would never see the bytes that were sent.
                # Decoding both sides sidesteps the whole question.
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleAssignments' } -MockWith {
                    $decoded = [uri]::UnescapeDataString([string]$Uri)
                    $script:RequestedUris.Add($decoded)

                    $mk = {
                        param($AssignmentId, $DefinitionId, $PrincipalId)
                        $p = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'
                                                id = $PrincipalId; userPrincipalName = "$PrincipalId@x.com" }
                        [pscustomobject]@{ id = $AssignmentId; roleDefinitionId = $DefinitionId
                                           principalId = $PrincipalId; directoryScopeId = '/'; principal = $p }
                    }
                    $all = @(
                        & $mk 'as1' 'def-ga'     'ga1'
                        & $mk 'as2' 'def-ga'     'ga2'
                        & $mk 'as3' 'def-ua'     'ua1'
                        & $mk 'as4' 'def-reader' 'rd1'
                        & $mk 'as5' 'def-custom' 'cu1'
                    )

                    if ($decoded -match "roleDefinitionId eq '(?<id>[^']+)'") {
                        $wanted = $Matches['id']
                        return [pscustomobject]@{ value = @($all | Where-Object roleDefinitionId -eq $wanted) }
                    }
                    [pscustomobject]@{ value = $all }
                }

                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleEligibilityScheduleInstances' } -MockWith {
                    [pscustomobject]@{ value = @() }
                }
            }

            # Passed as TEXT and rebuilt with [scriptblock]::Create inside InModuleScope.
            # A scriptblock stays bound to the session state it was written in, so calling
            # this one directly would fail to resolve Mock's module-private targets - the
            # mocks would silently not apply.
            $script:RoleMockText = $script:RoleMocks.ToString()
        }

        It 'resolves a canonical name against a directory that uses the legacy name' {
            # THE case this parameter exists for. The tenant calls the role 'Company
            # Administrator'; nobody types that. Matching display names only would return
            # nothing here and read as "no Global Admins".
            $rows = InModuleScope Msec -Parameters @{ MockText = $script:RoleMockText } {
                param($MockText)
                $script:RequestedUris = [System.Collections.Generic.List[string]]::new()
                & ([scriptblock]::Create($MockText))
                Get-MsecEntraRoleHolder -Role 'Global Administrator' -WarningAction SilentlyContinue
            }

            @($rows).Count | Should -Be 2
            @($rows.EffectiveId | Sort-Object) | Should -Be @('ga1', 'ga2')
            ($rows | Select-Object -Unique RoleName).RoleName | Should -Be 'Company Administrator'
        }

        It 'is case-insensitive and tolerates surrounding whitespace' {
            $rows = InModuleScope Msec -Parameters @{ MockText = $script:RoleMockText } {
                param($MockText)
                $script:RequestedUris = [System.Collections.Generic.List[string]]::new()
                & ([scriptblock]::Create($MockText))
                Get-MsecEntraRoleHolder -Role '  global ADMINISTRATOR ' -WarningAction SilentlyContinue
            }
            @($rows).Count | Should -Be 2
        }

        It 'resolves a roleTemplateId' {
            $rows = InModuleScope Msec -Parameters @{ MockText = $script:RoleMockText } {
                param($MockText)
                $script:RequestedUris = [System.Collections.Generic.List[string]]::new()
                & ([scriptblock]::Create($MockText))
                Get-MsecEntraRoleHolder -Role '62e90394-69f5-4237-9190-012177145e10' -WarningAction SilentlyContinue
            }
            @($rows).Count | Should -Be 2
        }

        It 'resolves the display name this tenant actually reports' {
            $rows = InModuleScope Msec -Parameters @{ MockText = $script:RoleMockText } {
                param($MockText)
                $script:RequestedUris = [System.Collections.Generic.List[string]]::new()
                & ([scriptblock]::Create($MockText))
                Get-MsecEntraRoleHolder -Role 'Company Administrator' -WarningAction SilentlyContinue
            }
            @($rows).Count | Should -Be 2
        }

        It 'resolves a custom role by its definition id, which has no template id' {
            $rows = InModuleScope Msec -Parameters @{ MockText = $script:RoleMockText } {
                param($MockText)
                $script:RequestedUris = [System.Collections.Generic.List[string]]::new()
                & ([scriptblock]::Create($MockText))
                Get-MsecEntraRoleHolder -Role 'def-custom' -WarningAction SilentlyContinue
            }

            @($rows).Count            | Should -Be 1
            $rows.EffectiveId         | Should -Be 'cu1'
            $rows.RoleName            | Should -Be 'Contoso Vault Reader'
            # Custom roles are never flagged privileged - the flag is a built-in lookup.
            $rows.IsHighlyPrivileged  | Should -BeFalse
        }

        It 'accepts several roles, mixing names and template ids' {
            $rows = InModuleScope Msec -Parameters @{ MockText = $script:RoleMockText } {
                param($MockText)
                $script:RequestedUris = [System.Collections.Generic.List[string]]::new()
                & ([scriptblock]::Create($MockText))
                Get-MsecEntraRoleHolder -WarningAction SilentlyContinue `
                    -Role 'Global Administrator', 'fe930be7-5e62-47db-91af-98c3a49a38b1', 'Contoso Vault Reader'
            }

            @($rows).Count | Should -Be 4
            @($rows.RoleName | Sort-Object -Unique) | Should -Be @('Company Administrator', 'Contoso Vault Reader', 'User Administrator')
            # Global Reader was not asked for and must not appear.
            $rows.EffectiveId | Should -Not -Contain 'rd1'
        }

        It 'filters server-side: one request per named role, and no full-tenant sweep' {
            # Wrapped in an object because InModuleScope unrolls a single-element
            # collection to the string inside it, and $uris[0] would then index a
            # character rather than a uri.
            $out = InModuleScope Msec -Parameters @{ MockText = $script:RoleMockText } {
                param($MockText)
                $script:RequestedUris = [System.Collections.Generic.List[string]]::new()
                & ([scriptblock]::Create($MockText))
                Get-MsecEntraRoleHolder -Role 'Global Administrator' -AssignmentType Active -WarningAction SilentlyContinue | Out-Null
                [pscustomobject]@{ Uris = @($script:RequestedUris) }
            }

            @($out.Uris).Count | Should -Be 1 -Because 'one named role is one filtered request'
            $out.Uris[0]       | Should -Match "roleDefinitionId eq 'def-ga'"
            # The point of the parameter: never pull every assignment in the tenant and
            # discard the rest.
            @($out.Uris | Where-Object { $_ -notmatch '\$filter=' }).Count | Should -Be 0
        }

        It 'sends one filtered request per role when several are named' {
            $out = InModuleScope Msec -Parameters @{ MockText = $script:RoleMockText } {
                param($MockText)
                $script:RequestedUris = [System.Collections.Generic.List[string]]::new()
                & ([scriptblock]::Create($MockText))
                Get-MsecEntraRoleHolder -AssignmentType Active -WarningAction SilentlyContinue `
                    -Role 'Global Administrator', 'User Administrator' | Out-Null
                [pscustomobject]@{ Uris = @($script:RequestedUris) }
            }

            @($out.Uris).Count | Should -Be 2
            ($out.Uris -join ' ') | Should -Match "roleDefinitionId eq 'def-ga'"
            ($out.Uris -join ' ') | Should -Match "roleDefinitionId eq 'def-ua'"
            # Global Reader was never asked for, so it was never fetched.
            ($out.Uris -join ' ') | Should -Not -Match 'def-reader'
        }

        It 'reads every assignment in one request when -Role is omitted' {
            # The unfiltered path must survive: it is one round trip for the whole tenant,
            # which is the right shape when you want the whole tenant.
            $out = InModuleScope Msec -Parameters @{ MockText = $script:RoleMockText } {
                param($MockText)
                $script:RequestedUris = [System.Collections.Generic.List[string]]::new()
                & ([scriptblock]::Create($MockText))
                Get-MsecEntraRoleHolder -AssignmentType Active -WarningAction SilentlyContinue | Out-Null
                [pscustomobject]@{ Uris = @($script:RequestedUris) }
            }

            @($out.Uris).Count | Should -Be 1
            $out.Uris[0]       | Should -Not -Match '\$filter='
        }

        It 'throws on an unrecognised role and names the tenant''s roles' {
            # A typo that returned zero rows would read as a clean bill of health.
            InModuleScope Msec -Parameters @{ MockText = $script:RoleMockText } {
                param($MockText)
                $script:RequestedUris = [System.Collections.Generic.List[string]]::new()
                & ([scriptblock]::Create($MockText))
                { Get-MsecEntraRoleHolder -Role 'Globl Administrator' } |
                    Should -Throw -ExpectedMessage '*Unrecognised role*'
            }
        }

        It 'lists the available roles in the error, so the fix is in the message' {
            $message = InModuleScope Msec -Parameters @{ MockText = $script:RoleMockText } {
                param($MockText)
                $script:RequestedUris = [System.Collections.Generic.List[string]]::new()
                & ([scriptblock]::Create($MockText))
                try { Get-MsecEntraRoleHolder -Role 'Nonsense Administrator'; '' }
                catch { $_.Exception.Message }
            }

            $message | Should -Match 'Nonsense Administrator'
            $message | Should -Match 'Company Administrator'
            $message | Should -Match 'Contoso Vault Reader'
        }

        It 'fails the whole call when only one of several roles is unrecognised' {
            # Returning the roles that DID resolve would hand back a partial answer that
            # looks complete - worse than failing, for an access review.
            InModuleScope Msec -Parameters @{ MockText = $script:RoleMockText } {
                param($MockText)
                $script:RequestedUris = [System.Collections.Generic.List[string]]::new()
                & ([scriptblock]::Create($MockText))
                { Get-MsecEntraRoleHolder -Role 'Global Administrator', 'Not A Role' } |
                    Should -Throw -ExpectedMessage '*Not A Role*'
            }
        }

        It 'returns nothing, without error, for a known role absent from this tenant' {
            # Distinct from a typo: msec knows this name, the tenant has no definition for
            # it, so nobody holds it. An empty answer is the correct answer.
            $rows = InModuleScope Msec {
                Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                    [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
                }
                Mock Get-AzContext -MockWith { [pscustomobject]@{ Tenant = @{ Id = 'tenant-role-tests' } } }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleDefinitions' } -MockWith {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ id = 'def-ga'; displayName = 'Company Administrator'
                                           templateId = '62e90394-69f5-4237-9190-012177145e10'; isBuiltIn = $true }
                    ) }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/roleAssignments' } -MockWith {
                    throw 'no assignment call should be made for a role with no definition'
                }

                @(Get-MsecEntraRoleHolder -Role 'Partner Tier2 Support' -WarningAction SilentlyContinue)
            }

            @($rows).Count | Should -Be 0
        }

        It 'refuses -Role together with -HighlyPrivilegedOnly' {
            # Logically empty combinations are another way to get a zero that reads as an
            # answer, so the parameter sets make it unrepresentable.
            { Get-MsecEntraRoleHolder -Role 'Global Administrator' -HighlyPrivilegedOnly } |
                Should -Throw
        }

        It 'caches the tenant''s role definitions for the completer' {
            $cached = InModuleScope Msec -Parameters @{ MockText = $script:RoleMockText } {
                param($MockText)
                $script:RequestedUris = [System.Collections.Generic.List[string]]::new()
                & ([scriptblock]::Create($MockText))
                Get-MsecEntraRoleHolder -AssignmentType Active -WarningAction SilentlyContinue | Out-Null
                @(Read-MsecCache -Name 'directory-roles')
            }

            @($cached).Count | Should -Be 4
            # Both names are kept: the completer needs the canonical one to offer and the
            # directory one to show alongside it.
            ($cached | Where-Object TemplateId -eq '62e90394-69f5-4237-9190-012177145e10').DisplayName |
                Should -Be 'Company Administrator'
            ($cached | Where-Object Id -eq 'def-custom').IsBuiltIn | Should -BeFalse
        }
    }
}
