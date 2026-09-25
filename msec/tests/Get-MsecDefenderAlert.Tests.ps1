#Requires -Module Pester
#
# Tests for Get-MsecDefenderIncident and Get-MsecDefenderAlert.
#
# Three things these commands must not get wrong, all of the same family - a value that means
# "no answer yet" must never render as a measurement:
#
#   ResolveDays on an open item is $null, never 0. Zero reads as "closed instantly", which is
#   the opposite of a still-running investigation.
#
#   A redirected incident was merged into another one. It is the same attack counted twice, so
#   it has to be visible and droppable - but never dropped silently, or a count that shrank has
#   no explanation.
#
#   serviceSource 'unknownFutureValue' is Graph saying it has no name for the source, not a
#   workload called that. It is passed through verbatim rather than guessed at.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module msec -Force -ErrorAction SilentlyContinue }

Describe 'Get-MsecDefenderIncident' {
    BeforeEach {
        InModuleScope msec { $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} } }
    }

    It 'leaves ResolveDays null while an incident is open' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ id = 'i1'; displayName = 'open'; severity = 'high'; status = 'active'
                                   classification = 'unknown'
                                   createdDateTime = '2026-09-01T00:00:00Z'; lastUpdateDateTime = '2026-09-10T00:00:00Z' }
                [pscustomobject]@{ id = 'i2'; displayName = 'done'; severity = 'low'; status = 'resolved'
                                   classification = 'unknown'
                                   createdDateTime = '2026-09-01T00:00:00Z'; lastUpdateDateTime = '2026-09-03T00:00:00Z' }
            }
            Get-MsecDefenderIncident -Days 90
        }

        ($rows | Where-Object Id -eq 'i1').ResolveDays | Should -BeNullOrEmpty
        ($rows | Where-Object Id -eq 'i2').ResolveDays | Should -Be 2
    }

    It 'returns redirected incidents by default and drops them only when asked' {
        $result = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ id = 'i1'; status = 'active';     severity = 'low'; createdDateTime = '2026-09-01T00:00:00Z' }
                # Merged into i1 - the same attack, counted twice if this is treated as its own.
                [pscustomobject]@{ id = 'i2'; status = 'redirected'; severity = 'low'; createdDateTime = '2026-09-01T00:00:00Z'
                                   redirectIncidentId = 'i1' }
            }
            [pscustomobject]@{
                All  = @(Get-MsecDefenderIncident -Days 90)
                Kept = @(Get-MsecDefenderIncident -Days 90 -ExcludeRedirected)
            }
        }
        $all  = @($result.All)
        $kept = @($result.Kept)

        $all.Count  | Should -Be 2
        $kept.Count | Should -Be 1
        # Visible rather than implied: the row names what absorbed it.
        ($all | Where-Object Id -eq 'i2').RedirectedToIncidentId | Should -Be 'i1'
    }

    It 'reports AlertCount as null when the alerts could not be read, not zero' {
        $row = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'incidents\?' } -MockWith {
                [pscustomobject]@{ id = 'i1'; status = 'active'; severity = 'low'; createdDateTime = '2026-09-01T00:00:00Z' }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/alerts$' } -MockWith { throw 'Forbidden' }
            Get-MsecDefenderIncident -Days 90 -IncludeAlerts
        }

        # An incident whose alerts were refused has not been shown to have none.
        $row.AlertCount | Should -BeNullOrEmpty
    }

    It 'names the permission when the endpoint refuses' {
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            { Get-MsecDefenderIncident } | Should -Throw '*SecurityIncident.Read.All*'
        }
    }
}

Describe 'Get-MsecDefenderAlert' {
    BeforeEach {
        InModuleScope msec { $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} } }
    }

    It 'passes unknownFutureValue through rather than guessing a workload' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                # 231 of 569 alerts on a live tenant came back exactly like this.
                [pscustomobject]@{ id = 'a1'; title = 'Role grant'; severity = 'high'; status = 'new'
                                   serviceSource = 'unknownFutureValue'; productName = 'Microsoft Entra ID'
                                   createdDateTime = '2026-09-01T00:00:00Z'; evidence = @(1, 2) }
            }
            Get-MsecDefenderAlert -Days 90
        }

        $rows.ServiceSource | Should -Be 'unknownFutureValue'
        # The fields that are often populated when ServiceSource is not.
        $rows.ProductName   | Should -Be 'Microsoft Entra ID'
        $rows.EvidenceCount | Should -Be 2
    }

    It 'leaves ResolveDays null while an alert is open' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ id = 'a1'; status = 'new'; severity = 'low'
                                   createdDateTime = '2026-09-01T00:00:00Z' }
                [pscustomobject]@{ id = 'a2'; status = 'resolved'; severity = 'low'
                                   createdDateTime = '2026-09-01T00:00:00Z'; resolvedDateTime = '2026-09-04T00:00:00Z' }
            }
            Get-MsecDefenderAlert -Days 90
        }

        ($rows | Where-Object Id -eq 'a1').ResolveDays | Should -BeNullOrEmpty
        ($rows | Where-Object Id -eq 'a2').ResolveDays | Should -Be 3
    }

    It 'uses the alert status vocabulary, which is not the incident one' {
        # An alert is never 'active'; an incident never 'new'. Filtering both with one string
        # silently finds nothing in one of them, so the ValidateSet has to differ.
        $valid = (Get-Command Get-MsecDefenderAlert).Parameters['Status'].Attributes |
                     Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                     Select-Object -ExpandProperty ValidValues
        $valid | Should -Contain 'new'
        $valid | Should -Not -Contain 'active'
        $valid | Should -Not -Contain 'redirected'
    }
}
