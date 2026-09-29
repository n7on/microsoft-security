#Requires -Module Pester
#
# Tests for the Get-MsecPurview* commands.
#
# The traps these pin are all of one family - a value that means "no answer" must never render
# as a measurement, and a setting that exists must never be read off a property that does not:
#
#   Get-Label HAS NO EncryptionEnabled PROPERTY. Asking for one returns empty on every label,
#   which reads as "nothing encrypts anything". The real settings are JSON in LabelActions.
#
#   THE disabled FLAG IS THE STRING 'true'/'false', and [bool]'false' is $true in PowerShell.
#   A truthiness test marks every configured action as switched off.
#
#   'All' IS AN ORDINARY MEMBER of a DLP location list, not a flag, so an estate-wide policy and
#   a single site called All are indistinguishable without looking.
#
#   A POLICY'S Mode IS NOT ITS Enabled FLAG. Only 'Enable' stops anything.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop

    # The Security & Compliance cmdlets do not exist without a live session, so they are stubbed
    # globally here purely so Pester has something to mock.
    function global:Get-ConnectionInformation { }
    function global:Get-DlpCompliancePolicy { }
    function global:Get-DlpComplianceRule { }
    function global:Get-Label { }
    function global:Get-LabelPolicy { }
    function global:Get-ComplianceTag { }
    function global:Get-RetentionCompliancePolicy { }
    function global:Disconnect-ExchangeOnline { param($ConnectionId, $Confirm) }
    function global:Get-AutoSensitivityLabelPolicy { }
    function global:Get-AutoSensitivityLabelRule { }
    function global:Get-InformationBarrierPolicy { }
    function global:Get-ProtectionAlert { }

    function global:New-Connected {
        param([string] $TenantId = 't', [string] $AppId = 'c')
        # Regional prefix on purpose: the real URI is eur01b.ps.compliance...
        [PSCustomObject]@{
            ConnectionUri = 'https://eur01b.ps.compliance.protection.outlook.com'
            TenantID = $TenantId; AppId = $AppId; ConnectionId = 'conn-1'
            UserPrincipalName = 'OAuthUser@contoso.com'
        }
    }
}
AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
    foreach ($f in 'Get-ConnectionInformation','Get-DlpCompliancePolicy','Get-DlpComplianceRule',
                   'Get-Label','Get-LabelPolicy','Get-ComplianceTag','Get-RetentionCompliancePolicy','New-Connected','Disconnect-ExchangeOnline','Get-AutoSensitivityLabelPolicy','Get-AutoSensitivityLabelRule','Get-InformationBarrierPolicy','Get-ProtectionAlert') {
        Remove-Item "function:global:$f" -ErrorAction SilentlyContinue
    }
}

Describe 'Initialize-MsecExoSession' {

    It 'connects by itself when no compliance session is open' {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { @() }
            Mock Connect-MsecPurview -MockWith { }
            Mock Get-DlpCompliancePolicy -MockWith { @() }
            Mock Get-DlpComplianceRule -MockWith { @() }

            $null = Get-MsecPurviewDlpPolicy

            Should -Invoke Connect-MsecPurview -Times 1 -Scope It
        }
    }

    It 'does NOT reconnect when a session is already open' {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Connect-MsecPurview -MockWith { }
            Mock Get-DlpCompliancePolicy -MockWith { @() }
            Mock Get-DlpComplianceRule -MockWith { @() }

            $null = Get-MsecPurviewDlpPolicy

            # The handshake costs seconds and imports hundreds of cmdlets - paying it per call
            # would be worse than the manual connect this replaced.
            Should -Invoke Connect-MsecPurview -Times 0 -Scope It
        }
    }

    It 'is not fooled by an Exchange Online connection into skipping the connect' {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith {
                [PSCustomObject]@{ ConnectionUri = 'https://outlook.office365.com/PowerShell-LiveId' }
            }
            Mock Connect-MsecPurview -MockWith { }
            Mock Get-DlpCompliancePolicy -MockWith { @() }
            Mock Get-DlpComplianceRule -MockWith { @() }

            $null = Get-MsecPurviewDlpPolicy

            Should -Invoke Connect-MsecPurview -Times 1 -Scope It
        }
    }

    It 'points at Connect-Msec, not Connect-MsecPurview, when there is no app session to build on' {
        InModuleScope msec {
            $script:MsecSession = $null
            Mock Get-ConnectionInformation -MockWith { @() }
            { Get-MsecPurviewDlpPolicy } | Should -Throw '*Connect-Msec first*'
        }
    }
}

