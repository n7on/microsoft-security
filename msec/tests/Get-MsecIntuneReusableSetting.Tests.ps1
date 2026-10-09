#Requires -Module Pester
#
# Tests for Get-MsecIntuneReusableSetting.
#
# Each covers something found against a live tenant:
#   - referencingConfigurationPolicyCount and settingInstance are ABSENT from the response
#     unless explicitly $select'd. Not null - absent. Without the select every setting reads
#     as unreferenced and empty, which could get an in-use allow-list deleted.
#   - A missing count must be $null, never 0: unknown and orphaned are different, and only
#     one of them justifies deletion.
#   - Entries are nested at varying depths, so the walker must not assume a fixed shape.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module Msec -Force -ErrorAction SilentlyContinue }

Describe 'Get-MsecIntuneReusableSetting' {
    BeforeEach {
        InModuleScope Msec { Mock Assert-MsecSession -MockWith { } }
    }

    It 'asks for the reference count and contents explicitly, because they are absent otherwise' {
        $path = InModuleScope Msec {
            $script:asked = $null
            Mock Invoke-MsecGraphRequest -MockWith { $script:asked = $Path; @() }
            Get-MsecIntuneReusableSetting | Out-Null
            $script:asked
        }

        $path | Should -Match 'referencingConfigurationPolicyCount'
        $path | Should -Match 'settingInstance'
    }

    It 'projects a Device Control group with its entries and reference count' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                @([pscustomobject]@{
                    id = '97a61128-1736-4808-a766-6bdc27deb519'
                    displayName = 'Authorized USBs '
                    description = ''
                    settingDefinitionId = 'device_vendor_msft_defender_configuration_devicecontrol_policygroups_{groupid}_groupdata'
                    lastModifiedDateTime = '2026-09-11T12:30:04Z'
                    referencingConfigurationPolicyCount = 1
                    settingInstance = [pscustomobject]@{
                        groupSettingCollectionValue = @(
                            [pscustomobject]@{ children = @(
                                [pscustomobject]@{
                                    settingDefinitionId = 'x_groupdata_descriptors_name'
                                    simpleSettingValue = [pscustomobject]@{ value = 'SanDisk - 1903' }
                                }
                                # Deliberately nested one level deeper than its sibling: the
                                # real payload varies in depth and a fixed-depth reader misses rows.
                                [pscustomobject]@{ groupSettingCollectionValue = @(
                                    [pscustomobject]@{ children = @(
                                        [pscustomobject]@{
                                            settingDefinitionId = 'x_groupdata_descriptors_name'
                                            simpleSettingValue = [pscustomobject]@{ value = "Feng's USB STICK" }
                                        }
                                        [pscustomobject]@{
                                            settingDefinitionId = 'x_groupdata_descriptors_serialnumberid'
                                            simpleSettingValue = [pscustomobject]@{ value = '9D0400034040' }
                                        }
                                    ) }
                                ) }
                            ) }
                        )
                    }
                })
            }
            Get-MsecIntuneReusableSetting
        }

        $row.DisplayName | Should -Be 'Authorized USBs'      # trailing space trimmed
        $row.Kind | Should -Be 'DeviceControlGroup'
        $row.ReferencingPolicyCount | Should -Be 1
        $row.IsUnreferenced | Should -BeFalse
        $row.EntryCount | Should -Be 2
        $row.Entries | Should -Contain 'SanDisk - 1903'
        $row.Entries | Should -Contain "Feng's USB STICK"
        $row.EntryIdentifiers | Should -Contain '9D0400034040'
        # The join back to a Device Control policy's `groupid`.
        $row.Id | Should -Be '97a61128-1736-4808-a766-6bdc27deb519'
    }

    It 'reports an unknown reference count as null, never as zero' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                @(
                    [pscustomobject]@{ id='a'; displayName='Known orphan'; settingDefinitionId='x'
                                       referencingConfigurationPolicyCount = 0; settingInstance = $null }
                    # Property absent entirely - what the API returns without the $select.
                    [pscustomobject]@{ id='b'; displayName='Count unknown'; settingDefinitionId='x'
                                       settingInstance = $null }
                )
            }
            , @(Get-MsecIntuneReusableSetting)
        }

        $known = $rows | Where-Object Id -eq 'a'
        $unknown = $rows | Where-Object Id -eq 'b'

        $known.ReferencingPolicyCount | Should -Be 0
        $known.IsUnreferenced | Should -BeTrue

        # Unknown is not orphaned. Reporting it as orphaned invites deleting an in-use allow-list.
        $unknown.ReferencingPolicyCount | Should -BeNullOrEmpty
        $unknown.IsUnreferenced | Should -BeNullOrEmpty
    }

    It 'returns only genuine orphans under -UnreferencedOnly, excluding unknown counts' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                @(
                    [pscustomobject]@{ id='orphan'; displayName='Orphan'; settingDefinitionId='x'
                                       referencingConfigurationPolicyCount = 0; settingInstance = $null }
                    [pscustomobject]@{ id='used';   displayName='In use'; settingDefinitionId='x'
                                       referencingConfigurationPolicyCount = 2; settingInstance = $null }
                    [pscustomobject]@{ id='unknown'; displayName='Unknown'; settingDefinitionId='x'
                                       settingInstance = $null }
                )
            }
            , @(Get-MsecIntuneReusableSetting -UnreferencedOnly)
        }

        @($rows | ForEach-Object Id) | Should -Be @('orphan')
    }

    It 'rewrites a 403 to name the permission' {
        $err = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            try { Get-MsecIntuneReusableSetting; $null } catch { "$($_.Exception.Message)" }
        }
        $err | Should -Match 'DeviceManagementConfiguration\.Read\.All'
    }
}
