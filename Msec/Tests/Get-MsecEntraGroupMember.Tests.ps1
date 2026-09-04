#Requires -Module Pester
#
# Tests for Get-MsecEntraGroupMember.
#
# The behaviour worth pinning down is where a group listing is easy to get quietly wrong:
#
#   * a PIM-governed group has ELIGIBLE members who appear on NO /members endpoint. Omitting
#     them makes the group read as empty while a queue of people is one activation away -
#     wrong in the most dangerous direction.
#   * an empty group and a mistyped name must not both be silence
#   * members are not only users; filtering to users would drop the service principal somebody
#     added to an access group
#   * Entra display names are NOT unique, so a name matching several groups must return all of
#     them rather than picking one

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEntraGroupMember' {
    BeforeEach {
        InModuleScope Msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId = 'tenant'; ClientId = 'client'; KeyVaultName = 'kv-test'
                KeyName = 'msec-app'; ThumbprintBytes = $Thumb; Tokens = @{}
            }

            # Catch-all, so an unmocked path fails the test instead of reaching the network.
            # Defined first, so the specific mocks in each It take precedence.
            Mock Invoke-MsecGraphRequest -MockWith {
                throw "unmocked Graph path in test: $Path"
            }
        }
    }

    It 'returns one row per group and member, with the group name on every row' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/groups\?' } -MockWith {
                if ($Path -match 'sg-admins') {
                    [pscustomobject]@{ id = 'g1'; displayName = 'sg-admins'; securityEnabled = $true; isAssignableToRole = $true }
                } else {
                    [pscustomobject]@{ id = 'g2'; displayName = 'sg-devops'; securityEnabled = $true }
                }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/groups/g1/members' } -MockWith {
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'; displayName = 'Ada'; userPrincipalName = 'ada@x.com'; accountEnabled = $true; userType = 'Member' }
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u2'; displayName = 'Bob'; userPrincipalName = 'bob@x.com'; accountEnabled = $true; userType = 'Guest' }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/groups/g2/members' } -MockWith {
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u3'; displayName = 'Cleo'; userPrincipalName = 'cleo@x.com'; accountEnabled = $true }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'eligibilityScheduleInstances' } -MockWith { @() }

            Get-MsecEntraGroupMember -Name 'sg-admins', 'sg-devops'
        }

        @($rows).Count | Should -Be 3

        # The group name rides on every row - that is what makes several groups one table.
        @($rows | Where-Object GroupName -eq 'sg-admins').Count | Should -Be 2
        @($rows | Where-Object GroupName -eq 'sg-devops').Count | Should -Be 1

        $ada = $rows | Where-Object MemberName -eq 'Ada'
        $ada.MemberUserPrincipalName | Should -Be 'ada@x.com'
        $ada.MemberType              | Should -Be 'user'
        $ada.MembershipType          | Should -Be 'Active'
        $ada.GroupType               | Should -Be 'RoleAssignable'
        $ada.IsRoleAssignable        | Should -BeTrue

        ($rows | Where-Object MemberName -eq 'Bob').UserType | Should -Be 'Guest'
    }

    It 'includes PIM-eligible members, which appear on no members endpoint' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/groups\?' } -MockWith {
                [pscustomobject]@{ id = 'g1'; displayName = 'sg-pim'; securityEnabled = $true }
            }
            # Nobody is an ACTUAL member - the whole membership is eligible.
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/members' } -MockWith { @() }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'eligibilityScheduleInstances' } -MockWith {
                [pscustomobject]@{ accessId = 'member'; principal = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u9'; displayName = 'Eve'; userPrincipalName = 'eve@x.com' } }
                # An OWNER does not hold what the group grants - a different finding, and
                # counting them would overstate the membership.
                [pscustomobject]@{ accessId = 'owner';  principal = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u10'; displayName = 'Owner' } }
            }

            Get-MsecEntraGroupMember -Name 'sg-pim'
        }

        # Without the eligibility read this group reads as EMPTY while someone is one
        # activation away from whatever it grants.
        @($rows).Count        | Should -Be 1
        $rows.MemberName      | Should -Be 'Eve'
        $rows.MembershipType  | Should -Be 'Eligible'
        # A real member, so the empty-group placeholder must NOT be emitted alongside it.
        $rows.MemberType      | Should -Be 'user'
    }

    It 'distinguishes an empty group from a name that matched nothing' {
        $warnings = @()
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'sg-empty' } -MockWith {
                [pscustomobject]@{ id = 'g1'; displayName = 'sg-empty'; securityEnabled = $true }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'sg-typo' } -MockWith { @() }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/members' } -MockWith { @() }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'eligibilityScheduleInstances' } -MockWith { @() }

            Get-MsecEntraGroupMember -Name 'sg-empty', 'sg-typo'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        # The empty group is accounted for with a row...
        @($rows).Count   | Should -Be 1
        $rows.GroupName  | Should -Be 'sg-empty'
        $rows.MemberType | Should -Be 'None'
        $rows.MemberName | Should -BeNullOrEmpty

        # ...and the typo is named, rather than both being silence.
        ($warnings -join ' ') | Should -Match "No group is named 'sg-typo'"
    }

    It 'keeps every group when a display name is ambiguous' {
        $warnings = @()
        $rows = InModuleScope Msec {
            # Entra display names are not unique.
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/groups\?' } -MockWith {
                [pscustomobject]@{ id = 'g1'; displayName = 'sg-dup'; securityEnabled = $true }
                [pscustomobject]@{ id = 'g2'; displayName = 'sg-dup'; securityEnabled = $true }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/groups/g1/members' } -MockWith {
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'; displayName = 'Ada' }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/groups/g2/members' } -MockWith {
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u2'; displayName = 'Bob' }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'eligibilityScheduleInstances' } -MockWith { @() }

            Get-MsecEntraGroupMember -Name 'sg-dup'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        @($rows).Count | Should -Be 2
        @($rows | ForEach-Object { $_.GroupId } | Sort-Object) | Should -Be @('g1', 'g2')
        ($warnings -join ' ') | Should -Match '2 groups are named'
    }

    It 'reports every member type, not only users' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/groups\?' } -MockWith {
                [pscustomobject]@{ id = 'g1'; displayName = 'sg-mixed'; securityEnabled = $true }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/members' } -MockWith {
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'; displayName = 'Ada' }
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.servicePrincipal'; id = 'sp1'; displayName = 'ci-runner' }
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; id = 'g2'; displayName = 'sg-nested' }
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.device'; id = 'd1'; displayName = 'LAPTOP-01' }
                # A response that omits @odata.type: genuinely unknown, and calling it 'user'
                # would mislabel whatever it actually is.
                [pscustomobject]@{ id = 'x1'; displayName = 'Mystery' }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'eligibilityScheduleInstances' } -MockWith { @() }

            Get-MsecEntraGroupMember -Name 'sg-mixed'
        }

        @($rows).Count | Should -Be 5
        ($rows | Where-Object MemberName -eq 'ci-runner').MemberType | Should -Be 'servicePrincipal'
        ($rows | Where-Object MemberName -eq 'sg-nested').MemberType | Should -Be 'group'
        ($rows | Where-Object MemberName -eq 'LAPTOP-01').MemberType | Should -Be 'device'
        ($rows | Where-Object MemberName -eq 'Mystery').MemberType   | Should -Be 'unknown'
    }

    It 'marks a group whose membership could not be read, rather than reporting it empty' {
        $warnings = @()
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/groups\?' } -MockWith {
                [pscustomobject]@{ id = 'g1'; displayName = 'sg-denied'; securityEnabled = $true }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/members' } -MockWith { throw 'Forbidden' }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'eligibilityScheduleInstances' } -MockWith { @() }

            Get-MsecEntraGroupMember -Name 'sg-denied'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        # 'Unreadable', not 'None' - a group that could not be read must never look clean.
        @($rows).Count   | Should -Be 1
        $rows.MemberType | Should -Be 'Unreadable'
        ($warnings -join ' ') | Should -Match 'Group\.Read\.All'
    }


    It 'expands nested groups instead of listing them, at any depth' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/groups\?' } -MockWith {
                [pscustomobject]@{ id = 'g1'; displayName = 'sg-top'; securityEnabled = $true }
            }
            # /transitiveMembers returns the nested groups AS WELL AS the people inside them.
            # Listing what it returns verbatim shows a group as a "member" and again as
            # everyone in it, which is the thing -Recurse exists to avoid.
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'transitiveMembers' } -MockWith {
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; id = 'g2'; displayName = 'sg-nested' }
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; id = 'g3'; displayName = 'sg-deeper' }
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'; displayName = 'Ada' }
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u2'; displayName = 'Deep' }
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.servicePrincipal'; id = 'sp1'; displayName = 'ci-runner' }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'eligibilityScheduleInstances' } -MockWith { @() }

            Get-MsecEntraGroupMember -Name 'sg-top' -Recurse
        }

        # People and service principals, no groups.
        @($rows).Count | Should -Be 3
        @($rows | ForEach-Object { $_.MemberName } | Sort-Object) | Should -Be @('Ada', 'ci-runner', 'Deep')
        @($rows | Where-Object MemberType -eq 'group').Count | Should -Be 0
        # ...and the nested group names appear nowhere at all.
        @($rows | ForEach-Object { $_.MemberName }) | Should -Not -Contain 'sg-nested'
        @($rows | ForEach-Object { $_.MemberName }) | Should -Not -Contain 'sg-deeper'
    }

    It 'reads PIM-eligible members of nested groups too when recursing' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/groups\?' } -MockWith {
                [pscustomobject]@{ id = 'g1'; displayName = 'sg-top'; securityEnabled = $true }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'transitiveMembers' } -MockWith {
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; id = 'g2'; displayName = 'sg-pim-nested' }
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'; displayName = 'Ada' }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'eligibilityScheduleInstances' } -MockWith { @() }
            # The nested group is PIM-governed, so /transitiveMembers finds nobody in it -
            # flattening only follows ACTUAL membership. Defined AFTER the catch-all: Pester
            # takes the last matching mock.
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'eligibilityScheduleInstances' -and $Path -match 'g2' } -MockWith {
                [pscustomobject]@{ accessId = 'member'; principal = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u9'; displayName = 'Eve' } }
            }

            Get-MsecEntraGroupMember -Name 'sg-top' -Recurse
        }

        # Without asking each nested group, Eve is invisible and the recursion is LESS complete
        # than not recursing at all would have been.
        @($rows | ForEach-Object { $_.MemberName } | Sort-Object) | Should -Be @('Ada', 'Eve')
        ($rows | Where-Object MemberName -eq 'Eve').MembershipType | Should -Be 'Eligible'
    }

    It 'counts a person reachable by two paths once, but keeps Active and Eligible apart' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/groups\?' } -MockWith {
                [pscustomobject]@{ id = 'g1'; displayName = 'sg-top'; securityEnabled = $true }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'transitiveMembers' } -MockWith {
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; id = 'g2'; displayName = 'sg-a' }
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; id = 'g3'; displayName = 'sg-b' }
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'; displayName = 'Ada' }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'eligibilityScheduleInstances' } -MockWith { @() }
            # Ada is eligible through BOTH nested groups, and is already an active member.
            # Defined AFTER the catch-all: Pester takes the last matching mock.
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'eligibilityScheduleInstances' -and ($Path -match 'g2' -or $Path -match 'g3') } -MockWith {
                [pscustomobject]@{ accessId = 'member'; principal = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u1'; displayName = 'Ada' } }
            }

            Get-MsecEntraGroupMember -Name 'sg-top' -Recurse
        }

        # Two rows, not three: the duplicate eligible path collapses...
        @($rows).Count | Should -Be 2
        @($rows | Where-Object MembershipType -eq 'Eligible').Count | Should -Be 1
        # ...but standing membership AND an eligible assignment is a real state, kept visible.
        @($rows | Where-Object MembershipType -eq 'Active').Count | Should -Be 1
    }

    It 'still lists a nested group as a member without -Recurse' {
        InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/groups\?' } -MockWith {
                [pscustomobject]@{ id = 'g1'; displayName = 'sg-top'; securityEnabled = $true }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/members' -and $Path -notmatch 'transitive' } -MockWith {
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; id = 'g2'; displayName = 'sg-nested' }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'eligibilityScheduleInstances' } -MockWith { @() }

            # The portal's view, unchanged.
            $row = Get-MsecEntraGroupMember -Name 'sg-top'
            $row.MemberName | Should -Be 'sg-nested'
            $row.MemberType | Should -Be 'group'
        }
    }
    It 'requires something to look up' {
        InModuleScope Msec {
            { Get-MsecEntraGroupMember } | Should -Throw '*at least one*'
        }
    }

    It 'throws a clear error when not connected' {
        InModuleScope Msec {
            $script:MsecSession = $null
            { Get-MsecEntraGroupMember -Name 'x' } | Should -Throw '*Connect-Msec*'
        }
    }
}