Describe 'Get-MsecPurviewDlpPolicy' {

    It 'reports Mode separately from IsEnforcing' {
        $rows = InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Get-DlpComplianceRule -MockWith { @() }
            Mock Get-DlpCompliancePolicy -MockWith {
                @(
                    [PSCustomObject]@{ Name = 'Enforcing'; Mode = 'Enable';                Enabled = $true }
                    [PSCustomObject]@{ Name = 'Testing';   Mode = 'TestWithNotifications'; Enabled = $true }
                    [PSCustomObject]@{ Name = 'Off';       Mode = 'Disable';               Enabled = $false }
                )
            }
            @(Get-MsecPurviewDlpPolicy)
        }

        ($rows | Where-Object Name -eq 'Enforcing').IsEnforcing | Should -BeTrue
        # Enabled AND reporting, but it stops nothing - the distinction the whole column exists for.
        ($rows | Where-Object Name -eq 'Testing').Enabled     | Should -BeTrue
        ($rows | Where-Object Name -eq 'Testing').IsEnforcing | Should -BeFalse
        ($rows | Where-Object Name -eq 'Off').IsEnforcing     | Should -BeFalse
    }

    It 'tells an estate-wide location apart from a site called All' {
        $rows = InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Get-DlpComplianceRule -MockWith { @() }
            Mock Get-DlpCompliancePolicy -MockWith {
                @([PSCustomObject]@{
                    Name = 'P'; Mode = 'Enable'; Enabled = $true
                    SharePointLocation = @([PSCustomObject]@{ DisplayName = 'All' })
                    OneDriveLocation   = @([PSCustomObject]@{ DisplayName = 'Site A' },
                                           [PSCustomObject]@{ DisplayName = 'Site B' })
                    ExchangeLocation   = @()
                })
            }
            @(Get-MsecPurviewDlpPolicy)
        }

        $rows[0].SharePointScope | Should -Be 'All'
        # Count is 0 for All: there is no list to count, and reading it as coverage would be wrong.
        $rows[0].SharePointCount | Should -Be 0
        $rows[0].OneDriveScope   | Should -Be 'Named'
        $rows[0].OneDriveCount   | Should -Be 2
        $rows[0].ExchangeScope   | Should -Be 'None'
    }

    It 'nulls the rule columns when the rules cannot be read, rather than reporting zero' {
        $rows = InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Get-DlpCompliancePolicy -MockWith { @([PSCustomObject]@{ Name = 'P'; Mode = 'Enable'; Enabled = $true }) }
            Mock Get-DlpComplianceRule -MockWith { throw 'access denied' }
            @(Get-MsecPurviewDlpPolicy -WarningAction SilentlyContinue)
        }

        # "no blocking rule" and "could not tell" must not look alike on a control question.
        $rows[0].RuleCount         | Should -BeNullOrEmpty
        $rows[0].BlockingRuleCount | Should -BeNullOrEmpty
    }

    It 'counts blocking rules and takes the highest severity' {
        $rows = InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Get-DlpCompliancePolicy -MockWith { @([PSCustomObject]@{ Name = 'P'; Mode = 'Enable'; Enabled = $true }) }
            Mock Get-DlpComplianceRule -MockWith {
                @(
                    [PSCustomObject]@{ Name = 'r1'; ParentPolicyName = 'P'; BlockAccess = $true;  ReportSeverityLevel = 'Low' }
                    [PSCustomObject]@{ Name = 'r2'; ParentPolicyName = 'P'; BlockAccess = $false; ReportSeverityLevel = 'High' }
                )
            }
            @(Get-MsecPurviewDlpPolicy)
        }

        $rows[0].RuleCount         | Should -Be 2
        $rows[0].BlockingRuleCount | Should -Be 1
        $rows[0].MaxRuleSeverity   | Should -Be 'High'
    }
}

