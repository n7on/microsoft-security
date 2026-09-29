#Requires -Module Pester
#
# Tests for Get-MsecIntuneCompliancePolicy. Verifies Platform is derived from
# @odata.type, AssignmentCount comes from $expand=assignments, and Status is
# omitted when -IncludeStatus is not passed.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecIntuneCompliancePolicy' {
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
        }
    }

    It 'lists compliance policies, deriving Platform from @odata.type and AssignmentCount from $expand' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceCompliancePolicies\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'cp-1'; displayName = 'Win10 Compliance'
                        '@odata.type' = '#microsoft.graph.windows10CompliancePolicy'
                        assignments = @(@{ target = @{ groupId = 'g-1' } })
                    }
                    [pscustomobject]@{
                        id = 'cp-2'; displayName = 'iOS Compliance'
                        '@odata.type' = '#microsoft.graph.iosCompliancePolicy'
                        assignments = @()
                    }
                ) }
            }

            Get-MsecIntuneCompliancePolicy
        }

        $rows.Count | Should -Be 2
        ($rows | Where-Object Id -eq 'cp-1').Platform        | Should -Be 'windows10'
        ($rows | Where-Object Id -eq 'cp-1').Type            | Should -Be 'windows10CompliancePolicy'
        ($rows | Where-Object Id -eq 'cp-1').AssignmentCount | Should -Be 1
        ($rows | Where-Object Id -eq 'cp-2').Platform        | Should -Be 'iOS'
        ($rows | Where-Object Id -eq 'cp-2').AssignmentCount | Should -Be 0

        # No -IncludeStatus -> no Status column at all (not even for AssignmentCount=0 rows).
        ($rows | Where-Object Id -eq 'cp-1').PSObject.Properties.Name | Should -Not -Contain 'Status'
        ($rows | Where-Object Id -eq 'cp-2').PSObject.Properties.Name | Should -Not -Contain 'Status'
    }
}

Describe 'A compliance policy that checks nothing' {
    BeforeEach {
        InModuleScope Msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId = 'tenant'; ClientId = 'client'; KeyVaultName = 'kv-test'
                KeyName = 'msec-app'; ThumbprintBytes = $Thumb; Tokens = @{}
            }
        }
    }

    It 'reports ChecksNothing for an assigned policy that enforces nothing' {
        # Measured live: a macOS baseline assigned to all licensed users since 2021, with every
        # setting empty or false, reported 17 of 19 devices compliant - including two on an
        # unsupported major version. Name, platform and assignment count all looked healthy.
        $rows = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceCompliancePolicies\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'cp-empty'; displayName = 'Baseline macOS'
                        '@odata.type' = '#microsoft.graph.macOSCompliancePolicy'
                        assignments = @(@{ target = @{ groupId = 'g-1' } })
                        osMinimumVersion = ''
                        passwordRequired = $false
                        storageRequireEncryption = $false
                        firewallEnabled = $false
                        passwordRequiredType = 'deviceDefault'
                        passwordMinimumLength = 0
                    }
                    [pscustomobject]@{
                        id = 'cp-real'; displayName = 'LAB macOS'
                        '@odata.type' = '#microsoft.graph.macOSCompliancePolicy'
                        assignments = @()
                        osMinimumVersion = '14.6.1'
                        passwordRequired = $true
                        storageRequireEncryption = $true
                    }
                )}
            }
            @(Get-MsecIntuneCompliancePolicy)
        }

        $empty = $rows | Where-Object DisplayName -eq 'Baseline macOS'
        $empty.ChecksNothing        | Should -BeTrue
        $empty.ConfiguredCheckCount | Should -Be 0
        # Assigned and enforcing nothing - the combination that looks fine in a policy list.
        $empty.AssignmentCount      | Should -Be 1

        $real = $rows | Where-Object DisplayName -eq 'LAB macOS'
        $real.ChecksNothing         | Should -BeFalse
        $real.ConfiguredCheckCount  | Should -Be 3
        $real.OsMinimumVersion      | Should -Be '14.6.1'
    }

    It 'does not count a false boolean, a do-nothing sentinel, or a zero threshold' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceCompliancePolicies\?' } -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{
                    id = 'cp-1'; displayName = 'Mixed'
                    '@odata.type' = '#microsoft.graph.windows10CompliancePolicy'
                    assignments = @()
                    # None of these enforce anything...
                    passwordRequired            = $false
                    passwordRequiredType        = 'deviceDefault'
                    defenderEnabled             = 'unavailable'
                    passwordMinimumLength       = 0
                    osMinimumVersion            = ''
                    # ...only this one does.
                    bitLockerEnabled            = $true
                })}
            }
            @(Get-MsecIntuneCompliancePolicy)
        }

        # False means "not required", not "required to be false".
        $row.ConfiguredCheckCount | Should -Be 1
        $row.ConfiguredChecks     | Should -Contain 'bitLockerEnabled'
        $row.ConfiguredChecks     | Should -Not -Contain 'passwordRequired'
        $row.ConfiguredChecks     | Should -Not -Contain 'passwordRequiredType'
        $row.ConfiguredChecks     | Should -Not -Contain 'defenderEnabled'
        $row.ConfiguredChecks     | Should -Not -Contain 'passwordMinimumLength'
    }

    It 'does not count identity or timestamps as compliance settings' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceCompliancePolicies\?' } -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{
                    id = 'cp-1'; displayName = 'Named'; description = 'has text'; version = 5
                    createdDateTime = '2021-08-17T14:41:09Z'
                    '@odata.type' = '#microsoft.graph.macOSCompliancePolicy'
                    assignments = @(@{ target = @{ groupId = 'g-1' } })
                    scheduledActionsForRule = @(@{ ruleName = 'PasswordRequired' })
                })}
            }
            @(Get-MsecIntuneCompliancePolicy)
        }

        # An id and a display name are not controls. scheduledActionsForRule says what happens
        # AFTER a failure, not whether anything is checked.
        $row.ChecksNothing | Should -BeTrue
    }

    It 'attaches the raw settings only when asked' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceCompliancePolicies\?' } -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{
                    id = 'cp-1'; displayName = 'P'
                    '@odata.type' = '#microsoft.graph.macOSCompliancePolicy'
                    assignments = @(); osMinimumVersion = '14.0'
                })}
            }
            ,@(Get-MsecIntuneCompliancePolicy)
            ,@(Get-MsecIntuneCompliancePolicy -IncludeSettings)
        }

        $rows[0][0].PSObject.Properties.Name | Should -Not -Contain 'Settings'
        $rows[1][0].Settings['osMinimumVersion'] | Should -Be '14.0'
    }
}
