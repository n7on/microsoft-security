#Requires -Module Pester
#
# Tests for Get-MsecAzureDevOpsWorkItem.
#
# The traps here are specific to Azure DevOps rather than to security:
#
#   'OPEN' IS NOT A STATE NAME. Agile uses New/Active/Resolved/Closed, Scrum uses
#   New/Approved/Committed/Done, Basic uses To Do/Doing/Done. Filtering on a state name returns
#   nothing on a process that does not use it, so -OpenOnly works on the state CATEGORY.
#
#   AN UNCLASSIFIABLE STATE IS KEPT, NOT DROPPED. Excluding an item because msec could not work
#   out whether it was closed would quietly shrink the list someone is using to chase work.
#
#   THE HELPER ALREADY UNWRAPS 'value'. workitemsbatch returns {count, value:[...]} and
#   Invoke-MsecAzureDevOpsRequest hands back the array; taking .value again yields nothing, and
#   the symptom is a correct row COUNT with every field blank. That happened while writing this.
#
#   WIQL STRING LITERALS ARE SINGLE-QUOTED, so an apostrophe in a tag has to be doubled or the
#   query fails to parse.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureDevOpsWorkItem' {

    It 'reads fields from the batch response the helper already unwrapped' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                if ($Path -match 'wiql')              { [pscustomobject]@{ workItems = @([pscustomobject]@{ id = 1 }) } }
                elseif ($Path -match 'workitemsbatch') {
                    # The helper returns the items THEMSELVES, not an envelope.
                    @([pscustomobject]@{ id = 1; fields = [pscustomobject]@{
                        'System.WorkItemType' = 'Task'; 'System.Title' = 'Do the thing'
                        'System.State' = 'To Do'; 'System.Tags' = 'security'
                        'System.TeamProject' = 'Sec'
                        'System.CreatedDate' = (Get-Date).AddDays(-10).ToString('o') } })
                }
                elseif ($Path -match 'states')         { @([pscustomobject]@{ name = 'To Do'; category = 'Proposed' }) }
            }
            Get-MsecAzureDevOpsWorkItem -Organization org -Project Sec
        }

        $rows.Count | Should -Be 1
        $rows[0].Title | Should -Be 'Do the thing'
        $rows[0].Tags  | Should -Be @('security')
        $rows[0].StateCategory | Should -Be 'Proposed'
        $rows[0].AgeDays | Should -BeGreaterOrEqual 9
    }

    It 'takes BacklogRank from whichever rank field the process populates' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                if ($Path -match 'wiql') { [pscustomobject]@{ workItems = @([pscustomobject]@{id=1},[pscustomobject]@{id=2},[pscustomobject]@{id=3}) } }
                elseif ($Path -match 'workitemsbatch') {
                    @(
                        # Scrum writes BacklogPriority...
                        [pscustomobject]@{ id=1; fields=[pscustomobject]@{ 'System.WorkItemType'='T'; 'System.State'='New'; 'System.TeamProject'='P'
                                                                           'Microsoft.VSTS.Common.BacklogPriority'=1418086018 } }
                        # ...Agile and CMMI write StackRank.
                        [pscustomobject]@{ id=2; fields=[pscustomobject]@{ 'System.WorkItemType'='T'; 'System.State'='New'; 'System.TeamProject'='P'
                                                                           'Microsoft.VSTS.Common.StackRank'=1999.5 } }
                        # Never ranked on a backlog - a real and common state.
                        [pscustomobject]@{ id=3; fields=[pscustomobject]@{ 'System.WorkItemType'='T'; 'System.State'='New'; 'System.TeamProject'='P' } }
                    )
                }
                elseif ($Path -match 'states') { @([pscustomobject]@{ name='New'; category='Proposed' }) }
            }
            Get-MsecAzureDevOpsWorkItem -Organization org -Project P
        }

        ($rows | Where-Object Id -eq 1).BacklogRank | Should -Be 1418086018
        ($rows | Where-Object Id -eq 2).BacklogRank | Should -Be 1999.5
        # 0 would sort an unranked item to the top as though someone had put it first.
        ($rows | Where-Object Id -eq 3).BacklogRank | Should -BeNullOrEmpty
    }

    It 'returns Tags as an array so -contains matches a multi-tag item' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                if ($Path -match 'wiql') { [pscustomobject]@{ workItems = @([pscustomobject]@{ id = 1 }) } }
                elseif ($Path -match 'workitemsbatch') {
                    @([pscustomobject]@{ id=1; fields=[pscustomobject]@{
                        'System.WorkItemType'='Task'; 'System.State'='To Do'; 'System.TeamProject'='Sec'
                        'System.Title'='Multi-tagged'; 'System.Tags'='Exchange; Internal IT' } })
                }
                elseif ($Path -match 'states') { @([pscustomobject]@{ name='To Do'; category='Proposed' }) }
            }
            Get-MsecAzureDevOpsWorkItem -Organization org -Project Sec
        }

        # Azure DevOps sends 'Exchange; Internal IT'. Keeping that string forced callers onto
        # -like '*Internal IT*', which also matches 'Internal IT Legacy', and made -contains
        # and -in return nothing at all for any item with more than one tag.
        $rows[0].Tags | Should -HaveCount 2
        $rows[0].Tags | Should -Contain 'Internal IT'
        @($rows | Where-Object Tags -contains 'Internal IT') | Should -HaveCount 1
    }

    It 'filters -OpenOnly by state CATEGORY, not by state name' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                if ($Path -match 'wiql') { [pscustomobject]@{ workItems = @([pscustomobject]@{id=1},[pscustomobject]@{id=2},[pscustomobject]@{id=3}) } }
                elseif ($Path -match 'workitemsbatch') {
                    @(
                        [pscustomobject]@{ id=1; fields=[pscustomobject]@{ 'System.WorkItemType'='Task'; 'System.State'='Committed'; 'System.TeamProject'='Sec'; 'System.Title'='In progress' } }
                        [pscustomobject]@{ id=2; fields=[pscustomobject]@{ 'System.WorkItemType'='Task'; 'System.State'='Done';      'System.TeamProject'='Sec'; 'System.Title'='Finished' } }
                        [pscustomobject]@{ id=3; fields=[pscustomobject]@{ 'System.WorkItemType'='Task'; 'System.State'='Removed';   'System.TeamProject'='Sec'; 'System.Title'='Dropped' } }
                    )
                }
                elseif ($Path -match 'states') {
                    # Scrum names - no state called 'Closed' or 'Active' anywhere.
                    @(
                        [pscustomobject]@{ name='Committed'; category='InProgress' }
                        [pscustomobject]@{ name='Done';      category='Completed' }
                        [pscustomobject]@{ name='Removed';   category='Removed' }
                    )
                }
            }
            Get-MsecAzureDevOpsWorkItem -Organization org -Project Sec -OpenOnly
        }

        @($rows).Count | Should -Be 1
        $rows[0].Title | Should -Be 'In progress'
    }

    It 'keeps an item whose state could not be classified under -OpenOnly' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                if ($Path -match 'wiql') { [pscustomobject]@{ workItems = @([pscustomobject]@{ id = 1 }) } }
                elseif ($Path -match 'workitemsbatch') {
                    @([pscustomobject]@{ id=1; fields=[pscustomobject]@{ 'System.WorkItemType'='Task'; 'System.State'='Mystery'; 'System.TeamProject'='Sec'; 'System.Title'='Unknown state' } })
                }
                elseif ($Path -match 'states') { throw 'Access denied' }
            }
            Get-MsecAzureDevOpsWorkItem -Organization org -Project Sec -OpenOnly -WarningAction SilentlyContinue
        }

        # Dropping it would shrink the very list someone uses to chase outstanding work.
        @($rows).Count | Should -Be 1
        $rows[0].StateCategory | Should -BeNullOrEmpty
    }

    It 'reports AgeDays as null rather than zero when the created date is missing' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                if ($Path -match 'wiql') { [pscustomobject]@{ workItems = @([pscustomobject]@{ id = 1 }) } }
                elseif ($Path -match 'workitemsbatch') {
                    @([pscustomobject]@{ id=1; fields=[pscustomobject]@{ 'System.WorkItemType'='Task'; 'System.State'='To Do'; 'System.TeamProject'='Sec'; 'System.Title'='No date' } })
                }
                elseif ($Path -match 'states') { @([pscustomobject]@{ name='To Do'; category='Proposed' }) }
            }
            Get-MsecAzureDevOpsWorkItem -Organization org -Project Sec
        }

        # 0 would read as "created today", which is the opposite of an unknown age.
        $rows[0].AgeDays | Should -BeNullOrEmpty
    }

    It 'doubles an apostrophe in a tag so the WIQL parses' {
        InModuleScope msec {
            $script:SeenQuery = $null
            Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                if ($Path -match 'wiql') { $script:SeenQuery = $Body.query; [pscustomobject]@{ workItems = @() } }
            }
            Get-MsecAzureDevOpsWorkItem -Organization org -Project Sec -Tag "Anton's" | Out-Null

            $script:SeenQuery | Should -Match "CONTAINS 'Anton''s'"
        }
    }

    It 'builds tag, area path and type filters into the query' {
        InModuleScope msec {
            $script:SeenQuery = $null
            Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                if ($Path -match 'wiql') { $script:SeenQuery = $Body.query; [pscustomobject]@{ workItems = @() } }
            }
            Get-MsecAzureDevOpsWorkItem -Organization org -Project Sec -Tag security -AreaPath 'Sec\Platform' -Type Task, Bug | Out-Null

            $script:SeenQuery | Should -Match "\[System\.Tags\] CONTAINS 'security'"
            # UNDER, not =, so child areas are included.
            $script:SeenQuery | Should -Match "\[System\.AreaPath\] UNDER 'Sec\\Platform'"
            $script:SeenQuery | Should -Match "\[System\.WorkItemType\] = 'Task' OR \[System\.WorkItemType\] = 'Bug'"
        }
    }

    It 'names both the organization and the project when Azure DevOps answers 404' {
        InModuleScope msec {
            Mock Invoke-MsecAzureDevOpsRequest -MockWith { throw 'Response status code does not indicate success: 404 (Not Found).' }
            # The same 404 covers a misspelled org, a misspelled project, and one the identity
            # cannot see - so the message must not send the reader to check only one of them.
            { Get-MsecAzureDevOpsWorkItem -Organization pcgsolution -Project Security } |
                Should -Throw "*organization 'pcgsolution' or project 'Security'*"
        }
    }

    It 'resolves a team to all its area paths, honouring includeChildren per path' {
        InModuleScope msec {
            $script:SeenQuery = $null
            Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                if ($Path -match 'teamfieldvalues') {
                    [pscustomobject]@{
                        field  = [pscustomobject]@{ referenceName = 'System.AreaPath' }
                        values = @(
                            [pscustomobject]@{ value = 'P\Basics\Security';  includeChildren = $true }
                            [pscustomobject]@{ value = 'P\Management - Sec'; includeChildren = $false }
                        )
                    }
                }
                elseif ($Path -match 'wiql') { $script:SeenQuery = $Body.query; [pscustomobject]@{ workItems = @() } }
            }
            Get-MsecAzureDevOpsWorkItem -Organization org -Project P -Team 'Sec team' | Out-Null

            # UNDER for everything would pull in sub-areas the team deliberately excluded;
            # = for everything would drop the sub-areas that are most of a backlog.
            $script:SeenQuery | Should -Match "\[System\.AreaPath\] UNDER 'P\\Basics\\Security'"
            $script:SeenQuery | Should -Match "\[System\.AreaPath\] = 'P\\Management - Sec'"
            # Both paths in one OR group, so a later AND cannot bind to only the last one.
            $script:SeenQuery | Should -Match "\(\[System\.AreaPath\].*OR.*\)"
        }
    }

    It 'requires -Project when -Team is given' {
        InModuleScope msec {
            Mock Invoke-MsecAzureDevOpsRequest -MockWith { }
            { Get-MsecAzureDevOpsWorkItem -Organization org -Team 'Sec team' } |
                Should -Throw '*-Team requires -Project*'
        }
    }

    It 'says team names are per-project and case-sensitive when the team cannot be read' {
        InModuleScope msec {
            Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                if ($Path -match 'teamfieldvalues') { throw 'Response status code does not indicate success: 404 (Not Found).' }
            }
            { Get-MsecAzureDevOpsWorkItem -Organization org -Project P -Team 'security and compliance' } |
                Should -Throw '*must match exactly*'
        }
    }

    It 'ORs several -AreaPath values rather than keeping only the last' {
        InModuleScope msec {
            $script:SeenQuery = $null
            Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                if ($Path -match 'wiql') { $script:SeenQuery = $Body.query; [pscustomobject]@{ workItems = @() } }
            }
            Get-MsecAzureDevOpsWorkItem -Organization org -Project P -AreaPath 'P\One', 'P\Two' | Out-Null

            $script:SeenQuery | Should -Match "UNDER 'P\\One' OR \[System\.AreaPath\] UNDER 'P\\Two'"
        }
    }

    It 'narrows server-side with -ChangedWithinDays' {
        InModuleScope msec {
            $script:SeenQuery = $null
            Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                if ($Path -match 'wiql') { $script:SeenQuery = $Body.query; [pscustomobject]@{ workItems = @() } }
            }
            Get-MsecAzureDevOpsWorkItem -Organization org -Project Sec -ChangedWithinDays 30 | Out-Null

            # @Today is resolved by Azure DevOps, not locally, so the clause must go to the
            # server verbatim rather than being turned into a date on this machine.
            $script:SeenQuery | Should -Match '\[System\.ChangedDate\] >= @Today - 30'
        }
    }

    It 'explains that -MaxItems cannot help when the 20,000 limit is hit' {
        InModuleScope msec {
            Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                throw 'VS402337: The number of work items returned exceeds the size limit of 20000.'
            }
            # The limit is applied before any result is returned, so a client-side cap is no
            # help - saying "raise -MaxItems" would send the reader round in a circle.
            { Get-MsecAzureDevOpsWorkItem -Organization org -Project Big } |
                Should -Throw '*-MaxItems cannot help here*'
            { Get-MsecAzureDevOpsWorkItem -Organization org -Project Big } |
                Should -Throw '*-ChangedWithinDays*'
        }
    }

    It 'warns that the answer is truncated when more items match than -MaxItems' {
        InModuleScope msec {
            Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                if ($Path -match 'wiql') { [pscustomobject]@{ workItems = @(1..5 | ForEach-Object { [pscustomobject]@{ id = $_ } }) } }
                elseif ($Path -match 'workitemsbatch') { @() }
            }
            Get-MsecAzureDevOpsWorkItem -Organization org -Project Sec -MaxItems 2 -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            $script:captured = $w
        }
        $captured = InModuleScope msec { $script:captured }

        # Silent truncation of a backlog report is how a count gets quoted as complete.
        "$captured" | Should -Match 'truncated answer'
    }
}