Describe 'Get-MsecPurviewSensitivityLabel' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Get-LabelPolicy -MockWith {
                @([PSCustomObject]@{ Name = 'Information Classification'; Labels = @('Confidential') })
            }
        }
    }

    It 'reads protection out of LabelActions, which is the only place it exists' {
        $rows = InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Get-LabelPolicy -MockWith { @() }
            Mock Get-Label -MockWith {
                @([PSCustomObject]@{
                    Name = 'Confidential'; DisplayName = 'Confidential'; Priority = 2; Disabled = $false
                    LabelActions = @('{"Type":"encrypt","Settings":[{"Key":"protectiontype","Value":"userdefined"},{"Key":"disabled","Value":"false"}]}')
                })
            }
            @(Get-MsecPurviewSensitivityLabel)
        }

        $rows[0].EncryptionConfigured | Should -BeTrue
        $rows[0].EncryptionEnabled    | Should -BeTrue
        $rows[0].EncryptionType       | Should -Be 'userdefined'
        $rows[0].ActionTypes          | Should -Contain 'encrypt'
    }

    It "treats the STRING 'true' as disabled - [bool]'false' is truthy and would invert this" {
        $rows = InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Get-LabelPolicy -MockWith { @() }
            Mock Get-Label -MockWith {
                @(
                    [PSCustomObject]@{
                        Name = 'On'; DisplayName = 'On'; Priority = 0; Disabled = $false
                        LabelActions = @('{"Type":"encrypt","Settings":[{"Key":"disabled","Value":"false"}]}')
                    }
                    [PSCustomObject]@{
                        Name = 'Off'; DisplayName = 'Off'; Priority = 1; Disabled = $false
                        LabelActions = @('{"Type":"encrypt","Settings":[{"Key":"disabled","Value":"true"}]}')
                    }
                )
            }
            @(Get-MsecPurviewSensitivityLabel)
        }

        # Both have encryption CONFIGURED; only one has it on.
        ($rows | Where-Object DisplayName -eq 'On').EncryptionConfigured  | Should -BeTrue
        ($rows | Where-Object DisplayName -eq 'On').EncryptionEnabled     | Should -BeTrue
        ($rows | Where-Object DisplayName -eq 'Off').EncryptionConfigured | Should -BeTrue
        ($rows | Where-Object DisplayName -eq 'Off').EncryptionEnabled    | Should -BeFalse
    }

    It 'marks a label no policy publishes as unpublished' {
        $rows = InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Get-LabelPolicy -MockWith {
                @([PSCustomObject]@{ Name = 'Information Classification'; Labels = @('Confidential') })
            }
            Mock Get-Label -MockWith {
                @(
                    [PSCustomObject]@{ Name = 'Confidential'; DisplayName = 'Confidential'; Priority = 0; Disabled = $false; LabelActions = @() }
                    [PSCustomObject]@{ Name = 'Orphan';       DisplayName = 'Orphan';       Priority = 1; Disabled = $false; LabelActions = @() }
                )
            }
            @(Get-MsecPurviewSensitivityLabel)
        }

        ($rows | Where-Object DisplayName -eq 'Confidential').IsPublished | Should -BeTrue
        ($rows | Where-Object DisplayName -eq 'Confidential').PublishedBy | Should -Contain 'Information Classification'
        ($rows | Where-Object DisplayName -eq 'Orphan').IsPublished       | Should -BeFalse
    }

    It 'nulls IsPublished when the label policies could not be read' {
        $rows = InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Get-LabelPolicy -MockWith { throw 'denied' }
            Mock Get-Label -MockWith {
                @([PSCustomObject]@{ Name = 'L'; DisplayName = 'L'; Priority = 0; Disabled = $false; LabelActions = @() })
            }
            @(Get-MsecPurviewSensitivityLabel -WarningAction SilentlyContinue)
        }

        # Not $false, which would claim we checked and it reaches nobody.
        $rows[0].IsPublished | Should -BeNullOrEmpty
        $rows[0].PublishedBy | Should -BeNullOrEmpty
    }
}

