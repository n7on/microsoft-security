#Requires -Module Pester
#
# Tests for New-MsecDefenderDetectionRule.
#
# The command's reason to exist is that it RUNS the query before creating the rule, so most of
# these cover the refusals:
#   - a query that does not run must not become a rule; Defender would accept it and then
#     autoDisable it later, leaving a dead rule that looks live.
#   - a query missing a column the entity mapping names must be refused, naming the column,
#     because Defender's own rejection does not say which.
#   - a query matching NOTHING must still be allowed - that is the normal state of a good
#     detection, and refusing it would block exactly the rules worth having.
#   - a query matching a lot must warn before creating an alert cannon.
#   - 403 must blame the user's scope, not the app's.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module Msec -Force -ErrorAction SilentlyContinue }

Describe 'New-MsecDefenderDetectionRule' {
    BeforeEach {
        InModuleScope Msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Assert-MsecAdminSession -MockWith { }
            Mock Invoke-MsecAdminGraphRequest -MockWith {
                $b = $Body
                [pscustomobject]@{
                    id = $b.id; displayName = $b.displayName; description = $b.description
                    status = $b.status
                    queryCondition = [pscustomobject]@{ queryText = $b.queryCondition.queryText }
                    schedule = [pscustomobject]@{ frequency = $b.schedule.frequency }
                    detectionAction = [pscustomobject]@{ alertTemplate = [pscustomobject]@{
                        title = $b.detectionAction.alertTemplate.title
                        severity = $b.detectionAction.alertTemplate.severity } }
                    createdBy = 'me@contoso.com'; createdDateTime = '2026-10-08T10:00:00Z'
                }
            }
        }
    }

    It 'refuses to create a rule whose query does not run' {
        $err = InModuleScope Msec {
            Mock Search-MsecDefenderHunting -MockWith { throw "Failed to resolve table named 'NoSuchTable'" }
            try {
                New-MsecDefenderDetectionRule -DisplayName 'Broken' -Query 'NoSuchTable | take 1' `
                    -Description 'x' -Confirm:$false
                $null
            } catch { "$($_.Exception.Message)" }
        }

        $err | Should -Match 'does not run'
        $err | Should -Match 'autoDisabled'
        InModuleScope Msec { Should -Invoke Invoke-MsecAdminGraphRequest -Times 0 -Exactly }
    }

    It 'refuses when the query omits a column the entity mapping names, and says which' {
        $err = InModuleScope Msec {
            Mock Search-MsecDefenderHunting -MockWith {
                @([pscustomobject]@{ Timestamp = (Get-Date); DeviceName = 'vie0001' })   # no DeviceId
            }
            try {
                New-MsecDefenderDetectionRule -DisplayName 'No device id' -Query 'DeviceEvents' `
                    -Description 'x' -Confirm:$false
                $null
            } catch { "$($_.Exception.Message)" }
        }

        $err | Should -Match 'DeviceId'
        # Defender's own error does not name the column, which is the whole reason for this check.
        $err | Should -Match 'does not say which'
        InModuleScope Msec { Should -Invoke Invoke-MsecAdminGraphRequest -Times 0 -Exactly }
    }

    It 'creates a rule whose query matches nothing - the normal state of a good detection' {
        $row = InModuleScope Msec {
            Mock Search-MsecDefenderHunting -MockWith { @() }
            New-MsecDefenderDetectionRule -DisplayName 'Quiet rule' -Query 'DeviceEvents | where 1 == 0' `
                -Description 'Should be silent' -Confirm:$false
        }

        $row.Id | Should -Be 'quiet-rule'      # slug derived from the name
        $row.Status | Should -Be 'enabled'
        $row.ValidationRows | Should -Be 0
        InModuleScope Msec { Should -Invoke Invoke-MsecAdminGraphRequest -Times 1 -Exactly }
    }

    It 'warns before creating a rule that would match hundreds of rows' {
        $out = InModuleScope Msec {
            Mock Search-MsecDefenderHunting -MockWith {
                1..200 | ForEach-Object { [pscustomobject]@{ Timestamp = (Get-Date); DeviceId = "d$_"; DeviceName = "n$_" } }
            }
            $w = @()
            $r = New-MsecDefenderDetectionRule -DisplayName 'Noisy' -Query 'DeviceEvents' `
                    -Description 'x' -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
            [pscustomobject]@{ Row = $r; Warnings = "$($w -join ' ')" }
        }

        $out.Warnings | Should -Match '200 row'
        $out.Warnings | Should -Match 'somebody switches off'
        # Warned, but still created - the caller may know it is a reporting rule.
        $out.Row.ValidationRows | Should -Be 200
    }

    It 'maps frequency, severity and MITRE into the request body' {
        $body = InModuleScope Msec {
            $script:sent = $null
            Mock Search-MsecDefenderHunting -MockWith { @() }
            Mock Invoke-MsecAdminGraphRequest -MockWith {
                $script:sent = $Body
                [pscustomobject]@{ id=$Body.id; displayName=$Body.displayName; status=$Body.status
                                   queryCondition=[pscustomobject]@{}; schedule=[pscustomobject]@{}
                                   detectionAction=[pscustomobject]@{ alertTemplate=[pscustomobject]@{} } }
            }
            New-MsecDefenderDetectionRule -DisplayName 'Safe Mode blocked' -Query 'DeviceEvents' `
                -Description 'x' -Severity medium -Frequency 3h `
                -Tactic DefenseEvasion -Technique 'T1562.009' -Confirm:$false | Out-Null
            $script:sent
        }

        $body.schedule.frequency | Should -Be 'PT3H'
        $body.detectionAction.alertTemplate.severity | Should -Be 'medium'
        $body.detectionAction.alertTemplate.tactics[0].tactic | Should -Be 'DefenseEvasion'
        $body.detectionAction.alertTemplate.tactics[0].techniques[0].technique | Should -Be 'T1562.009'
        $body.detectionAction.alertTemplate.entityMappings.hosts[0].deviceIdColumn | Should -Be 'DeviceId'
        $body.status | Should -Be 'enabled'
    }

    It 'rejects a technique without a tactic, which Defender refuses server-side' {
        $err = InModuleScope Msec {
            Mock Search-MsecDefenderHunting -MockWith { @() }
            try {
                New-MsecDefenderDetectionRule -DisplayName 'x' -Query 'DeviceEvents' -Description 'x' `
                    -Technique 'T1562.009' -Confirm:$false
                $null
            } catch { "$($_.Exception.Message)" }
        }
        $err | Should -Match 'technique without a tactic'
    }

    It 'creates nothing under -WhatIf' {
        InModuleScope Msec {
            Mock Search-MsecDefenderHunting -MockWith { @() }
            New-MsecDefenderDetectionRule -DisplayName 'Dry run' -Query 'DeviceEvents' -Description 'x' -WhatIf | Out-Null
            Should -Invoke Invoke-MsecAdminGraphRequest -Times 0 -Exactly
        }
    }

    It 'blames the signed-in user for a 403, and names the only scope that works' {
        $err = InModuleScope Msec {
            Mock Search-MsecDefenderHunting -MockWith { @() }
            Mock Invoke-MsecAdminGraphRequest -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            try { New-MsecDefenderDetectionRule -DisplayName 'x' -Query 'DeviceEvents' -Description 'x' -Confirm:$false; $null }
            catch { "$($_.Exception.Message)" }
        }

        $err | Should -Match 'CustomDetection\.ReadWrite\.All'
        $err | Should -Match 'no read-only or lesser scope'
        $err | Should -Match 'YOUR authorization'
    }
}
