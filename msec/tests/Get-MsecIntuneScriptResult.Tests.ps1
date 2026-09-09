#Requires -Module Pester
#
# Tests for Get-MsecIntuneScriptResult. The behaviours that matter are the ones a partial
# implementation would get wrong and still look plausible: five different Intune script
# features projecting to one row shape without conflating what 'Output' means, a
# remediation's pre/post outputs both surviving, and a mistyped -Name failing loudly rather
# than returning nothing (which would read as "that script has never run").
#
# The five collections here ARE the complete set Intune exposes under /deviceManagement -
# verified against Graph's own $metadata, not from memory. Three of them share one
# deviceRunStates type, which is why the projection branches on StateShape rather than on
# -Source.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)

    # Passed as TEXT and rebuilt inside InModuleScope: a scriptblock stays bound to the
    # session state it was written in and could not resolve Mock's private targets there.
    #
    # EVERY collection is mocked. There is no catch-all, so an unmocked endpoint reaches the
    # real Invoke-RestMethod and fails as 401 - which is how the -Source All tests caught
    # the three new collections when they were added.
    $script:MockText = @'
Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
    [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
}

# ---- the five script collections ----
Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceHealthScripts$' } -MockWith {
    [pscustomobject]@{ value = @(
        [pscustomobject]@{ id = 'rem-1'; displayName = 'Check-BitLocker' }
        [pscustomobject]@{ id = 'rem-2'; displayName = 'Never-Ran' }
    ) }
}
Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceManagementScripts$' } -MockWith {
    [pscustomobject]@{ value = @([pscustomobject]@{ id = 'winps-1'; displayName = 'Set-RegistryTweak' }) }
}
Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceShellScripts$' } -MockWith {
    [pscustomobject]@{ value = @([pscustomobject]@{ id = 'macsh-1'; displayName = 'Install-Rosetta' }) }
}
Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceCustomAttributeShellScripts$' } -MockWith {
    [pscustomobject]@{ value = @([pscustomobject]@{ id = 'attr-1'; displayName = 'FileVault-Status' }) }
}
Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceComplianceScripts$' } -MockWith {
    [pscustomobject]@{ value = @([pscustomobject]@{ id = 'comp-1'; displayName = 'Check-TpmVersion' }) }
}

# ---- run states: deviceHealthScriptDeviceState (two outputs) ----
Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceHealthScripts/rem-1/deviceRunStates' } -MockWith {
    [pscustomobject]@{ value = @(
        [pscustomobject]@{
            id = 'rs-1'
            detectionState = 'success'; remediationState = 'success'
            preRemediationDetectionScriptOutput  = 'Suspended'
            postRemediationDetectionScriptOutput = 'On'
            lastStateUpdateDateTime = '2026-08-01T10:00:00Z'
            managedDevice = [pscustomobject]@{ id = 'dev-1'; deviceName = 'LAPTOP-A1'; userPrincipalName = 'a@x.com' }
        }
        [pscustomobject]@{
            id = 'rs-2'
            detectionState = 'fail'; remediationState = 'remediationFailed'
            preRemediationDetectionScriptOutput  = 'Off'
            postRemediationDetectionScriptOutput = $null
            remediationScriptError = 'Access denied enabling BitLocker'
            lastStateUpdateDateTime = '2026-08-02T10:00:00Z'
            managedDevice = [pscustomobject]@{ id = 'dev-2'; deviceName = 'LAPTOP-B2'; userPrincipalName = 'b@x.com' }
        }
    ) }
}
# Assigned but nothing has reported.
Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceHealthScripts/rem-2/deviceRunStates' } -MockWith {
    [pscustomobject]@{ value = @() }
}