Describe 'Get-MsecPurviewRetention' {

    It 'reports an unpublished label as not in force' {
        $rows = InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Get-RetentionCompliancePolicy -MockWith { @() }
            Mock Get-ComplianceTag -MockWith {
                @([PSCustomObject]@{
                    Name = 'Retain indefinitely'; RetentionAction = 'Keep'; RetentionDuration = 'Unlimited'
                    IsRecordLabel = $false; Published = $false
                })
            }
            @(Get-MsecPurviewRetention)
        }

        $rows[0].Kind      | Should -Be 'Label'
        $rows[0].IsInForce | Should -BeFalse
    }

    It 'returns labels and policies in one stream, tagged by Kind' {
        $rows = InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Get-ComplianceTag -MockWith { @([PSCustomObject]@{ Name = 'L'; Published = $true }) }
            Mock Get-RetentionCompliancePolicy -MockWith { @([PSCustomObject]@{ Name = 'P'; Enabled = $true }) }
            @(Get-MsecPurviewRetention)
        }

        @($rows | Where-Object Kind -eq 'Label').Count  | Should -Be 1
        @($rows | Where-Object Kind -eq 'Policy').Count | Should -Be 1
    }

    It 'takes a side with -Kind' {
        $rows = InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Get-ComplianceTag -MockWith { @([PSCustomObject]@{ Name = 'L'; Published = $true }) }
            Mock Get-RetentionCompliancePolicy -MockWith { throw 'should not be called' }
            @(Get-MsecPurviewRetention -Kind Label)
        }
        $rows.Count | Should -Be 1
    }

    It 'returns nothing, without throwing, when no retention is configured' {
        $rows = InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Get-ComplianceTag -MockWith { @() }
            Mock Get-RetentionCompliancePolicy -MockWith { @() }
            @(Get-MsecPurviewRetention)
        }
        # An empty result is a real answer here, and a report must say so rather than omit it.
        $rows.Count | Should -Be 0
    }
}

