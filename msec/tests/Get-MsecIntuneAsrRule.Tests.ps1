#Requires -Module Pester
#
# Tests for Get-MsecIntuneAsrRule. The function reads the ASR setting definitions for the rule
# catalogue, then every endpoint-security ASR policy, and flattens them to one row per rule per
# policy - plus a row per rule that no policy configures.
#
# Each test covers a defect that was found against a live tenant while writing it:
#   - Device Control policies share the ASR templateFamily, and their settings sliced at the ASR
#     prefix length produced rows named 'uleid}_ruledata'.
#   - 'exclusionGroupAssignmentTarget' also matches the wildcard '*groupAssignmentTarget', and
#     PowerShell's switch runs every matching branch - so carve-out groups landed in the
#     INCLUDED list and 'everyone except developers' read as 'everyone'.
#   - Two modes for one rule is usually a deliberate ring design, not a conflict.
#   - A rule no policy configures must still be emitted, with Mode $null rather than 'off'.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll { Remove-Module Msec -Force -ErrorAction SilentlyContinue }

Describe 'Get-MsecIntuneAsrRule' {
    BeforeEach {
        InModuleScope Msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId = 'tenant'; ClientId = 'client'; KeyVaultName = 'kv-test'
                KeyName = 'msec-app'; ThumbprintBytes = $Thumb; Tokens = @{}
            }

            $base = 'device_vendor_msft_policy_config_defender_attacksurfacereductionrules'

            function script:New-AsrChild([string]$Slug, [string]$Mode) {
                [pscustomobject]@{
                    settingDefinitionId = "device_vendor_msft_policy_config_defender_attacksurfacereductionrules_$Slug"
                    choiceSettingValue  = [pscustomobject]@{ value = "device_vendor_msft_policy_config_defender_attacksurfacereductionrules_${Slug}_$Mode" }
                }
            }
            function script:New-AsrPolicy([string]$Id, [string]$Name, [object[]]$Children, [object[]]$Assignments) {
                [pscustomobject]@{
                    id = $Id; name = $Name; lastModifiedDateTime = '2026-05-12T11:07:46Z'
                    templateReference = [pscustomobject]@{ templateFamily = 'endpointSecurityAttackSurfaceReduction' }
                    assignments = $Assignments
                    settings = @([pscustomobject]@{ settingInstance = [pscustomobject]@{
                        groupSettingCollectionValue = @([pscustomobject]@{ children = $Children }) } })
                }
            }
            function script:Incl([string]$Name) { [pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $Name } } }
            function script:Excl([string]$Name) { [pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = $Name } } }
            function script:AllUsers { [pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget' } } }

            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            # Group name lookup is identity here: the fixtures use the name as the id.
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '^/v1\.0/groups/' } -MockWith {
                [pscustomobject]@{ displayName = ($Path -replace '^/v1\.0/groups/', '' -replace '\?.*$', '') }
            }
            # Catalogue: three real rules plus the per-rule-exclusion sibling that must NOT
            # become a rule of its own.
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationSettings' } -MockWith {
                @(
                    [pscustomobject]@{ id = "${base}_blockrebootingmachineinsafemode";   displayName = 'Block rebooting machine in Safe Mode' }
                    [pscustomobject]@{ id = "${base}_blockuseofcopiedorimpersonatedsystemtools"; displayName = 'Block use of copied or impersonated system tools' }
                    [pscustomobject]@{ id = "${base}_blockexecutablefilesrunningunlesstheymeetprevalenceagetrustedlistcriterion"; displayName = 'Block executable files from running unless they meet a prevalence, age, or trusted list criterion' }
                    [pscustomobject]@{ id = "${base}_blockrebootingmachineinsafemode_perruleexclusions"; displayName = 'ASR Only Per Rule Exclusions' }
                )
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'deviceManagement/intents' } -MockWith { @() }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'deviceConfigurations' } -MockWith { @() }
        }
    }

    It 'reports a rule no policy configures, with Mode null rather than off' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies\?' } -MockWith {
                @(New-AsrPolicy 'p1' 'ASR Developers' @(New-AsrChild 'blockuseofcopiedorimpersonatedsystemtools' 'block') @(Incl 'Devs'))
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies/p1/settings' } -MockWith {
                @([pscustomobject]@{ settingInstance = [pscustomobject]@{ groupSettingCollectionValue = @([pscustomobject]@{
                    children = @(New-AsrChild 'blockuseofcopiedorimpersonatedsystemtools' 'block') }) } })
            }
            , @(Get-MsecIntuneAsrRule)
        }

        $safeMode = $rows | Where-Object RuleSlug -eq 'blockrebootingmachineinsafemode'
        $safeMode.Configured | Should -BeFalse
        # The distinction that matters: unconfigured is NOT 'off'. An explicit off wins a
        # policy conflict; an absent rule does not.
        $safeMode.Mode | Should -BeNullOrEmpty
        $safeMode.RuleId | Should -Be '33ddedf1-c6e0-47cb-833e-de6133960387'
        $safeMode.RuleName | Should -Be 'Block rebooting machine in Safe Mode'

        # The '_perruleexclusions' definition is an exclusion list, not a rule.
        @($rows | Where-Object RuleSlug -match 'perruleexclusions') | Should -BeNullOrEmpty
    }

    It 'keeps exclusion groups out of the included list, so a carve-out is not inverted' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies\?' } -MockWith {
                @(New-AsrPolicy 'p2' 'ASR everyone except Developers' @() @((AllUsers), (Excl 'Devs'), (Incl 'Pilot')))
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies/p2/settings' } -MockWith {
                @([pscustomobject]@{ settingInstance = [pscustomobject]@{ groupSettingCollectionValue = @([pscustomobject]@{
                    children = @(New-AsrChild 'blockuseofcopiedorimpersonatedsystemtools' 'block') }) } })
            }
            Get-MsecIntuneAsrRule -Rule 'copied'
        }

        $row.AssignedAllUsers | Should -BeTrue
        $row.ExcludedGroup | Should -Be @('Devs')
        # 'exclusionGroupAssignmentTarget' also matches '*groupAssignmentTarget', and switch runs
        # every matching branch - without a break, 'Devs' appears in both lists and the policy
        # reads as applying to everyone.
        $row.AssignedGroup | Should -Be @('Pilot')
        $row.AssignedGroup | Should -Not -Contain 'Devs'
    }

    It 'calls two modes a deliberate ring when the policies exclude each other, not a conflict' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies\?' } -MockWith {
                @(
                    New-AsrPolicy 'd1' 'ASR Developers'                @() @(Incl 'Devs')
                    New-AsrPolicy 'd2' 'ASR everyone except Developers' @() @((AllUsers), (Excl 'Devs'))
                )
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies/d1/settings' } -MockWith {
                @([pscustomobject]@{ settingInstance = [pscustomobject]@{ groupSettingCollectionValue = @([pscustomobject]@{
                    children = @(New-AsrChild 'blockexecutablefilesrunningunlesstheymeetprevalenceagetrustedlistcriterion' 'audit') }) } })
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies/d2/settings' } -MockWith {
                @([pscustomobject]@{ settingInstance = [pscustomobject]@{ groupSettingCollectionValue = @([pscustomobject]@{
                    children = @(New-AsrChild 'blockexecutablefilesrunningunlesstheymeetprevalenceagetrustedlistcriterion' 'block') }) } })
            }
            , @(Get-MsecIntuneAsrRule -Rule 'prevalence')
        }

        @($rows).Count | Should -Be 2
        @($rows | ForEach-Object Mode | Sort-Object) | Should -Be @('audit', 'block')
        $rows | ForEach-Object { $_.ModesDiffer | Should -BeTrue }
        # The carve-out is the whole design. Calling it a conflict sends someone to break it.
        $rows | ForEach-Object { $_.Conflicting | Should -BeFalse }
        $rows | ForEach-Object { $_.PolicyCount | Should -Be 2 }
    }

    It 'calls two modes a conflict when no policy carves the other out' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies\?' } -MockWith {
                @(
                    New-AsrPolicy 'c1' 'Baseline' @() @(Incl 'Everyone')
                    New-AsrPolicy 'c2' 'Mathias test' @() @(Incl 'Testers')
                )
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies/c1/settings' } -MockWith {
                @([pscustomobject]@{ settingInstance = [pscustomobject]@{ groupSettingCollectionValue = @([pscustomobject]@{
                    children = @(New-AsrChild 'blockuseofcopiedorimpersonatedsystemtools' 'audit') }) } })
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies/c2/settings' } -MockWith {
                @([pscustomobject]@{ settingInstance = [pscustomobject]@{ groupSettingCollectionValue = @([pscustomobject]@{
                    children = @(New-AsrChild 'blockuseofcopiedorimpersonatedsystemtools' 'block') }) } })
            }
            $w = @()
            $r = @(Get-MsecIntuneAsrRule -Rule 'copied' -WarningVariable w -WarningAction SilentlyContinue)
            [pscustomobject]@{ Rows = $r; Warnings = "$($w -join ' ')" }
        }

        $rows.Rows | ForEach-Object { $_.Conflicting | Should -BeTrue }
        $rows.Warnings | Should -Match 'do NOT carve each other out'
    }

    It 'ignores Device Control settings that share the ASR template family' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies\?' } -MockWith {
                @(New-AsrPolicy 'u1' 'USB Device Control' @() @(Incl 'All'))
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies/u1/settings' } -MockWith {
                @([pscustomobject]@{ settingInstance = [pscustomobject]@{ groupSettingCollectionValue = @([pscustomobject]@{
                    children = @(
                        # A real Device Control setting id. Sliced at the ASR prefix length this
                        # produced a rule called 'uleid}_ruledata'.
                        [pscustomobject]@{
                            settingDefinitionId = 'device_vendor_msft_defender_configuration_devicecontrol_policyrules_{ruleid}_ruledata'
                            choiceSettingValue  = [pscustomobject]@{ value = 'something' }
                        }
                    ) }) } })
            }
            , @(Get-MsecIntuneAsrRule)
        }

        @($rows | Where-Object Configured) | Should -BeNullOrEmpty
        @($rows | Where-Object { $_.RuleSlug -match 'ruledata|ruleid' }) | Should -BeNullOrEmpty
        # The catalogue rules are all still reported as unconfigured.
        @($rows).Count | Should -Be 3
    }

    It 'finds a per-rule exclusion NESTED under the rule, which is where Intune actually puts it' {
        # THIS FIXTURE IS THE REAL SHAPE. The first version of this test put the exclusion
        # beside the rule as a sibling - which is what the setting id
        # '<rule>_perruleexclusions' suggests - and the command was written to match. Both were
        # wrong: Intune hangs the list off the rule's own choiceSettingValue, one level deeper.
        # The test passed, the command reported no exclusions, and a live policy carrying a Git
        # exclusion read as having none. Fixture corrected from production data.
        $row = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies\?' } -MockWith {
                @(New-AsrPolicy 'e1' 'ASR with exclusions' @() @(Incl 'All'))
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies/e1/settings' } -MockWith {
                $slug = 'blockuseofcopiedorimpersonatedsystemtools'
                $base = 'device_vendor_msft_policy_config_defender_attacksurfacereductionrules'
                @([pscustomobject]@{ settingInstance = [pscustomobject]@{ groupSettingCollectionValue = @([pscustomobject]@{
                    children = @(
                        [pscustomobject]@{
                            settingDefinitionId = "${base}_$slug"
                            choiceSettingValue  = [pscustomobject]@{
                                value    = "${base}_${slug}_block"
                                children = @(
                                    [pscustomobject]@{
                                        settingDefinitionId          = "${base}_${slug}_perruleexclusions"
                                        simpleSettingCollectionValue = @(
                                            [pscustomobject]@{ value = 'C:\Users\*\AppData\Local\Programs\Git\*' }
                                            [pscustomobject]@{ value = 'C:\Tools\build.exe' }
                                        )
                                    }
                                )
                            }
                        }
                    ) }) } })
            }
            Get-MsecIntuneAsrRule -Rule 'copied'
        }

        $row.Mode | Should -Be 'block'
        $row.PerRuleExclusion | Should -Contain 'C:\Users\*\AppData\Local\Programs\Git\*'
        $row.PerRuleExclusion | Should -Contain 'C:\Tools\build.exe'
        @($row.PerRuleExclusion).Count | Should -Be 2
    }

    It 'also finds an exclusion placed as a sibling, so a differing shape is not missed' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies\?' } -MockWith {
                @(New-AsrPolicy 'e2' 'Sibling shape' @() @(Incl 'All'))
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies/e2/settings' } -MockWith {
                @([pscustomobject]@{ settingInstance = [pscustomobject]@{ groupSettingCollectionValue = @([pscustomobject]@{
                    children = @(
                        New-AsrChild 'blockuseofcopiedorimpersonatedsystemtools' 'block'
                        [pscustomobject]@{
                            settingDefinitionId          = 'device_vendor_msft_policy_config_defender_attacksurfacereductionrules_blockuseofcopiedorimpersonatedsystemtools_perruleexclusions'
                            simpleSettingCollectionValue = @([pscustomobject]@{ value = 'C:\Legacy\shape.exe' })
                        }
                    ) }) } })
            }
            Get-MsecIntuneAsrRule -Rule 'copied'
        }

        $row.PerRuleExclusion | Should -Contain 'C:\Legacy\shape.exe'
    }

    It 'does not attribute one rule exclusions belonging to another' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies\?' } -MockWith {
                @(New-AsrPolicy 'e3' 'Two rules one exclusion' @() @(Incl 'All'))
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies/e3/settings' } -MockWith {
                $base = 'device_vendor_msft_policy_config_defender_attacksurfacereductionrules'
                @([pscustomobject]@{ settingInstance = [pscustomobject]@{ groupSettingCollectionValue = @([pscustomobject]@{
                    children = @(
                        # Only the Safe Mode rule carries an exclusion.
                        [pscustomobject]@{
                            settingDefinitionId = "${base}_blockrebootingmachineinsafemode"
                            choiceSettingValue  = [pscustomobject]@{
                                value    = "${base}_blockrebootingmachineinsafemode_block"
                                children = @([pscustomobject]@{
                                    settingDefinitionId          = "${base}_blockrebootingmachineinsafemode_perruleexclusions"
                                    simpleSettingCollectionValue = @([pscustomobject]@{ value = 'C:\Only\SafeMode.exe' })
                                })
                            }
                        }
                        New-AsrChild 'blockuseofcopiedorimpersonatedsystemtools' 'block'
                    ) }) } })
            }
            , @(Get-MsecIntuneAsrRule)
        }

        $safe   = $rows | Where-Object RuleSlug -eq 'blockrebootingmachineinsafemode'
        $copied = $rows | Where-Object RuleSlug -eq 'blockuseofcopiedorimpersonatedsystemtools'
        $safe.PerRuleExclusion | Should -Contain 'C:\Only\SafeMode.exe'
        # A subtree walk that started too high would hand this rule its neighbour's exclusion,
        # which reads as a hole that does not exist.
        @($copied.PerRuleExclusion).Count | Should -Be 0
    }

    It 'warns that rules reported unconfigured may be set on surfaces it does not read' {
        $warning = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'configurationPolicies\?' } -MockWith { @() }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'deviceManagement/intents' } -MockWith {
                @([pscustomobject]@{ id = 'i1'; displayName = 'Endpoint security baseline' })
            }
            $w = @()
            Get-MsecIntuneAsrRule -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            "$($w -join ' ')"
        }

        $warning | Should -Match 'Endpoint security baseline'
        $warning | Should -Match 'Group Policy'
    }
}
