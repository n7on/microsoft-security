#Requires -Module Pester
#
# Tests for Get-MsecIntuneAuditEvent. The function GETs /deviceManagement/auditEvents with an
# activityDateTime filter and projects each change to a flat PSCustomObject.
#
# The tests target the things that are easy to get wrong and silent when they are:
#   - ChangedProperties carries 'Setting: old -> new' per modified property, which is the
#     whole reason the command exists.
#   - An actor with no userPrincipalName (a change made by an app) is still named, rather
#     than reported as having no author.
#   - An EMPTY result warns, because "nothing changed" and "out of retention" are the same
#     empty array and only one of them is an answer.
#   - Result is tested for SUCCESS, so an unfamiliar activityResult counts as a failure and
#     survives -FailedOnly rather than being silently filtered away.
#   - 403 is rewritten to name DeviceManagementApps.Read.All specifically - the Intune APPS
#     scope, which is not implied by any of the other Intune permissions the module holds.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecIntuneAuditEvent' {
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

            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
        }
    }

    It 'projects a change to the flat shape and renders each modified property as old -> new' {
        $row = InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceManagement/auditEvents' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id                    = 'evt-1'
                        displayName           = 'Patch DeviceConfiguration'
                        componentName         = 'DeviceConfiguration'
                        activity              = 'Patch DeviceConfiguration'
                        activityDateTime      = '2026-08-14T09:30:00Z'
                        activityType          = 'Patch'
                        activityOperationType = 'Patch'
                        activityResult        = 'Success'
                        correlationId         = 'corr-1'
                        category              = 'DeviceConfiguration'
                        actor                 = [pscustomobject]@{
                            userPrincipalName      = 'someone@contoso.com'
                            servicePrincipalName   = $null
                            applicationDisplayName = 'Microsoft Intune portal'
                            auditActorType         = 'ItPro'
                            ipAddress              = '203.0.113.9'
                            applicationId          = 'app-1'
                        }
                        resources             = @(
                            [pscustomobject]@{
                                displayName       = 'ASR baseline'
                                type              = 'DeviceConfiguration'
                                auditResourceType = 'DeviceConfiguration'
                                resourceId        = 'res-1'
                                modifiedProperties = @(
                                    [pscustomobject]@{ displayName = 'BlockSafeModeReboot'; oldValue = 'audit'; newValue = 'block' }
                                    [pscustomobject]@{ displayName = 'DisplayName';         oldValue = $null;   newValue = 'ASR baseline' }
                                )
                            }
                        )
                    }
                ) }
            }
            Get-MsecIntuneAuditEvent -Days 365
        }

        $row.Id | Should -Be 'evt-1'
        $row.Activity | Should -Be 'Patch DeviceConfiguration'
        $row.Category | Should -Be 'DeviceConfiguration'
        $row.Actor | Should -Be 'someone@contoso.com'
        $row.ActorIpAddress | Should -Be '203.0.113.9'
        $row.Succeeded | Should -BeTrue
        $row.ActivityDateTime | Should -BeOfType [datetime]
        $row.Resource | Should -Contain 'ASR baseline'

        # The point of the command: the setting that moved, with both values.
        $row.ChangedCount | Should -Be 2
        $row.ChangedProperties | Should -Contain 'BlockSafeModeReboot: audit -> block'
        # A null old value renders as (none), not as an empty gap that reads like a missing field.
        $row.ChangedProperties | Should -Contain 'DisplayName: (none) -> ASR baseline'
    }

    It 'names an actor that has no userPrincipalName, so app-made changes are not reported as authorless' {
        $row = InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceManagement/auditEvents' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'evt-2'; activity = 'Delete'; activityDateTime = '2026-08-01T00:00:00Z'
                        activityResult = 'Success'; category = 'Application'
                        actor = [pscustomobject]@{
                            userPrincipalName      = $null
                            servicePrincipalName   = 'automation-sp'
                            applicationDisplayName = 'Terraform'
                            auditActorType         = 'Application'
                        }
                        resources = @()
                    }
                ) }
            }
            Get-MsecIntuneAuditEvent
        }

        $row.Actor | Should -Be 'automation-sp'
        $row.ActorType | Should -Be 'Application'
        # No resources means no properties moved - zero, not null, and not an error.
        $row.ChangedCount | Should -Be 0
    }

    It 'warns on an empty result instead of returning silence, because out-of-retention looks identical' {
        $warnings = InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceManagement/auditEvents' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            $w = @()
            Get-MsecIntuneAuditEvent -Days 365 -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            , $w
        }

        $warnings.Count | Should -BeGreaterThan 0
        "$($warnings[0])" | Should -Match 'NOT the same as'
    }

    It 'treats an unrecognised activityResult as a failure, so -FailedOnly cannot hide one' {
        $rows = InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceManagement/auditEvents' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id='ok';   activity='A'; activityDateTime='2026-08-01T00:00:00Z'; activityResult='Success';            actor=[pscustomobject]@{}; resources=@() }
                    [pscustomobject]@{ id='bad';  activity='B'; activityDateTime='2026-08-01T00:00:00Z'; activityResult='Fail';               actor=[pscustomobject]@{}; resources=@() }
                    [pscustomobject]@{ id='odd';  activity='C'; activityDateTime='2026-08-01T00:00:00Z'; activityResult='PartiallyCompleted'; actor=[pscustomobject]@{}; resources=@() }
                ) }
            }
            , @(Get-MsecIntuneAuditEvent -FailedOnly)
        }

        @($rows | ForEach-Object Id) | Should -Be @('bad', 'odd')
    }

    It 'filters by resource name, activity and actor without matching regex metacharacters literally' {
        $rows = InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceManagement/auditEvents' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id='a'; activity='Patch DeviceConfiguration'; activityDateTime='2026-08-01T00:00:00Z'
                        activityResult='Success'; category='DeviceConfiguration'
                        actor=[pscustomobject]@{ userPrincipalName='mikael.wallen@viedoc.com' }
                        resources=@([pscustomobject]@{ displayName='Attack Surface Reduction (ASR)'; type='DeviceConfiguration' })
                    }
                    [pscustomobject]@{
                        id='b'; activity='Create Application'; activityDateTime='2026-08-01T00:00:00Z'
                        activityResult='Success'; category='Application'
                        actor=[pscustomobject]@{ userPrincipalName='someone.else@viedoc.com' }
                        resources=@([pscustomobject]@{ displayName='Company Portal'; type='Application' })
                    }
                ) }
            }
            [pscustomobject]@{
                ByResource = @(Get-MsecIntuneAuditEvent -Resource 'Attack Surface').Id
                ByActivity = @(Get-MsecIntuneAuditEvent -Activity 'Patch').Id
                ByActor    = @(Get-MsecIntuneAuditEvent -Actor 'mikael').Id
                ByCategory = @(Get-MsecIntuneAuditEvent -Category 'Application').Id
                # '(ASR)' contains regex metacharacters. Unescaped, this would match nothing
                # or throw; the function escapes the needle before matching.
                ByParens   = @(Get-MsecIntuneAuditEvent -Resource 'Reduction (ASR)').Id
            }
        }

        $rows.ByResource | Should -Be 'a'
        $rows.ByActivity | Should -Be 'a'
        $rows.ByActor    | Should -Be 'a'
        $rows.ByCategory | Should -Be 'b'
        $rows.ByParens   | Should -Be 'a'
    }

    It 'asks Graph for the requested window with an unquoted ISO 8601 literal' {
        $uri = InModuleScope Msec {
            $script:captured = $null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceManagement/auditEvents' } -MockWith {
                $script:captured = $Uri
                [pscustomobject]@{ value = @() }
            }
            Get-MsecIntuneAuditEvent -Days 365 -WarningAction SilentlyContinue | Out-Null
            $script:captured
        }

        $decoded = [uri]::UnescapeDataString($uri)
        $decoded | Should -Match 'activityDateTime ge \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z'
        # Quoting the datetime is a filter-parse 400 that does not name the date.
        $decoded | Should -Not -Match "activityDateTime ge '"
    }

    It 'rewrites a 403 to name DeviceManagementApps.Read.All, not the other Intune scopes' {
        $err = InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceManagement/auditEvents' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }
            try { Get-MsecIntuneAuditEvent; $null }
            catch { "$($_.Exception.Message)" }
        }

        $err | Should -Match 'DeviceManagementApps\.Read\.All'
        $err | Should -Match 'New-MsecApp'
        # The whole point of the message is that the obvious-looking scopes do NOT cover this.
        $err | Should -Match 'AuditLog\.Read\.All'
    }

    It 'filters by ResourceType, and falls back to displayName when Graph returns a blank activity' {
        $out = InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceManagement/auditEvents' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id='p'; activity=''; displayName='Create device configuration 2.0 (beta)'
                        activityDateTime='2026-02-27T09:15:20Z'; activityResult='Success'; category='DeviceConfiguration'
                        actor=[pscustomobject]@{ userPrincipalName='mathias_admin@viedoc.com' }
                        resources=@([pscustomobject]@{ displayName='Block use of copied or impersonated system tools'
                                                       auditResourceType='DeviceManagementConfigurationPolicy' })
                    }
                    [pscustomobject]@{
                        id='d'; activity=''; displayName='Sync device'
                        activityDateTime='2026-02-27T09:15:20Z'; activityResult='Success'; category='Device'
                        actor=[pscustomobject]@{ userPrincipalName='someone@viedoc.com' }
                        resources=@([pscustomobject]@{ displayName='LAPTOP-1'; auditResourceType='ManagedDevice' })
                    }
                ) }
            }
            [pscustomobject]@{
                Policies = @(Get-MsecIntuneAuditEvent -Days 365 -ResourceType 'DeviceManagementConfigurationPolicy')
                All      = @(Get-MsecIntuneAuditEvent -Days 365)
            }
        }

        @($out.Policies).Count | Should -Be 1
        $out.Policies[0].Id | Should -Be 'p'
        # Graph returned activity as an empty string on both rows; the column must still say
        # what happened rather than rendering blank.
        $out.Policies[0].Activity | Should -Be 'Create device configuration 2.0 (beta)'
        @($out.All | ForEach-Object Activity) | Should -Not -Contain ''
    }

    It 'warns with the resource names actually present when a filter matches nothing, ranked by frequency' {
        $warning = InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceManagement/auditEvents' } -MockWith {
                [pscustomobject]@{ value = @(
                    # One rarely-touched policy and one touched three times. Busiest must lead:
                    # sorted by name, 'Aaa rare policy' would come first and bury the answer.
                    [pscustomobject]@{ id='1'; displayName='x'; activityDateTime='2026-02-27T09:00:00Z'; activityResult='Success'; category='DeviceConfiguration'
                                       actor=[pscustomobject]@{}; resources=@([pscustomobject]@{ displayName='Aaa rare policy'; auditResourceType='DeviceManagementConfigurationPolicy' }) }
                    [pscustomobject]@{ id='2'; displayName='x'; activityDateTime='2026-02-27T09:00:00Z'; activityResult='Success'; category='DeviceConfiguration'
                                       actor=[pscustomobject]@{}; resources=@([pscustomobject]@{ displayName='Block use of copied or impersonated system tools'; auditResourceType='DeviceManagementConfigurationPolicy' }) }
                    [pscustomobject]@{ id='3'; displayName='x'; activityDateTime='2026-02-27T09:00:00Z'; activityResult='Success'; category='DeviceConfiguration'
                                       actor=[pscustomobject]@{}; resources=@([pscustomobject]@{ displayName='Block use of copied or impersonated system tools'; auditResourceType='DeviceManagementConfigurationPolicy' }) }
                    [pscustomobject]@{ id='4'; displayName='x'; activityDateTime='2026-02-27T09:00:00Z'; activityResult='Success'; category='DeviceConfiguration'
                                       actor=[pscustomobject]@{}; resources=@([pscustomobject]@{ displayName='Block use of copied or impersonated system tools'; auditResourceType='DeviceManagementConfigurationPolicy' }) }
                ) }
            }
            $w = @()
            Get-MsecIntuneAuditEvent -Days 365 -Resource 'Attack Surface' -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            "$($w -join ' ')"
        }

        # The distinction that cost an afternoon: events WERE returned, the filter missed.
        $warning | Should -Match 'FILTER miss and NOT an empty audit log'
        $warning | Should -Match '4 audit event'
        $warning | Should -Match 'Block use of copied or impersonated system tools'
        # Busiest first, so the three-hit policy precedes the one-hit one.
        $warning.IndexOf('Block use of copied') | Should -BeLessThan $warning.IndexOf('Aaa rare policy')
    }

    It 'does not warn about filters when the audit log itself is empty - that is a different message' {
        $warning = InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceManagement/auditEvents' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            $w = @()
            Get-MsecIntuneAuditEvent -Days 365 -Resource 'anything' -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            "$($w -join ' ')"
        }

        $warning | Should -Match 'NOT the same as'
        $warning | Should -Not -Match 'FILTER miss'
    }
}