Describe 'Session handling is consistent across the workloads that need one' {

    It 'reconnects when the session belongs to a DIFFERENT tenant' {
        # A workload session outlives the Connect-Msec that prompted it. Matching only on "is
        # something connected" reuses the previous tenant's session and reports its data under
        # the new tenant's name, which looks like nothing at all.
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 'tenant-B'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected -TenantId 'tenant-A' }
            Mock Disconnect-ExchangeOnline -MockWith { }
            Mock Connect-MsecPurview -MockWith { }
            Mock Get-DlpCompliancePolicy -MockWith { @() }
            Mock Get-DlpComplianceRule -MockWith { @() }

            $null = Get-MsecPurviewDlpPolicy -WarningAction SilentlyContinue

            Should -Invoke Connect-MsecPurview -Times 1 -Scope It
            # And the stale one is CLOSED, not left alongside - two live sessions would make the
            # wrong-tenant read intermittent instead of consistent.
            Should -Invoke Disconnect-ExchangeOnline -Times 1 -Scope It
        }
    }

    It 'says which tenant it closed and why' {
        $warnings = InModuleScope msec {
            $script:MsecSession = @{ TenantId = 'tenant-B'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected -TenantId 'tenant-A' }
            Mock Disconnect-ExchangeOnline -MockWith { }
            Mock Connect-MsecPurview -MockWith { }
            Mock Get-DlpCompliancePolicy -MockWith { @() }
            Mock Get-DlpComplianceRule -MockWith { @() }
            $null = Get-MsecPurviewDlpPolicy -WarningVariable w -WarningAction SilentlyContinue
            @($w)
        }
        ($warnings -join ' ') | Should -Match 'tenant-A'
        ($warnings -join ' ') | Should -Match 'tenant-B'
    }

    It 'does NOT reconnect a session that merely signed in as someone else on the right tenant' {
        # Identity is the caller''s business; reconnecting as the app would quietly remove rights
        # they deliberately signed in to use. Tenant is the correctness question, not identity.
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'msec-app'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected -TenantId 't' -AppId 'some-other-app' }
            Mock Connect-MsecPurview -MockWith { }
            Mock Disconnect-ExchangeOnline -MockWith { }
            Mock Get-DlpCompliancePolicy -MockWith { @() }
            Mock Get-DlpComplianceRule -MockWith { @() }

            $null = Get-MsecPurviewDlpPolicy

            Should -Invoke Connect-MsecPurview -Times 0 -Scope It
            Should -Invoke Disconnect-ExchangeOnline -Times 0 -Scope It
        }
    }

    It 'tells an Exchange session apart from a Compliance one, in both directions' {
        # One module, two services, distinguishable only by URI. A loose match lets either
        # satisfy a requirement for the other, and the failure then lands later as a
        # missing-cmdlet error naming nothing.
        InModuleScope msec {
            Mock Get-ConnectionInformation -MockWith {
                [PSCustomObject]@{ ConnectionUri = 'https://outlook.office365.com/PowerShell-LiveId' }
            }
            @(Get-MsecExoConnection -Endpoint Exchange).Count   | Should -Be 1
            @(Get-MsecExoConnection -Endpoint Compliance).Count | Should -Be 0

            Mock Get-ConnectionInformation -MockWith { New-Connected }
            @(Get-MsecExoConnection -Endpoint Exchange).Count   | Should -Be 0
            @(Get-MsecExoConnection -Endpoint Compliance).Count | Should -Be 1
        }
    }

    It 'reports not-connected rather than throwing when Get-ConnectionInformation is unavailable' {
        InModuleScope msec {
            Mock Get-ConnectionInformation -MockWith { throw 'module not loaded' }
            @(Get-MsecExoConnection -Endpoint Exchange).Count | Should -Be 0
        }
    }

    It 'leaves no workload demanding a manual connect step' {
        # The house rule, pinned: every command needing a workload session opens one itself.
        # Get-MsecTeamsPolicy and Get-MsecSharePointSiteUser already did; Exchange and Purview
        # were brought into line.
        $offenders = foreach ($name in 'Get-MsecExchangeMailboxPermission', 'Get-MsecTeamsPolicy',
                                       'Get-MsecPurviewDlpPolicy', 'Get-MsecPurviewSensitivityLabel',
                                       'Get-MsecPurviewRetention') {
            $body = (Get-Command $name).Definition
            if ($body -notmatch 'Initialize-MsecExoSession|Connect-Msec\w+') { $name }
        }
        $offenders | Should -BeNullOrEmpty
    }
}

Describe 'A tenant without the feature' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
        }
    }

    It 'says the tenant cannot be asked, rather than returning no policies' {
        # The compliance endpoint imports only the cmdlets a tenant is licensed for, so on a
        # tenant without DLP the cmdlet is simply absent. Returning an empty result would claim
        # "no DLP policies are configured" - the opposite conclusion on a compliance report.
        InModuleScope msec {
            Mock Get-Command -ParameterFilter { $Name -eq 'Get-DlpCompliancePolicy' } -MockWith { $null }

            { Get-MsecPurviewDlpPolicy } | Should -Throw '*not measurable from here*'
        }
    }

    It 'names the cmdlet and says it is a capability limit, not a permission problem' {
        InModuleScope msec {
            Mock Get-Command -ParameterFilter { $Name -eq 'Get-Label' } -MockWith { $null }

            $message = $null
            try { Get-MsecPurviewSensitivityLabel } catch { $message = $_.Exception.Message }

            $message | Should -Match 'Get-Label'
            $message | Should -Match 'sensitivity labels'
            $message | Should -Match 'ROLE GROUPS'
            # Sending someone to grant an API permission would waste their time - it cannot help.
            $message | Should -Match 'not an API permission'
        }
    }

    It 'points at the half that still works when only one retention cmdlet is missing' {
        InModuleScope msec {
            Mock Get-Command -ParameterFilter { $Name -eq 'Get-RetentionCompliancePolicy' } -MockWith { $null }

            { Get-MsecPurviewRetention } | Should -Throw '*-Kind Label*'
        }
    }

    It 'still answers -Kind Label when only the policy cmdlet is missing' {
        $rows = InModuleScope msec {
            Mock Get-Command -ParameterFilter { $Name -eq 'Get-RetentionCompliancePolicy' } -MockWith { $null }
            Mock Get-ComplianceTag -MockWith { @([PSCustomObject]@{ Name = 'L'; Published = $true }) }

            @(Get-MsecPurviewRetention -Kind Label)
        }
        # The guard is per half and only fires for the half being read.
        $rows.Count | Should -Be 1
    }
}