# ---- run states: deviceManagementScriptDeviceState, shared by THREE features ----
Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceManagementScripts/winps-1/deviceRunStates' } -MockWith {
    [pscustomobject]@{ value = @(
        [pscustomobject]@{
            id = 'rs-5'; runState = 'success'; resultMessage = 'Registry value set'
            lastStateUpdateDateTime = '2026-08-04T10:00:00Z'
            managedDevice = [pscustomobject]@{ id = 'dev-5'; deviceName = 'DESKTOP-C3'; userPrincipalName = 'e@x.com' }
        }
    ) }
}
Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceShellScripts/macsh-1/deviceRunStates' } -MockWith {
    [pscustomobject]@{ value = @(
        [pscustomobject]@{
            id = 'rs-6'; runState = 'fail'; resultMessage = $null
            errorCode = 127; errorDescription = 'softwareupdate: command failed'
            lastStateUpdateDateTime = '2026-08-05T10:00:00Z'
            managedDevice = [pscustomobject]@{ id = 'dev-6'; deviceName = 'MacBook-Air-2'; userPrincipalName = 'f@x.com' }
        }
    ) }
}
Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceCustomAttributeShellScripts/attr-1/deviceRunStates' } -MockWith {
    [pscustomobject]@{ value = @(
        [pscustomobject]@{
            id = 'rs-3'; runState = 'success'; resultMessage = 'Enabled, 1 recovery key'
            lastStateUpdateDateTime = '2026-08-03T10:00:00Z'
            managedDevice = [pscustomobject]@{ id = 'dev-3'; deviceName = 'MacBook-Pro-1'; userPrincipalName = 'c@x.com' }
        }
        [pscustomobject]@{
            id = 'rs-4'; runState = 'scriptError'; resultMessage = $null
            errorCode = 1; errorDescription = 'command not found: fdesetup'
            lastStateUpdateDateTime = '2026-08-03T11:00:00Z'
            managedDevice = [pscustomobject]@{ id = 'dev-4'; deviceName = 'MacBook-Air-9'; userPrincipalName = 'd@x.com' }
        }
    ) }
}

