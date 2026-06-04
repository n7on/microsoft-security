#Requires -Module Pester
#
# Tests for Export-MsecIntuneConfiguration. Verifies the two source dispatches
# (Settings Catalog gets policy + settings + assignments, Templates gets the full
# configuration + assignments), and the per-row file output when -OutDir is used.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Export-MsecIntuneConfiguration' {
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

    It 'exports a Settings Catalog policy by pulling policy + settings + assignments' {
        $export = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/configurationPolicies/sc-1$' } -MockWith {
                [pscustomobject]@{ id = 'sc-1'; name = 'Win10 Hardening'; platforms = 'windows10' }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/configurationPolicies/sc-1/settings' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = '0'; settingInstance = @{ settingDefinitionId = 'foo' } }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/configurationPolicies/sc-1/assignments' } -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ target = @{ groupId = 'g-1' } }) }
            }

            Export-MsecIntuneConfiguration -Id 'sc-1' -Source 'SettingsCatalog'
        }

        $export.Id          | Should -Be 'sc-1'
        $export.Source      | Should -Be 'SettingsCatalog'
        $export.DisplayName | Should -Be 'Win10 Hardening'
        $export.Policy      | Should -Not -BeNullOrEmpty
        $export.Settings.Count     | Should -Be 1
        $export.Assignments.Count  | Should -Be 1
        $export.ExportedAt  | Should -Not -BeNullOrEmpty
    }

    It 'exports a classic Template by pulling the full config + assignments' {
        $export = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceConfigurations/tpl-1$' } -MockWith {
                [pscustomobject]@{
                    id = 'tpl-1'; displayName = 'iOS Restrictions'
                    '@odata.type' = '#microsoft.graph.iosGeneralDeviceConfiguration'
                    passcodeMinimumLength = 6
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceConfigurations/tpl-1/assignments' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            Export-MsecIntuneConfiguration -Id 'tpl-1' -Source 'Templates'
        }

        $export.Id            | Should -Be 'tpl-1'
        $export.Source        | Should -Be 'Templates'
        $export.DisplayName   | Should -Be 'iOS Restrictions'
        $export.Configuration.passcodeMinimumLength | Should -Be 6
        $export.Assignments.Count | Should -Be 0
    }

    It 'writes one JSON file per config to -OutDir, using the DisplayName for the filename' {
        $outDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().Guid)

        $files = InModuleScope msec -Parameters @{ OutDir = $outDir } {
            param($OutDir)
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceConfigurations/tpl-1$' } -MockWith {
                [pscustomobject]@{ id = 'tpl-1'; displayName = 'iOS Restrictions' }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceConfigurations/tpl-1/assignments' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            # Simulate a pipeline row from Get-MsecIntuneConfiguration
            [pscustomobject]@{ Id = 'tpl-1'; Source = 'Templates'; DisplayName = 'iOS Restrictions' } |
                Export-MsecIntuneConfiguration -OutDir $OutDir
        }

        $files.Count       | Should -Be 1
        $files[0].Name     | Should -Be 'iOS Restrictions.json'
        $files[0].Exists   | Should -BeTrue

        # Re-read and parse to make sure the JSON is valid.
        $json = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
        $json.Id | Should -Be 'tpl-1'

        Remove-Item -LiteralPath $outDir -Recurse -Force
    }
}