Describe 'Get-MsecPurviewAutoLabelingPolicy' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
        }
    }

    It 'returns nothing, without throwing, when no auto-labeling exists' {
        # Zero here is a FINDING - labels are being applied by users only - so the command must
        # answer cleanly rather than error, and a report must print the section.
        $rows = InModuleScope msec {
            Mock Get-AutoSensitivityLabelPolicy -MockWith { @() }
            Mock Get-AutoSensitivityLabelRule -MockWith { @() }
            @(Get-MsecPurviewAutoLabelingPolicy)
        }
        $rows.Count | Should -Be 0
    }

    It 'separates simulation from enforcement' {
        $rows = InModuleScope msec {
            Mock Get-AutoSensitivityLabelRule -MockWith { @() }
            Mock Get-AutoSensitivityLabelPolicy -MockWith {
                @(
                    [PSCustomObject]@{ Name = 'Live'; Mode = 'Enable';                   Enabled = $true; ApplySensitivityLabel = 'Confidential' }
                    [PSCustomObject]@{ Name = 'Sim';  Mode = 'TestWithoutNotifications'; Enabled = $true; ApplySensitivityLabel = 'Confidential' }
                )
            }
            @(Get-MsecPurviewAutoLabelingPolicy)
        }
        ($rows | Where-Object Name -eq 'Live').IsEnforcing | Should -BeTrue
        # Enabled and running, but it labels nothing.
        ($rows | Where-Object Name -eq 'Sim').Enabled      | Should -BeTrue
        ($rows | Where-Object Name -eq 'Sim').IsEnforcing  | Should -BeFalse
    }

    It 'keeps Raw, because the projection is unverified against a tenant that has one' {
        $rows = InModuleScope msec {
            Mock Get-AutoSensitivityLabelRule -MockWith { @() }
            Mock Get-AutoSensitivityLabelPolicy -MockWith {
                @([PSCustomObject]@{ Name = 'P'; Mode = 'Enable'; Enabled = $true
                                     SomeUndocumentedField = 'still reachable' })
            }
            @(Get-MsecPurviewAutoLabelingPolicy)
        }
        $rows[0].Raw.SomeUndocumentedField | Should -Be 'still reachable'
    }

    It 'nulls the rule columns when the rule cmdlet is not exposed' {
        $rows = InModuleScope msec {
            Mock Get-AutoSensitivityLabelPolicy -MockWith { @([PSCustomObject]@{ Name = 'P'; Mode = 'Enable'; Enabled = $true }) }
            Mock Get-Command -ParameterFilter { $Name -eq 'Get-AutoSensitivityLabelRule' } -MockWith { $null }
            @(Get-MsecPurviewAutoLabelingPolicy -WarningAction SilentlyContinue)
        }
        # Not 0, which would say "this policy has no conditions".
        $rows[0].RuleCount | Should -BeNullOrEmpty
    }
}

