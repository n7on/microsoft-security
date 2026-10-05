#Requires -Module Pester
#
# Tests for Get-MsecEntraPimPolicy.
#
# The traps here are all about reading a setting the way the question is asked:
#
#   isExpirationRequired IS INVERTED. PermanentActiveAllowed is NOT isExpirationRequired, and
#   getting it backwards reports a tenant that forbids standing privilege as one that permits
#   it, or worse the other way round.
#
#   AN ABSENT RULE IS NOT A DISABLED ONE. A policy that does not carry an enablement rule has
#   not been measured, so the flag is $null - $false would claim PIM was asked and said no.
#
#   A POLICY ON A ROLE NOBODY IS ELIGIBLE FOR GOVERNS NOTHING, but it is still returned: it may
#   be deliberately pre-configured. HasEligibleHolder is how the two are told apart, and it is
#   null - never false - when eligibility could not be read.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEntraPimPolicy' {

    BeforeEach {
        InModuleScope msec { $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} } }
    }

    It 'reads activation requirements out of enabledRules' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*roleDefinitions*') {
                    @([pscustomobject]@{ id = 'def-1'; displayName = 'Global Administrator'
                                         templateId = '62e90394-69f5-4237-9190-012177145e10' })
                }
                elseif ($Path -like '*roleEligibilityScheduleInstances*') { @([pscustomobject]@{ roleDefinitionId = 'def-1' }) }
                elseif ($Path -like '*roleManagementPolicyAssignments*') {
                    @([pscustomobject]@{ roleDefinitionId = 'def-1'; policy = [pscustomobject]@{ rules = @(
                        [pscustomobject]@{ id = 'Enablement_EndUser_Assignment'
                                           enabledRules = @('MultiFactorAuthentication', 'Justification') }
                    ) } })
                }
                else { @() }
            }
            Get-MsecEntraPimPolicy
        }

        $get = { param($s) ($rows | Where-Object Setting -eq $s).Value }
        (& $get 'ActivationRequiresMfa')           | Should -Be 'True'
        (& $get 'ActivationRequiresJustification') | Should -Be 'True'
        # Ticketing is absent from enabledRules, which is a measured "not demanded".
        (& $get 'ActivationRequiresTicket')        | Should -Be 'False'
        $rows[0].IsHighlyPrivileged | Should -BeTrue
        $rows[0].HasEligibleHolder  | Should -BeTrue
    }

    It 'inverts isExpirationRequired into PermanentActiveAllowed' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*roleDefinitions*') { @([pscustomobject]@{ id = 'def-1'; displayName = 'Role'; templateId = 'tpl-1' }) }
                elseif ($Path -like '*roleEligibilityScheduleInstances*') { @() }
                elseif ($Path -like '*roleManagementPolicyAssignments*') {
                    @([pscustomobject]@{ roleDefinitionId = 'def-1'; policy = [pscustomobject]@{ rules = @(
                        # Expiration NOT required => a permanent assignment IS allowed.
                        [pscustomobject]@{ id = 'Expiration_Admin_Assignment'; isExpirationRequired = $false; maximumDuration = 'P180D' }
                        # Expiration required => permanent eligibility is NOT allowed.
                        [pscustomobject]@{ id = 'Expiration_Admin_Eligibility'; isExpirationRequired = $true; maximumDuration = 'P365D' }
                    ) } })
                }
                else { @() }
            }
            Get-MsecEntraPimPolicy
        }

        $get = { param($s) ($rows | Where-Object Setting -eq $s).Value }
        (& $get 'PermanentActiveAllowed')   | Should -Be 'True'
        (& $get 'MaxActiveDuration')        | Should -Be 'P180D'
        (& $get 'PermanentEligibleAllowed') | Should -Be 'False'
    }

    It 'reports an absent enablement rule as null rather than as not required' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*roleDefinitions*') { @([pscustomobject]@{ id = 'def-1'; displayName = 'Role'; templateId = 'tpl-1' }) }
                elseif ($Path -like '*roleEligibilityScheduleInstances*') { @() }
                elseif ($Path -like '*roleManagementPolicyAssignments*') {
                    @([pscustomobject]@{ roleDefinitionId = 'def-1'; policy = [pscustomobject]@{ rules = @() } })
                }
                else { @() }
            }
            Get-MsecEntraPimPolicy
        }

        ($rows | Where-Object Setting -eq 'ActivationRequiresMfa').Value | Should -BeNullOrEmpty
        ($rows | Where-Object Setting -eq 'PermanentActiveAllowed').Value | Should -BeNullOrEmpty
    }

    It 'still returns a role nobody is eligible for, flagged as such' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*roleDefinitions*') { @([pscustomobject]@{ id = 'def-1'; displayName = 'Unused Role'; templateId = 'tpl-1' }) }
                elseif ($Path -like '*roleEligibilityScheduleInstances*') { @() }
                elseif ($Path -like '*roleManagementPolicyAssignments*') {
                    @([pscustomobject]@{ roleDefinitionId = 'def-1'; policy = [pscustomobject]@{ rules = @(
                        [pscustomobject]@{ id = 'Enablement_EndUser_Assignment'; enabledRules = @() }) } })
                }
                else { @() }
            }
            Get-MsecEntraPimPolicy
        }

        # Dropping it would hide a policy someone pre-configured ahead of an assignment.
        $rows | Should -Not -BeNullOrEmpty
        $rows[0].HasEligibleHolder | Should -BeFalse
    }

    It 'leaves HasEligibleHolder null when eligibility could not be read' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*roleDefinitions*') { @([pscustomobject]@{ id = 'def-1'; displayName = 'Role'; templateId = 'tpl-1' }) }
                elseif ($Path -like '*roleEligibilityScheduleInstances*') { throw 'Insufficient privileges' }
                elseif ($Path -like '*roleManagementPolicyAssignments*') {
                    @([pscustomobject]@{ roleDefinitionId = 'def-1'; policy = [pscustomobject]@{ rules = @() } })
                }
                else { @() }
            }
            Get-MsecEntraPimPolicy -WarningAction SilentlyContinue
        }

        # $false would claim nobody is eligible, which nothing established.
        $rows[0].HasEligibleHolder | Should -BeNullOrEmpty
    }

    It 'filters to the shared privileged role list with -HighlyPrivilegedOnly' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*roleDefinitions*') {
                    @(
                        [pscustomobject]@{ id = 'def-1'; displayName = 'Global Administrator'
                                           templateId = '62e90394-69f5-4237-9190-012177145e10' }
                        [pscustomobject]@{ id = 'def-2'; displayName = 'Message Center Reader'; templateId = 'tpl-mcr' }
                    )
                }
                elseif ($Path -like '*roleEligibilityScheduleInstances*') { @() }
                elseif ($Path -like '*roleManagementPolicyAssignments*') {
                    @(
                        [pscustomobject]@{ roleDefinitionId = 'def-1'; policy = [pscustomobject]@{ rules = @() } }
                        [pscustomobject]@{ roleDefinitionId = 'def-2'; policy = [pscustomobject]@{ rules = @() } }
                    )
                }
                else { @() }
            }
            Get-MsecEntraPimPolicy -HighlyPrivilegedOnly
        }

        @($rows | Select-Object -ExpandProperty RoleName -Unique) | Should -Be 'Global Administrator'
    }

    It 'accepts -Role by display name or by template id' {
        $byName = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*roleDefinitions*') {
                    @(
                        [pscustomobject]@{ id = 'def-1'; displayName = 'Intune Administrator'; templateId = 'tpl-intune' }
                        [pscustomobject]@{ id = 'def-2'; displayName = 'User Administrator'; templateId = 'tpl-user' }
                    )
                }
                elseif ($Path -like '*roleEligibilityScheduleInstances*') { @() }
                elseif ($Path -like '*roleManagementPolicyAssignments*') {
                    @(
                        [pscustomobject]@{ roleDefinitionId = 'def-1'; policy = [pscustomobject]@{ rules = @() } }
                        [pscustomobject]@{ roleDefinitionId = 'def-2'; policy = [pscustomobject]@{ rules = @() } }
                    )
                }
                else { @() }
            }
            @(
                (Get-MsecEntraPimPolicy -Role 'Intune Administrator' | Select-Object -ExpandProperty RoleName -Unique)
                (Get-MsecEntraPimPolicy -Role 'tpl-user'             | Select-Object -ExpandProperty RoleName -Unique)
            )
        }

        $byName[0] | Should -Be 'Intune Administrator'
        $byName[1] | Should -Be 'User Administrator'
    }
}
