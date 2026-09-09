#Requires -Module Pester
#
# Tests for Get-MsecEntraDisabledUser.
#
# The list of disabled users is the easy half. The half worth testing is "how long", because
# Entra stores no disabledDateTime and the answer has three distinct shapes:
#
#   * the disable event is inside the audit window  -> exact DisabledSince / DisabledDays
#   * it has aged out                               -> a bracket, DisabledAtLeastDays and
#                                                      DisabledAtMostDays (from last sign-in)
#   * the audit log itself is unreadable            -> the user list still comes back, with
#                                                      the timing columns blank and a warning
#
# Also covered: an account disabled, re-enabled and disabled again must report the LAST
# disable, and a tenant without Entra ID P1 must degrade rather than fail.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEntraDisabledUser' {
    BeforeEach {
        InModuleScope Msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId = 'tenant'; ClientId = 'client'; KeyVaultName = 'kv'
                KeyName = 'msec-app'; ThumbprintBytes = $Thumb; Tokens = @{}
            }
        }
    }

    It 'filters on accountEnabled eq false and projects the flat row' {
        $result = InModuleScope Msec {
            $captured = @{}
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*/users*' } -MockWith {
                $captured['UserPath'] = $Path
                [pscustomobject]@{
                    id = 'u1'; displayName = 'Ex Employee'; userPrincipalName = 'ex@contoso.com'
                    userType = 'Member'; accountEnabled = $false; department = 'Sales'
                    jobTitle = 'Rep'; onPremisesSyncEnabled = $false
                    createdDateTime = '2020-01-01T00:00:00Z'
                    assignedLicenses = @([pscustomobject]@{ skuId = 'a' }, [pscustomobject]@{ skuId = 'b' })
                }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*directoryAudits*' } -MockWith { }

            [pscustomobject]@{ Rows = @(Get-MsecEntraDisabledUser); Captured = $captured }
        }

        [uri]::UnescapeDataString($result.Captured['UserPath']) | Should -BeLike '*accountEnabled eq false*'

        $row = $result.Rows[0]
        $row.UserPrincipalName | Should -Be 'ex@contoso.com'
        $row.Department        | Should -Be 'Sales'
        # A disabled account still holding licences is the actionable finding.
        $row.LicenseCount      | Should -Be 2
        $row.PSObject.TypeNames | Should -Contain 'MsecEntraDisabledUser'
    }

    It 'reports an exact date when the disable event is inside the audit window' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*/users*' } -MockWith {
                [pscustomobject]@{ id = 'u1'; userPrincipalName = 'ex@contoso.com'; accountEnabled = $false }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*directoryAudits*' } -MockWith {
                [pscustomobject]@{
                    activityDateTime = ([DateTime]::UtcNow.AddDays(-5)).ToString('o')
                    initiatedBy = [pscustomobject]@{ user = [pscustomobject]@{ userPrincipalName = 'admin@contoso.com' } }
                    targetResources = @(
                        [pscustomobject]@{
                            id = 'u1'
                            # Graph sends these as JSON-ish text, not booleans.
                            modifiedProperties = @([pscustomobject]@{
                                displayName = 'AccountEnabled'; oldValue = '[true]'; newValue = '[false]'
                            })
                        }
                    )
                }
            }
            @(Get-MsecEntraDisabledUser)[0]
        }

        $row.DisabledDays        | Should -Be 5
        $row.DisabledBy          | Should -Be 'admin@contoso.com'
        $row.DisabledSource      | Should -Be 'AuditLog'
        $row.DisabledSince       | Should -Not -BeNullOrEmpty
        # Exact answer, so no bracket.
        $row.DisabledAtLeastDays | Should -BeNullOrEmpty
        $row.DisabledAtMostDays  | Should -BeNullOrEmpty
    }

    It 'brackets the answer when the event has aged out of the log' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*/users*' } -MockWith {
                [pscustomobject]@{
                    id = 'u1'; userPrincipalName = 'old@contoso.com'; accountEnabled = $false
                    signInActivity = [pscustomobject]@{
                        lastSuccessfulSignInDateTime = ([DateTime]::UtcNow.AddDays(-400)).ToString('o')
                    }
                }
            }
            # Nothing in the window.
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*directoryAudits*' } -MockWith { }

            @(Get-MsecEntraDisabledUser -Days 30)[0]
        }

        $row.DisabledSince       | Should -BeNullOrEmpty
        $row.DisabledDays        | Should -BeNullOrEmpty
        # Nothing found in 30 days, so it happened before that...
        $row.DisabledAtLeastDays | Should -Be 30
        # ...and it cannot predate the last successful sign-in, because a disabled account
        # cannot sign in.
        $row.DisabledAtMostDays  | Should -Be 400
        $row.DisabledSource      | Should -BeLike '*Beyond audit retention*'
    }

    It 'reports three distinct last-touched signals, since Graph has no lastModifiedDateTime' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*/users*' } -MockWith {
                [pscustomobject]@{
                    id = 'u1'; userPrincipalName = 'ex@contoso.com'; accountEnabled = $false
                    lastPasswordChangeDateTime = '2024-03-01T09:00:00Z'
                    onPremisesLastSyncDateTime = '2026-08-20T02:00:00Z'
                    onPremisesSyncEnabled      = $true
                }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*directoryAudits*' } -MockWith {
                # A department change - NOT an AccountEnabled change - so it must count as a
                # directory update while leaving the disable columns alone.
                [pscustomobject]@{
                    activityDateTime = ([DateTime]::UtcNow.AddDays(-2)).ToString('o')
                    targetResources = @([pscustomobject]@{
                        id = 'u1'
                        modifiedProperties = @(
                            [pscustomobject]@{ displayName = 'Department'; newValue = '"Ops"' }
                            [pscustomobject]@{ displayName = 'JobTitle';   newValue = '"Lead"' }
                        )
                    })
                }
            }
            @(Get-MsecEntraDisabledUser)[0]
        }

        $row.LastDirectoryChange     | Should -Not -BeNullOrEmpty
        $row.LastDirectoryChangeWhat | Should -Be 'Department, JobTitle'
        $row.LastPasswordChange      | Should -Be ([datetime]'2024-03-01T09:00:00Z')
        $row.OnPremisesLastSync      | Should -Be ([datetime]'2026-08-20T02:00:00Z')
        # A non-AccountEnabled edit is an update, not a disable.
        $row.DisabledSince           | Should -BeNullOrEmpty
    }

    It 'leaves LastDirectoryChange null when nothing touched the object in the window' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*/users*' } -MockWith {
                [pscustomobject]@{
                    id = 'u1'; userPrincipalName = 'old@contoso.com'; accountEnabled = $false
                    lastPasswordChangeDateTime = '2019-01-01T00:00:00Z'
                }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*directoryAudits*' } -MockWith { }
            @(Get-MsecEntraDisabledUser)[0]
        }

        # Null means "not in the audit window", not "never" - which is why the unbounded
        # LastPasswordChange is carried alongside it.
        $row.LastDirectoryChange | Should -BeNullOrEmpty
        $row.LastPasswordChange  | Should -Be ([datetime]'2019-01-01T00:00:00Z')
    }

    It 'bounds only on a SUCCESSFUL sign-in, never on a failed attempt' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*/users*' } -MockWith {
                [pscustomobject]@{
                    id = 'u1'; userPrincipalName = 'sprayed@contoso.com'; accountEnabled = $false
                    signInActivity = [pscustomobject]@{
                        # Somebody tried the account last week - an ex-employee, a stale
                        # client, a password spray. It is disabled, so it did not work.
                        lastSignInDateTime           = ([DateTime]::UtcNow.AddDays(-7)).ToString('o')
                        # The last time it actually worked was three years ago.
                        lastSuccessfulSignInDateTime = ([DateTime]::UtcNow.AddDays(-1100)).ToString('o')
                    }
                }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*directoryAudits*' } -MockWith { }
            @(Get-MsecEntraDisabledUser -Days 30)[0]
        }

        # Bounding on the attempt would claim "disabled at most 7 days" for an account that
        # has been off for years - wrong, and confidently so.
        $row.DisabledAtMostDays    | Should -Be 1100
        $row.DisabledAtLeastDays   | Should -Be 30
        # Both timestamps are still surfaced; only the BOUND is restricted.
        $row.LastInteractiveSignIn | Should -Not -BeNullOrEmpty
        $row.LastSignIn            | Should -Be $row.LastInteractiveSignIn   # newest of any kind
    }

    It 'leaves the upper bound blank when only an unsuccessful sign-in is recorded' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*/users*' } -MockWith {
                [pscustomobject]@{
                    id = 'u1'; userPrincipalName = 'ex@contoso.com'; accountEnabled = $false
                    signInActivity = [pscustomobject]@{
                        lastSignInDateTime = ([DateTime]::UtcNow.AddDays(-9)).ToString('o')
                    }
                }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*directoryAudits*' } -MockWith { }
            @(Get-MsecEntraDisabledUser)[0]
        }

        # No proof the account ever worked, so no bound - blank rather than guessed.
        $row.DisabledAtMostDays  | Should -BeNullOrEmpty
        $row.DisabledAtLeastDays | Should -Be 30
    }

    It 'surfaces non-interactive sign-in, which is how a service account looks alive' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*/users*' } -MockWith {
                [pscustomobject]@{
                    id = 'u1'; userPrincipalName = 'svc@contoso.com'; accountEnabled = $false
                    signInActivity = [pscustomobject]@{
                        lastSignInDateTime               = ([DateTime]::UtcNow.AddDays(-900)).ToString('o')
                        lastNonInteractiveSignInDateTime = ([DateTime]::UtcNow.AddDays(-3)).ToString('o')
                    }
                }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*directoryAudits*' } -MockWith { }
            @(Get-MsecEntraDisabledUser)[0]
        }

        # Interactively it looks dead for years; non-interactively it was busy three days ago.
        $row.LastNonInteractiveSignIn | Should -Not -BeNullOrEmpty
        $row.LastSignIn | Should -Be $row.LastNonInteractiveSignIn
    }

    It 'reports the MOST RECENT disable when an account was toggled off, on, and off again' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*/users*' } -MockWith {
                [pscustomobject]@{ id = 'u1'; userPrincipalName = 'toggled@contoso.com'; accountEnabled = $false }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*directoryAudits*' } -MockWith {
                foreach ($daysAgo in 20, 3, 12) {
                    [pscustomobject]@{
                        activityDateTime = ([DateTime]::UtcNow.AddDays(-$daysAgo)).ToString('o')
                        initiatedBy = [pscustomobject]@{ user = [pscustomobject]@{ userPrincipalName = "admin$daysAgo@contoso.com" } }
                        targetResources = @([pscustomobject]@{
                            id = 'u1'
                            modifiedProperties = @([pscustomobject]@{ displayName = 'AccountEnabled'; newValue = '[false]' })
                        })
                    }
                }
            }
            @(Get-MsecEntraDisabledUser)[0]
        }

        # The disable currently in force is the newest one, not the first seen in the page.
        $row.DisabledDays | Should -Be 3
        $row.DisabledBy   | Should -Be 'admin3@contoso.com'
    }

    It 'ignores an Update user event that changed something other than AccountEnabled' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*/users*' } -MockWith {
                [pscustomobject]@{ id = 'u1'; userPrincipalName = 'ex@contoso.com'; accountEnabled = $false }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*directoryAudits*' } -MockWith {
                [pscustomobject]@{
                    activityDateTime = ([DateTime]::UtcNow.AddDays(-2)).ToString('o')
                    targetResources = @([pscustomobject]@{
                        id = 'u1'
                        modifiedProperties = @([pscustomobject]@{ displayName = 'Department'; newValue = '"Ops"' })
                    })
                }
                # ...and an AccountEnabled event that turned the account ON, which is not a
                # disable and must not be read as one.
                [pscustomobject]@{
                    activityDateTime = ([DateTime]::UtcNow.AddDays(-1)).ToString('o')
                    targetResources = @([pscustomobject]@{
                        id = 'u1'
                        modifiedProperties = @([pscustomobject]@{ displayName = 'AccountEnabled'; oldValue = '[false]'; newValue = '[true]' })
                    })
                }
            }
            @(Get-MsecEntraDisabledUser)[0]
        }

        $row.DisabledSince | Should -BeNullOrEmpty
        $row.DisabledSource | Should -BeLike '*Beyond audit retention*'
    }

    It 'still returns the user list when the audit log cannot be read' {
        $result = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*/users*' } -MockWith {
                [pscustomobject]@{ id = 'u1'; userPrincipalName = 'ex@contoso.com'; accountEnabled = $false }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*directoryAudits*' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }

            $rows = @(Get-MsecEntraDisabledUser -WarningVariable w -WarningAction SilentlyContinue)
            [pscustomobject]@{ Rows = $rows; Warnings = $w }
        }

        # The list is the point; the dates are the bonus.
        $result.Rows.Count | Should -Be 1
        $result.Rows[0].UserPrincipalName | Should -Be 'ex@contoso.com'
        $result.Rows[0].DisabledSince | Should -BeNullOrEmpty
        ($result.Warnings -join ' ') | Should -Match 'audit log'
    }

    It 'retries without signInActivity when the tenant has no premium licence' {
        $result = InModuleScope Msec {
            $paths = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*/users*' } -MockWith {
                $paths.Add($Path)
                if ($Path -match 'signInActivity') {
                    throw 'Neither tenant is B2C or tenant doesn''t have premium license'
                }
                [pscustomobject]@{ id = 'u1'; userPrincipalName = 'ex@contoso.com'; accountEnabled = $false }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*directoryAudits*' } -MockWith { }

            $rows = @(Get-MsecEntraDisabledUser -WarningVariable w -WarningAction SilentlyContinue)
            [pscustomobject]@{ Rows = $rows; Paths = $paths; Warnings = $w }
        }

        @($result.Paths).Count | Should -Be 2                       # premium attempt, then without
        $result.Paths[0] | Should -BeLike '*signInActivity*'
        $result.Paths[1] | Should -Not -BeLike '*signInActivity*'
        $result.Rows.Count | Should -Be 1                            # and the list still arrives
        ($result.Warnings -join ' ') | Should -Match 'signInActivity'
    }

    It 'scopes to guests when asked' {
        $path = InModuleScope Msec {
            $captured = @{}
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*/users*' } -MockWith {
                $captured['Path'] = $Path
                [pscustomobject]@{ id = 'g1'; userPrincipalName = 'guest@partner.com'; accountEnabled = $false; userType = 'Guest' }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -like '*directoryAudits*' } -MockWith { }
            Get-MsecEntraDisabledUser -UserType Guest | Out-Null
            $captured['Path']
        }

        [uri]::UnescapeDataString($path) | Should -BeLike "*userType eq 'Guest'*"
    }

    It 'throws a clear error when not connected' {
        InModuleScope Msec {
            $script:MsecSession = $null
            { Get-MsecEntraDisabledUser } | Should -Throw '*Connect-Msec*'
        }
    }
}