Describe 'Get-MsecPurviewInformationBarrier' {

    It 'distinguishes an authored policy from an applied one' {
        $rows = InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Get-InformationBarrierPolicy -MockWith {
                @(
                    [PSCustomObject]@{ Name = 'Live';  State = 'Active';   AssignedSegment = 'Traders' }
                    [PSCustomObject]@{ Name = 'Draft'; State = 'Inactive'; AssignedSegment = 'Research' }
                )
            }
            @(Get-MsecPurviewInformationBarrier)
        }
        ($rows | Where-Object Name -eq 'Live').IsActive  | Should -BeTrue
        # Counted as a policy, protecting nobody.
        ($rows | Where-Object Name -eq 'Draft').IsActive | Should -BeFalse
    }
}

Describe 'A renamed policy has two names' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
        }
    }

    It 'reports the DISPLAY name, which is what the portal shows' {
        # Renaming a DLP policy changes DisplayName and leaves Name as created. Reporting Name
        # means the page says one thing and the portal another, and nobody can find the policy.
        $rows = InModuleScope msec {
            Mock Get-DlpComplianceRule -MockWith { @() }
            Mock Get-DlpCompliancePolicy -MockWith {
                @([PSCustomObject]@{
                    Name = 'TEST - Label-based DLP (pilot)'
                    DisplayName = 'DLP - Confidential document shared'
                    Mode = 'Enable'; Enabled = $true })
            }
            @(Get-MsecPurviewDlpPolicy)
        }

        $rows[0].Name         | Should -Be 'DLP - Confidential document shared'
        $rows[0].InternalName | Should -Be 'TEST - Label-based DLP (pilot)'
        $rows[0].Renamed      | Should -BeTrue
    }

    It 'still joins rules on the INTERNAL name, which is what ParentPolicyName tracks' {
        # Measured live: ParentPolicyName matched Name on 10 of 10 rules and DisplayName only
        # where the two happened to be equal. Joining on the display name silently loses the
        # rules of every renamed policy - and RuleCount 0 reads as "no conditions".
        $rows = InModuleScope msec {
            Mock Get-DlpCompliancePolicy -MockWith {
                @([PSCustomObject]@{
                    Name = 'TEST - Label-based DLP (pilot)'
                    DisplayName = 'DLP - Confidential document shared'
                    Mode = 'Enable'; Enabled = $true })
            }
            Mock Get-DlpComplianceRule -MockWith {
                @([PSCustomObject]@{ Name = 'r1'
                                     ParentPolicyName = 'TEST - Label-based DLP (pilot)'
                                     BlockAccess = $false; ReportSeverityLevel = 'Low' })
            }
            @(Get-MsecPurviewDlpPolicy)
        }

        $rows[0].RuleCount | Should -Be 1
        $rows[0].RuleNames | Should -Contain 'r1'
    }

    It 'is findable by either name' {
        $byDisplay, $byInternal = InModuleScope msec {
            Mock Get-DlpComplianceRule -MockWith { @() }
            Mock Get-DlpCompliancePolicy -MockWith {
                @([PSCustomObject]@{ Name = 'Old name'; DisplayName = 'New name'; Mode = 'Enable'; Enabled = $true })
            }
            ,@(Get-MsecPurviewDlpPolicy -Name 'New*')
            ,@(Get-MsecPurviewDlpPolicy -Name 'Old*')
        }
        $byDisplay.Count  | Should -Be 1
        $byInternal.Count | Should -Be 1
    }

    It 'falls back to Name when there is no DisplayName' {
        $rows = InModuleScope msec {
            Mock Get-DlpComplianceRule -MockWith { @() }
            Mock Get-DlpCompliancePolicy -MockWith {
                @([PSCustomObject]@{ Name = 'Only one name'; Mode = 'Enable'; Enabled = $true })
            }
            @(Get-MsecPurviewDlpPolicy)
        }
        $rows[0].Name    | Should -Be 'Only one name'
        $rows[0].Renamed | Should -BeFalse
    }
}

