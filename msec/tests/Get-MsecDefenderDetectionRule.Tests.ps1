#Requires -Module Pester
#
# Tests for Get-MsecDefenderDetectionRule.
#
# Each covers a way this can silently mislead:
#   - isEnabled was REMOVED from the resource on 2026-10-01. Reading it gets $null, which is
#     falsy, and reports every live rule as disabled. 'status' is the replacement.
#   - 'autoDisabled' is a state isEnabled could never express: Defender switched the rule off
#     because its query broke. It still appears in the portal and is not running.
#   - An empty list is not "we have no detections" - built-in analytics and Sentinel rules are
#     separate stores - so it warns rather than returning silence.
#   - The 403 must say why ThreatHunting.Read.All is not enough, since that is the permission
#     anyone would assume covers this.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module Msec -Force -ErrorAction SilentlyContinue }

Describe 'Get-MsecDefenderDetectionRule' {
    BeforeEach {
        InModuleScope Msec { Mock Assert-MsecSession -MockWith { } }
    }

    It 'projects a rule from status, schedule and alert template' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                @([pscustomobject]@{
                    id = 'r1'; displayName = 'Anthropic cert rotation'
                    description = 'New signing cert needs an indicator'
                    status = 'enabled'
                    createdBy = 'me@contoso.com'; createdDateTime = '2026-10-08T09:00:00Z'
                    lastModifiedBy = 'me@contoso.com'; lastModifiedDateTime = '2026-10-08T09:00:00Z'
                    queryCondition = [pscustomobject]@{ queryText = 'DeviceFileCertificateInfo | where Signer has "Anthropic"' }
                    schedule = [pscustomobject]@{ frequency = 'PT24H'; nextRunDateTime = '2026-10-09T09:00:00Z' }
                    detectionAction = [pscustomobject]@{ alertTemplate = [pscustomobject]@{
                        title = 'Unapproved Anthropic signing certificate'; severity = 'informational'; category = 'Discovery' } }
                })
            }
            Get-MsecDefenderDetectionRule
        }

        $row.DisplayName | Should -Be 'Anthropic cert rotation'
        $row.Status | Should -Be 'enabled'
        $row.IsRunning | Should -BeTrue
        $row.Frequency | Should -Be 'PT24H'
        $row.NextRun | Should -BeOfType [datetime]
        $row.Severity | Should -Be 'informational'
        $row.Query | Should -Match 'DeviceFileCertificateInfo'
    }

    It 'surfaces autoDisabled and warns, because such a rule looks live and is not running' {
        $out = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                @(
                    [pscustomobject]@{ id='ok';   displayName='Working';  status='enabled'
                                       queryCondition=[pscustomobject]@{ queryText='DeviceEvents' }
                                       schedule=[pscustomobject]@{}; detectionAction=[pscustomobject]@{} }
                    [pscustomobject]@{ id='dead'; displayName='Broken query'; status='autoDisabled'
                                       queryCondition=[pscustomobject]@{ queryText='DeviceEvents | where RenamedColumn == 1' }
                                       schedule=[pscustomobject]@{}; detectionAction=[pscustomobject]@{} }
                )
            }
            $w = @()
            $r = @(Get-MsecDefenderDetectionRule -WarningVariable w -WarningAction SilentlyContinue)
            [pscustomobject]@{ Rows = $r; Warnings = "$($w -join ' ')" }
        }

        $dead = $out.Rows | Where-Object Id -eq 'dead'
        $dead.Status | Should -Be 'autoDisabled'
        # Not running, but also not 'disabled' - nobody chose this.
        $dead.IsRunning | Should -BeFalse
        $out.Warnings | Should -Match 'AUTODISABLED'
        $out.Warnings | Should -Match 'still appear in the portal'
    }

    It 'does not read the retired isEnabled property as authoritative' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                @(
                    # Current shape: status present, isEnabled gone. A reader still keyed on
                    # isEnabled would get $null and call this disabled.
                    [pscustomobject]@{ id='new'; displayName='Current'; status='enabled'
                                       queryCondition=[pscustomobject]@{}; schedule=[pscustomobject]@{}
                                       detectionAction=[pscustomobject]@{} }
                    # Legacy shape, for a tenant still returning the old property.
                    [pscustomobject]@{ id='old'; displayName='Legacy'; isEnabled=$true
                                       queryCondition=[pscustomobject]@{}; schedule=[pscustomobject]@{}
                                       detectionAction=[pscustomobject]@{} }
                    # Neither: unknown, which must not be reported as off.
                    [pscustomobject]@{ id='unk'; displayName='Unknown'
                                       queryCondition=[pscustomobject]@{}; schedule=[pscustomobject]@{}
                                       detectionAction=[pscustomobject]@{} }
                )
            }
            , @(Get-MsecDefenderDetectionRule)
        }

        ($rows | Where-Object Id -eq 'new').IsRunning | Should -BeTrue
        ($rows | Where-Object Id -eq 'old').Status    | Should -Be 'enabled'
        ($rows | Where-Object Id -eq 'unk').Status    | Should -BeNullOrEmpty
        ($rows | Where-Object Id -eq 'unk').IsRunning | Should -BeNullOrEmpty
    }

    It 'filters on the query text, so "is anything watching this" is one call' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                @(
                    [pscustomobject]@{ id='asr'; displayName='ASR blocks'; status='enabled'
                                       queryCondition=[pscustomobject]@{ queryText='DeviceEvents | where ActionType startswith "Asr"' }
                                       schedule=[pscustomobject]@{}; detectionAction=[pscustomobject]@{} }
                    [pscustomobject]@{ id='mail'; displayName='Phish'; status='enabled'
                                       queryCondition=[pscustomobject]@{ queryText='EmailEvents | where ThreatTypes has "Phish"' }
                                       schedule=[pscustomobject]@{}; detectionAction=[pscustomobject]@{} }
                )
            }
            , @(Get-MsecDefenderDetectionRule -Query 'Asr')
        }

        @($rows | ForEach-Object Id) | Should -Be @('asr')
    }

    It 'warns on an empty list rather than implying there are no detections anywhere' {
        $warning = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith { @() }
            $w = @()
            Get-MsecDefenderDetectionRule -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            "$($w -join ' ')"
        }

        $warning | Should -Match 'NOT the same as having no detections'
        # The neighbouring store, named so the reader does not conclude too much.
        $warning | Should -Match 'Get-MsecSentinelRule'
    }

    It 'explains why ThreatHunting.Read.All does not cover this' {
        $err = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            try { Get-MsecDefenderDetectionRule; $null } catch { "$($_.Exception.Message)" }
        }

        $err | Should -Match 'CustomDetection\.Read\.All'
        $err | Should -Match 'ThreatHunting\.Read\.All'
        $err | Should -Match 'New-MsecApp'
    }
}
