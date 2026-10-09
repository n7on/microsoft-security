#Requires -Module Pester
#
# Tests for Get-MsecEntraConditionalAccessChange. Entra records a CA change as one property
# whose old and new values are the WHOLE policy as JSON; the command's job is to diff them.
#
# Covered, each from the real event shape:
#   - the diff reports only fields that moved, out of a large object
#   - modifiedDateTime is EXCLUDED: it changes on every edit, so leaving it in puts a
#     meaningless entry on every single row and buries the real one
#   - state is lifted into its own column, because enabled -> disabled is the highest-signal
#     CA change and is one field inside a big blob
#   - an APP actor is named: measured on a live tenant, 11 of 15 changes came from a
#     Microsoft365DSC service principal, so reading only initiatedBy.user loses the majority
#   - an empty result WARNS, because 30-day audit retention means silence is not stability

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module Msec -Force -ErrorAction SilentlyContinue }

Describe 'Get-MsecEntraConditionalAccessChange' {
    BeforeEach {
        InModuleScope Msec { Mock Assert-MsecSession -MockWith { } }
    }

    It 'diffs the policy JSON and reports only what moved, excluding modifiedDateTime' {
        $row = InModuleScope Msec {
            $old = @{ id='p1'; displayName='Require MFA'; state='enabled'
                      createdDateTime='2026-01-01T00:00:00Z'; modifiedDateTime='2026-10-08T07:00:00Z'
                      grantControls=@{ builtInControls=@('mfa') }
                      conditions=@{ clientAppTypes=@('all') } } | ConvertTo-Json -Depth 8
            $new = @{ id='p1'; displayName='Require MFA'; state='enabled'
                      createdDateTime='2026-01-01T00:00:00Z'; modifiedDateTime='2026-10-08T12:00:00Z'
                      grantControls=@{ builtInControls=@() }
                      conditions=@{ clientAppTypes=@('all') } } | ConvertTo-Json -Depth 8
            Mock Invoke-MsecGraphRequest -MockWith {
                @([pscustomobject]@{
                    activityDisplayName = 'Update conditional access policy'
                    activityDateTime = '2026-10-08T12:00:00Z'; result = 'success'; correlationId = 'c1'
                    initiatedBy = [pscustomobject]@{ user = [pscustomobject]@{ userPrincipalName = 'me@contoso.com' } }
                    targetResources = @([pscustomobject]@{
                        displayName = 'Require MFA'; id = 'p1'
                        modifiedProperties = @([pscustomobject]@{
                            displayName = 'ConditionalAccessPolicy'; oldValue = $old; newValue = $new })
                    })
                })
            }
            Get-MsecEntraConditionalAccessChange
        }

        $row.PolicyName | Should -Be 'Require MFA'
        $row.Actor | Should -Be 'me@contoso.com'
        $row.ActorType | Should -Be 'User'
        # The real change: MFA removed from the grant controls.
        ($row.ChangedProperties -join ' ') | Should -Match 'grantControls'
        # Noise that moves on every single edit must not be reported as a change.
        ($row.ChangedProperties -join ' ') | Should -Not -Match 'modifiedDateTime'
        ($row.ChangedProperties -join ' ') | Should -Not -Match 'createdDateTime'
        # Unchanged fields stay out.
        ($row.ChangedProperties -join ' ') | Should -Not -Match 'clientAppTypes'
    }

    It 'lifts a state change into its own column' {
        $row = InModuleScope Msec {
            $old = @{ id='p2'; displayName='X'; state='enabledForReportingButNotEnforced' } | ConvertTo-Json
            $new = @{ id='p2'; displayName='X'; state='enabled' } | ConvertTo-Json
            Mock Invoke-MsecGraphRequest -MockWith {
                @([pscustomobject]@{
                    activityDisplayName='Update conditional access policy'
                    activityDateTime='2026-10-08T12:12:16Z'; result='success'
                    initiatedBy=[pscustomobject]@{ app=[pscustomobject]@{ displayName='sc-m365dsc-ca-orchestrator' } }
                    targetResources=@([pscustomobject]@{ displayName='X'; id='p2'
                        modifiedProperties=@([pscustomobject]@{ displayName='ConditionalAccessPolicy'; oldValue=$old; newValue=$new }) })
                })
            }
            Get-MsecEntraConditionalAccessChange
        }

        $row.StateBefore | Should -Be 'enabledForReportingButNotEnforced'
        $row.StateAfter | Should -Be 'enabled'
        $row.StateChanged | Should -BeTrue
        # Filterable without parsing diffs - the point of the column.
    }

    It 'names an application actor, since most CA changes on an automated tenant have no user' {
        $row = InModuleScope Msec {
            $new = @{ id='p3'; displayName='New policy'; state='enabled' } | ConvertTo-Json
            Mock Invoke-MsecGraphRequest -MockWith {
                @([pscustomobject]@{
                    activityDisplayName='Add conditional access policy'
                    activityDateTime='2026-10-08T13:18:04Z'; result='success'
                    initiatedBy=[pscustomobject]@{
                        user=[pscustomobject]@{ userPrincipalName=$null }
                        app=[pscustomobject]@{ displayName='sc-m365dsc-ca-orchestrator' } }
                    targetResources=@([pscustomobject]@{ displayName='New policy'; id='p3'
                        modifiedProperties=@([pscustomobject]@{ displayName='ConditionalAccessPolicy'; oldValue=''; newValue=$new }) })
                })
            }
            Get-MsecEntraConditionalAccessChange
        }

        $row.Actor | Should -Be 'sc-m365dsc-ca-orchestrator'
        $row.ActorType | Should -Be 'Application'
        $row.Activity | Should -Match 'Add'
        # A create has no old value; every field reads as new rather than the row being empty.
        $row.ChangedCount | Should -BeGreaterThan 0
    }

    It 'filters by policy name and by actor' {
        $out = InModuleScope Msec {
            function New-Evt($pol, $who) {
                [pscustomobject]@{
                    activityDisplayName='Update conditional access policy'
                    activityDateTime='2026-10-08T12:00:00Z'; result='success'
                    initiatedBy=[pscustomobject]@{ user=[pscustomobject]@{ userPrincipalName=$who } }
                    targetResources=@([pscustomobject]@{ displayName=$pol; id=$pol
                        modifiedProperties=@([pscustomobject]@{ displayName='ConditionalAccessPolicy'
                            oldValue=(@{ id=$pol; state='enabled' } | ConvertTo-Json)
                            newValue=(@{ id=$pol; state='disabled' } | ConvertTo-Json) }) })
                }
            }
            Mock Invoke-MsecGraphRequest -MockWith { @((New-Evt 'CA901-Emergency' 'a@x.com'), (New-Evt 'CA500-Guests' 'b@x.com')) }
            [pscustomobject]@{
                ByName  = @(Get-MsecEntraConditionalAccessChange -PolicyName 'Emergency').PolicyName
                ByActor = @(Get-MsecEntraConditionalAccessChange -Actor 'b@x.com').PolicyName
            }
        }

        $out.ByName  | Should -Be 'CA901-Emergency'
        $out.ByActor | Should -Be 'CA500-Guests'
    }

    It 'warns on an empty result, because 30-day retention makes silence ambiguous' {
        $warning = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith { @() }
            $w = @()
            Get-MsecEntraConditionalAccessChange -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            "$($w -join ' ')"
        }

        $warning | Should -Match 'NOT evidence that the policies are unchanged'
        # Points at the property that outlives the audit log.
        $warning | Should -Match 'ModifiedDateTime'
    }

    It 'rewrites a 403 to mention both the permission and the licence' {
        $err = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            try { Get-MsecEntraConditionalAccessChange; $null } catch { "$($_.Exception.Message)" }
        }

        $err | Should -Match 'AuditLog\.Read\.All'
        # A free tenant has no directory audit log at all, which a permission error does not convey.
        $err | Should -Match 'Entra ID P1'
    }
}