Describe 'The Workload property contradicts the scopes' {

    It 'flags a policy that claims Exchange but targets no mailboxes' {
        # Measured live: all 8 policies on one tenant listed Exchange in Workload while every
        # Exchange targeting property was empty. Microsoft's reference is explicit that an unset
        # ExchangeLocation means email is not included - so Workload is declarative, not derived,
        # and reading it is how a careful admin concludes email is covered when it is not.
        $rows = InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Get-DlpComplianceRule -MockWith { @() }
            Mock Get-DlpCompliancePolicy -MockWith {
                @(
                    [PSCustomObject]@{
                        Name = 'Claims email'; Mode = 'Enable'; Enabled = $true
                        Workload = 'Exchange, SharePoint, OneDriveForBusiness'
                        ExchangeLocation = @()
                        SharePointLocation = @([PSCustomObject]@{ DisplayName = 'All' })
                    }
                    [PSCustomObject]@{
                        Name = 'Actually covers email'; Mode = 'Enable'; Enabled = $true
                        Workload = 'Exchange'
                        ExchangeLocation = @([PSCustomObject]@{ DisplayName = 'All' })
                    }
                )
            }
            @(Get-MsecPurviewDlpPolicy)
        }

        $claims = $rows | Where-Object Name -eq 'Claims email'
        $claims.ExchangeScope            | Should -Be 'None'
        $claims.WorkloadClaims           | Should -Contain 'Exchange'
        $claims.ClaimsEmailWithoutTarget | Should -BeTrue

        $real = $rows | Where-Object Name -eq 'Actually covers email'
        $real.ExchangeScope              | Should -Be 'All'
        $real.ClaimsEmailWithoutTarget   | Should -BeFalse
    }
}

Describe 'Get-MsecPurviewAlertPolicy' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith { New-Connected }
            Mock Get-ProtectionAlert -MockWith {
                @(
                    [PSCustomObject]@{ Name = 'Shared files externally'; Category = 'DataGovernance'
                                       Severity = 'Medium'; Disabled = $true;  IsSystemRule = $true
                                       NotificationEnabled = $true }
                    [PSCustomObject]@{ Name = 'DLP-Custom rule'; Category = 'DataLossPrevention'
                                       Severity = 'Low'; Disabled = $false; IsSystemRule = $false
                                       NotificationEnabled = $false }
                    [PSCustomObject]@{ Name = 'Malware campaign'; Category = 'ThreatManagement'
                                       Severity = 'High'; Disabled = $false; IsSystemRule = $true
                                       NotificationEnabled = $true }
                )
            }
        }
    }

    It 'inverts Disabled into IsEnabled, keeping both' {
        # The service stores Disabled, so a filter written against it reads backwards and
        # Where-Object Disabled silently returns the healthy policies.
        $rows = InModuleScope msec { @(Get-MsecPurviewAlertPolicy) }

        ($rows | Where-Object Name -eq 'Shared files externally').IsEnabled | Should -BeFalse
        ($rows | Where-Object Name -eq 'Shared files externally').Disabled  | Should -BeTrue
        ($rows | Where-Object Name -eq 'Malware campaign').IsEnabled        | Should -BeTrue
    }

    It 'separates Microsoft built-ins from what this organisation configured' {
        $rows = InModuleScope msec { @(Get-MsecPurviewAlertPolicy -CustomOnly) }
        # A count mixing the two says nothing about how much alerting anyone here set up.
        $rows.Count  | Should -Be 1
        $rows[0].Name | Should -Be 'DLP-Custom rule'
    }

    It 'reports an enabled policy that emails nobody' {
        # NotificationEnabled is not whether the alert fires - it is whether anyone is told.
        $rows = InModuleScope msec {
            @(Get-MsecPurviewAlertPolicy | Where-Object { $_.IsEnabled -and -not $_.NotificationEnabled })
        }
        $rows.Count   | Should -Be 1
        $rows[0].Name | Should -Be 'DLP-Custom rule'
    }

    It 'filters by category' {
        $rows = InModuleScope msec { @(Get-MsecPurviewAlertPolicy -Category ThreatManagement) }
        $rows.Count | Should -Be 1
    }
}