# ---- run states: deviceComplianceScriptDeviceState (its own field names) ----
Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceComplianceScripts/comp-1/deviceRunStates' } -MockWith {
    [pscustomobject]@{ value = @(
        [pscustomobject]@{
            id = 'rs-7'
            detectionState = 'success'
            scriptOutput = '{"TpmVersion":"2.0"}'
            scriptError = $null
            lastStateUpdateDateTime = '2026-08-06T10:00:00Z'
            managedDevice = [pscustomobject]@{ id = 'dev-7'; deviceName = 'LAPTOP-D4'; userPrincipalName = 'g@x.com' }
        }
    ) }
}
'@
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecIntuneScriptResult' {
    BeforeEach {
        InModuleScope Msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId = 'tenant'; ClientId = 'client'; KeyVaultName = 'kv-test'
                KeyName = 'msec-app'; ThumbprintBytes = $Thumb; Tokens = @{}
            }
        }
    }

    It 'requires -Source, with no default' {
        # The features overlap in shape but not in meaning; a silent default would make an
        # empty result ambiguous between "no scripts" and "I did not ask".
        (Get-Command Get-MsecIntuneScriptResult).Parameters.Source.Attributes.Mandatory |
            Should -BeTrue
    }

    It 'offers every script source Intune has' {
        # If Microsoft adds a sixth collection this list is where it goes; the five here were
        # taken from Graph's $metadata rather than from the portal's navigation.
        $values = (Get-Command Get-MsecIntuneScriptResult).Parameters.Source.Attributes.ValidValues
        $values | Should -Contain 'Remediation'
        $values | Should -Contain 'PlatformScript'
        $values | Should -Contain 'CustomAttribute'
        $values | Should -Contain 'ComplianceScript'
        $values | Should -Contain 'All'
    }

    Context 'Remediation - deviceHealthScriptDeviceState' {

        It 'keeps both detection outputs' {
            $rows = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                @(Get-MsecIntuneScriptResult -Source Remediation -WarningAction SilentlyContinue)
            }

            @($rows).Count | Should -Be 2

            $fixed = $rows | Where-Object DeviceId -eq 'dev-1'
            $fixed.ScriptName            | Should -Be 'Check-BitLocker'
            $fixed.Source                | Should -Be 'Remediation'
            $fixed.Platform              | Should -Be 'Windows'
            $fixed.DeviceName            | Should -Be 'LAPTOP-A1'
            $fixed.State                 | Should -Be 'success'
            $fixed.RemediationState      | Should -Be 'success'
            # Output is the LATEST thing the detection script said - after the fix.
            $fixed.Output                | Should -Be 'On'
            # ...and both readings survive, so a row where the remediation changed the answer
            # is still legible.
            $fixed.PreRemediationOutput  | Should -Be 'Suspended'
            $fixed.PostRemediationOutput | Should -Be 'On'
            $fixed.PSObject.TypeNames    | Should -Contain 'MsecIntuneScriptResult'
        }

        It 'falls back to the pre-remediation output when no remediation has run' {
            $row = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                @(Get-MsecIntuneScriptResult -Source Remediation -WarningAction SilentlyContinue) |
                    Where-Object DeviceId -eq 'dev-2'
            }

            # Post is $null until a remediation actually runs, so pre IS the current answer.
            $row.Output                | Should -Be 'Off'
            $row.PostRemediationOutput | Should -BeNullOrEmpty
            $row.RemediationState      | Should -Be 'remediationFailed'
            $row.Error                 | Should -Be 'Access denied enabling BitLocker'
        }
    }

    Context 'PlatformScript - both operating systems, one Graph type' {

        It 'reads Windows and macOS platform scripts under one -Source' {
            # One blade in the portal, two collections in Graph. The Platform column tells
            # them apart, which is why they do not need separate -Source values.
            $rows = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                @(Get-MsecIntuneScriptResult -Source PlatformScript)
            }

            @($rows).Count | Should -Be 2

            $win = $rows | Where-Object Platform -eq 'Windows'
            $win.ScriptName | Should -Be 'Set-RegistryTweak'
            $win.Source     | Should -Be 'PlatformScript'
            $win.State      | Should -Be 'success'
            $win.Output     | Should -Be 'Registry value set'

            $mac = $rows | Where-Object Platform -eq 'macOS'
            $mac.ScriptName | Should -Be 'Install-Rosetta'
            $mac.State      | Should -Be 'fail'
            $mac.Error      | Should -Be 'softwareupdate: command failed'
            # No remediation concept here, so those columns stay empty rather than invented.
            $mac.RemediationState      | Should -BeNullOrEmpty
            $mac.PreRemediationOutput  | Should -BeNullOrEmpty
        }
    }

    Context 'CustomAttribute - the attribute value' {

        It 'puts resultMessage in Output' {
            $rows = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                @(Get-MsecIntuneScriptResult -Source CustomAttribute)
            }

            @($rows).Count | Should -Be 2

            $ok = $rows | Where-Object DeviceId -eq 'dev-3'
            $ok.Source   | Should -Be 'CustomAttribute'
            $ok.Platform | Should -Be 'macOS'
            # resultMessage IS the attribute value - the reason the attribute exists.
            $ok.Output   | Should -Be 'Enabled, 1 recovery key'

            $bad = $rows | Where-Object DeviceId -eq 'dev-4'
            $bad.State  | Should -Be 'scriptError'
            $bad.Error  | Should -Be 'command not found: fdesetup'
            $bad.Output | Should -BeNullOrEmpty
        }
    }

    Context 'ComplianceScript - deviceComplianceScriptDeviceState' {

        It 'reads scriptOutput, which is the JSON the compliance rules are evaluated against' {
            # Its own field names: scriptOutput / scriptError / detectionState, none of which
            # the other two shapes use. A custom compliance policy is only as trustworthy as
            # this output.
            $row = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                @(Get-MsecIntuneScriptResult -Source ComplianceScript)
            }

            @($row).Count | Should -Be 1
            $row.ScriptName       | Should -Be 'Check-TpmVersion'
            $row.Source           | Should -Be 'ComplianceScript'
            $row.Platform         | Should -Be 'Windows'
            $row.DeviceName       | Should -Be 'LAPTOP-D4'
            $row.State            | Should -Be 'success'
            $row.Output           | Should -Be '{"TpmVersion":"2.0"}'
            $row.Error            | Should -BeNullOrEmpty
            $row.RemediationState | Should -BeNullOrEmpty
        }
    }

    Context '-Source All' {

        It 'means all five collections, not merely the ones it used to mean' {
            $rows = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                @(Get-MsecIntuneScriptResult -Source All -WarningAction SilentlyContinue)
            }

            # 2 remediation + 2 platform + 2 custom attribute + 1 compliance. 'Never-Ran'
            # contributes none.
            @($rows).Count | Should -Be 7
            @($rows.Source | Sort-Object -Unique) |
                Should -Be @('ComplianceScript', 'CustomAttribute', 'PlatformScript', 'Remediation')
            # One row shape across all of them, which is what makes a single Where-Object work.
            @($rows.Platform | Sort-Object -Unique) | Should -Be @('macOS', 'Windows')
        }
    }

    Context '-Name' {

        It 'reads only the named script, and only that script''s run states' {
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                # A run-states call for the other script would be wasted work on a tenant
                # with thousands of devices.
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceHealthScripts/rem-2/deviceRunStates' } -MockWith {
                    throw 'the unnamed script must not be read'
                }
                @(Get-MsecIntuneScriptResult -Source Remediation -Name 'Check-BitLocker')
            }

            @($out).Count | Should -Be 2
            ($out.ScriptName | Sort-Object -Unique) | Should -Be 'Check-BitLocker'
        }

        It 'matches case-insensitively, ignores whitespace, and accepts an id' {
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                [pscustomobject]@{
                    ByName = @(Get-MsecIntuneScriptResult -Source Remediation -Name '  check-bitlocker ')
                    ById   = @(Get-MsecIntuneScriptResult -Source CustomAttribute -Name 'attr-1')
                }
            }
            @($out.ByName).Count | Should -Be 2
            @($out.ById).Count   | Should -Be 2
        }

        It 'throws on an unrecognised name, listing what the tenant has' {
            # A typo returning zero rows would read as "that script has never run".
            $message = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                try { Get-MsecIntuneScriptResult -Source Remediation -Name 'Check-Bitlockr' | Out-Null; '' }
                catch { $_.Exception.Message }
            }

            $message | Should -Match 'Unrecognised script name'
            $message | Should -Match 'Check-Bitlockr'
            $message | Should -Match 'Check-BitLocker'
        }

        It 'throws before emitting anything when one of several names is wrong' {
            # Names are resolved in a first pass precisely so a partial stream is impossible -
            # a truncated result that looks complete is worse than an error.
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                $rows = @()
                try { $rows = @(Get-MsecIntuneScriptResult -Source Remediation -Name 'Check-BitLocker', 'Nope') }
                catch { }
                [pscustomobject]@{ Rows = @($rows) }
            }

            @($out.Rows).Count | Should -Be 0
        }

        It 'accepts a name that matches only one of the five under -Source All' {
            # A Windows remediation name is not expected among the macOS scripts, so a miss is
            # only fatal when nothing matched it anywhere.
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                @(Get-MsecIntuneScriptResult -Source All -Name 'FileVault-Status')
            }

            @($out).Count | Should -Be 2
            ($out.Source | Sort-Object -Unique) | Should -Be 'CustomAttribute'
        }

        It 'warns for a named script with no results, but stays quiet when sweeping' {
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                $named = Get-MsecIntuneScriptResult -Source Remediation -Name 'Never-Ran' `
                            -WarningVariable wNamed -WarningAction SilentlyContinue
                $swept = Get-MsecIntuneScriptResult -Source Remediation `
                            -WarningVariable wSwept -WarningAction SilentlyContinue
                [pscustomobject]@{
                    NamedRows = @($named); NamedWarnings = @($wNamed)
                    SweptRows = @($swept); SweptWarnings = @($wSwept)
                }
            }

            # Asked for it by name and got nothing - that needs saying.
            @($out.NamedRows).Count         | Should -Be 0
            ($out.NamedWarnings -join "`n") | Should -Match 'nothing has reported yet'
            # Sweeping the tenant, an idle script is ordinary and warning would be noise.
            @($out.SweptRows).Count         | Should -Be 2
            @($out.SweptWarnings).Count     | Should -Be 0
        }
    }

    Context 'degradation' {

        It 'retries without the expand when Graph rejects it, warning once' {
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))

                # Catch-all first so the specific expand-rejection mock wins.
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'deviceRunStates' } -MockWith {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ id = 'rs-9'; detectionState = 'success'
                                           preRemediationDetectionScriptOutput = 'On' }
                    ) }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'deviceRunStates\?\$expand=managedDevice' } -MockWith {
                    throw 'Response status code does not indicate success: 400 (Bad Request). Could not parse $expand'
                }

                $rows = Get-MsecIntuneScriptResult -Source Remediation `
                            -WarningVariable w -WarningAction SilentlyContinue
                [pscustomobject]@{ Rows = @($rows); Warnings = @($w) }
            }

            # The script output survives - it is the point of the call.
            @($out.Rows).Count      | Should -BeGreaterThan 0
            $out.Rows[0].Output     | Should -Be 'On'
            # ...and a row is never unattributable: DeviceId falls back to the run-state id.
            $out.Rows[0].DeviceId   | Should -Be 'rs-9'
            $out.Rows[0].DeviceName | Should -BeNullOrEmpty
            # One warning for the run, not one per script - it is an API-version fact.
            @($out.Warnings | Where-Object { $_ -match 'expand' }).Count | Should -Be 1
        }

        It 'rewrites a 403 to name the scripts scope, not the configuration one' {
            # Intune scripts need DeviceManagementScripts.Read.All. Naming the Configuration
            # scope - which the app already holds - sent a real user looking in exactly the
            # wrong place.
            InModuleScope Msec {
                Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                    [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceHealthScripts' } -MockWith {
                    throw 'Response status code does not indicate success: 403 (Forbidden).'
                }

                { Get-MsecIntuneScriptResult -Source Remediation } |
                    Should -Throw -ExpectedMessage '*DeviceManagementScripts.Read.All*'
            }
        }
    }
}
