#Requires -Module Pester
#
# Pester 5 tests for the msec module. Run from the repo root with:
#   Invoke-Pester ./msec/Tests/msec.Tests.ps1
#
# Signing is delegated to Key Vault (Invoke-AzKeyVaultKeyOperation -Sign), so the private
# key is never local. These tests mock that call - they verify:
#   1. New-MsecClientAssertion assembles a correct JWT (header alg/typ/x5t, payload
#      aud/iss/sub) and passes a SHA-256 digest of the signing input to Key Vault.
#   2. The signature bytes returned by KV land verbatim in the JWT.
#   3. Get-MsecAccessToken caches tokens (no second /token hit while fresh).
#   4. Get-MsecScoreSummary returns Overall first, correct per-category math, and Defender
#      rows with blank previous-month / diff.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    # A stable fake SHA-1 thumbprint for x5t header tests.
    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'New-MsecClientAssertion (Key Vault signing)' {
    It 'assembles a 3-part JWT, sends SHA-256 of signing input to KV, and embeds the returned signature' {
        # The expected signature bytes are defined here AND hardcoded inline in the MockWith block
        # below - Pester's Mock script block does not reliably see $script:/closure variables from
        # outside, so inlining the literal is the most robust pattern.
        $signatureFromKv = [byte[]](100..255)

        $result = InModuleScope msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)

            $script:CapturedDigest = $null
            Mock Invoke-MsecKeyVaultSign -MockWith {
                $script:CapturedDigest = $Digest
                [byte[]](100..255)
            }

            $jwt = New-MsecClientAssertion `
                -TenantId 'tenant-guid' -ClientId 'client-guid' `
                -VaultName 'kv-test'    -KeyName 'msec-app' `
                -ThumbprintBytes $Thumb

            [pscustomobject]@{ Jwt = $jwt; Digest = $script:CapturedDigest }
        }

        $parts = $result.Jwt -split '\.'
        $parts.Count | Should -Be 3

        $pad = { param($s) $s + ('=' * ((4 - ($s.Length % 4)) % 4)) }
        $b64u = { param($s) ($s.Replace('-', '+').Replace('_', '/')) }

        # Header: alg/typ/x5t
        $headerJson = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String((& $pad (& $b64u $parts[0]))))
        $header = $headerJson | ConvertFrom-Json
        $header.alg | Should -Be 'RS256'
        $header.typ | Should -Be 'JWT'
        $expectedX5t = [Convert]::ToBase64String($script:TestThumbBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $header.x5t | Should -Be $expectedX5t

        # Payload: aud/iss/sub
        $payloadJson = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String((& $pad (& $b64u $parts[1]))))
        $payload = $payloadJson | ConvertFrom-Json
        $payload.iss | Should -Be 'client-guid'
        $payload.sub | Should -Be 'client-guid'
        $payload.aud | Should -Be 'https://login.microsoftonline.com/tenant-guid/oauth2/v2.0/token'

        # Digest passed to KV equals SHA-256 of the signing input ("$header.$payload").
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $expectedDigest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$($parts[0]).$($parts[1])"))
        } finally { $sha.Dispose() }
        [Convert]::ToBase64String([byte[]]$result.Digest) | Should -Be ([Convert]::ToBase64String($expectedDigest))

        # Signature bytes returned by KV land verbatim in the JWT (after base64url-decoding).
        $jwtSigBytes = [Convert]::FromBase64String((& $pad (& $b64u $parts[2])))
        [Convert]::ToBase64String($jwtSigBytes) | Should -Be ([Convert]::ToBase64String($signatureFromKv))
    }
}

Describe 'Get-MsecAccessToken caching' {
    BeforeEach {
        InModuleScope msec -Parameters @{ Thumb = $script:TestThumbBytes } {
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

    It 'hits /token only once across multiple Get-MsecAccessToken calls for the same resource' {
        InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'cached'; expires_in = 3600 }
            }

            [void](Get-MsecAccessToken -Resource 'https://graph.microsoft.com')
            [void](Get-MsecAccessToken -Resource 'https://graph.microsoft.com')
            [void](Get-MsecAccessToken -Resource 'https://graph.microsoft.com')

            Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -Times 1 -Exactly
        }
    }
}

Describe 'Get-MsecScoreSummary' {
    BeforeEach {
        InModuleScope msec -Parameters @{ Thumb = $script:TestThumbBytes } {
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

    It 'returns Overall first then categories, with correct today / prev-month / diff' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'secureScoreControlProfiles' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 'ctrl_id1';  maxScore = 30; controlCategory = 'Identity' }
                    [pscustomobject]@{ id = 'ctrl_id2';  maxScore = 20; controlCategory = 'Identity' }
                    [pscustomobject]@{ id = 'ctrl_dev1'; maxScore = 50; controlCategory = 'Device' }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'secureScores' -and $Uri -notmatch 'Profile' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        createdDateTime = '2026-05-27'; currentScore = 65; maxScore = 100
                        controlScores = @(
                            [pscustomobject]@{ controlName = 'ctrl_id1';  controlCategory = 'Identity'; score = 30 }
                            [pscustomobject]@{ controlName = 'ctrl_id2';  controlCategory = 'Identity'; score = 10 }
                            [pscustomobject]@{ controlName = 'ctrl_dev1'; controlCategory = 'Device';   score = 25 })
                    }
                    [pscustomobject]@{
                        createdDateTime = '2026-04-27'; currentScore = 70; maxScore = 100
                        controlScores = @(
                            [pscustomobject]@{ controlName = 'ctrl_id1';  controlCategory = 'Identity'; score = 20 }
                            [pscustomobject]@{ controlName = 'ctrl_id2';  controlCategory = 'Identity'; score = 10 }
                            [pscustomobject]@{ controlName = 'ctrl_dev1'; controlCategory = 'Device';   score = 40 })
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/api/exposureScore' }      -MockWith { [pscustomobject]@{ score = 33.49 } }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/api/configurationScore' } -MockWith { [pscustomobject]@{ score = 88 } }

            Get-MsecScoreSummary
        }

        $rows[0].ScoreType            | Should -Be 'Overall'
        $rows[0].TodayPercent         | Should -Be 65
        $rows[0].PreviousMonthPercent | Should -Be 70
        $rows[0].DiffPercent          | Should -Be -5

        $identity = $rows | Where-Object ScoreType -eq 'Identity'
        $identity.TodayPercent         | Should -Be 80
        $identity.PreviousMonthPercent | Should -Be 60
        $identity.DiffPercent          | Should -Be 20

        $device = $rows | Where-Object ScoreType -eq 'Device'
        $device.TodayPercent         | Should -Be 50
        $device.PreviousMonthPercent | Should -Be 80
        $device.DiffPercent          | Should -Be -30

        $exposure = $rows | Where-Object ScoreType -eq 'Exposure'
        $exposure.TodayPercent         | Should -Be 33.49
        $exposure.PreviousMonthPercent | Should -BeNullOrEmpty
        $exposure.DiffPercent          | Should -BeNullOrEmpty

        # DeviceConfiguration is intentionally excluded - the Defender API returns raw points
        # with no maximum, so it can't be normalized to a comparable percentage.
        ($rows | Where-Object ScoreType -eq 'DeviceConfiguration') | Should -BeNullOrEmpty
    }
}

Describe 'Get-MsecIntuneConfiguration' {
    BeforeEach {
        InModuleScope msec -Parameters @{ Thumb = $script:TestThumbBytes } {
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

    It 'merges Settings Catalog policies and classic device configurations into a unified shape' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/beta/deviceManagement/configurationPolicies\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'sc-1'; name = 'Win10 Hardening'; description = 'Catalog policy'
                        platforms = 'windows10'
                        createdDateTime = '2026-04-01T00:00:00Z'; lastModifiedDateTime = '2026-05-01T00:00:00Z'
                        assignments = @(@{ target = @{ groupId = 'g-1' } }; @{ target = @{ groupId = 'g-2' } })
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/v1.0/deviceManagement/deviceConfigurations\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'tpl-1'; displayName = 'Legacy iOS Restrictions'; description = 'Classic template'
                        '@odata.type' = '#microsoft.graph.iosGeneralDeviceConfiguration'
                        createdDateTime = '2025-12-01T00:00:00Z'; lastModifiedDateTime = '2026-02-01T00:00:00Z'
                        assignments = @()
                    }
                    [pscustomobject]@{
                        # Regression: windows10* used to also match windows* without 'break' -
                        # producing Platform = @('windows10','windows') instead of a single value.
                        id = 'tpl-2'; displayName = 'Win10 Custom'; description = 'Classic template'
                        '@odata.type' = '#microsoft.graph.windows10CustomConfiguration'
                        createdDateTime = '2024-05-20T00:00:00Z'; lastModifiedDateTime = '2024-06-01T00:00:00Z'
                        assignments = @(@{ target = @{ groupId = 'g-3' } })
                    }
                ) }
            }

            Get-MsecIntuneConfiguration
        }

        $rows.Count | Should -Be 3

        $sc = $rows | Where-Object Source -eq 'SettingsCatalog'
        $sc.Id          | Should -Be 'sc-1'
        $sc.DisplayName | Should -Be 'Win10 Hardening'   # comes from .name, not .displayName
        $sc.Platform    | Should -Be 'windows10'
        $sc.Type        | Should -Be 'Settings Catalog'

        $ios = $rows | Where-Object Id -eq 'tpl-1'
        $ios.DisplayName | Should -Be 'Legacy iOS Restrictions'
        $ios.Platform    | Should -Be 'iOS'              # derived from @odata.type prefix
        $ios.Type        | Should -Be 'iosGeneralDeviceConfiguration'

        # Regression: Platform is a single string, not an array of wildcard matches.
        $win = $rows | Where-Object Id -eq 'tpl-2'
        $win.Platform | Should -Be 'windows10'
        $win.Platform | Should -BeOfType [string]

        # AssignmentCount comes from $expand=assignments (no extra round-trip).
        $sc.AssignmentCount | Should -Be 2
        ($rows | Where-Object Id -eq 'tpl-1').AssignmentCount | Should -Be 0
        $win.AssignmentCount | Should -Be 1

        # Status column only appears with -IncludeStatus - the rows here should not have it.
        $sc.PSObject.Properties.Name  | Should -Not -Contain 'Status'
        $win.PSObject.Properties.Name | Should -Not -Contain 'Status'
    }

    It '-IncludeStatus adds check-in counts from the right endpoint per Source' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            # The list-all endpoint with $expand=assignments
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/beta/deviceManagement/configurationPolicies\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'sc-1'; name = 'SC Test'; platforms = 'windows10'
                        assignments = @(@{ target = @{ groupId = 'g-1' } })
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/v1.0/deviceManagement/deviceConfigurations\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'tpl-1'; displayName = 'Tpl Test'
                        '@odata.type' = '#microsoft.graph.windows10GeneralConfiguration'
                        assignments = @(@{ target = @{ groupId = 'g-1' } })
                    }
                ) }
            }
            # Templates status: single aggregated object from /deviceStatusOverview
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceConfigurations/tpl-1/deviceStatusOverview' } -MockWith {
                [pscustomobject]@{
                    successCount = 10; errorCount = 0; conflictCount = 0
                    notApplicableCount = 2; pendingCount = 0
                }
            }
            # Settings Catalog status: pre-fetched via the Reports API. Mock the helper
            # directly to avoid mocking the full exportJob + poll + download flow here.
            Mock Get-MsecSettingsCatalogStatusReport -MockWith {
                @{
                    'sc-1' = [pscustomobject]@{
                        SuccessCount = 3; ErrorCount = 1; ConflictCount = 0
                        NotApplicableCount = 1; PendingCount = 0
                    }
                }
            }

            Get-MsecIntuneConfiguration -IncludeStatus
        }

        # Templates: real counts from deviceStatusOverview
        $tpl = $rows | Where-Object Source -eq 'Templates'
        $tpl.SuccessCount   | Should -Be 10
        $tpl.ErrorCount     | Should -Be 0
        $tpl.SuccessPercent | Should -Be 100.0

        # Settings Catalog: counts came from the (mocked) Reports API helper.
        $sc = $rows | Where-Object Source -eq 'SettingsCatalog'
        $sc.SuccessCount   | Should -Be 3
        $sc.ErrorCount     | Should -Be 1
        # Applicable = 3 success + 1 error + 0 conflict + 0 pending = 4 -> 75.0
        $sc.SuccessPercent | Should -Be 75.0

        # Status rollup with -IncludeStatus.
        $tpl.Status | Should -Be 'Healthy'   # 100% success, no errors/conflicts
        $sc.Status  | Should -Be 'Degraded'  # 75% with an error
    }

    It 'NotDeployed policies get zero counts (not nulls) on every status field' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/beta/deviceManagement/configurationPolicies\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'sc-unassigned'; name = 'Unassigned SC policy'; platforms = 'windows10'
                        assignments = @()  # AssignmentCount = 0 -> NotDeployed
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/v1.0/deviceManagement/deviceConfigurations\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{
                        id = 'tpl-unassigned'; displayName = 'Unassigned Template'
                        '@odata.type' = '#microsoft.graph.windows10GeneralConfiguration'
                        assignments = @()
                    }
                ) }
            }
            Mock Get-MsecSettingsCatalogStatusReport -MockWith { @{} }

            Get-MsecIntuneConfiguration -IncludeStatus
        }

        foreach ($r in $rows) {
            $r.Status             | Should -Be 'NotDeployed'
            $r.SuccessCount       | Should -Be 0
            $r.ErrorCount         | Should -Be 0
            $r.ConflictCount      | Should -Be 0
            $r.NotApplicableCount | Should -Be 0
            $r.PendingCount       | Should -Be 0
            $r.SuccessPercent     | Should -Be 0
        }
    }

    It 'Status is NotReporting when assigned but no status data, and all counts are zero (consistent with NotDeployed)' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/beta/deviceManagement/configurationPolicies\?' } -MockWith {
                [pscustomobject]@{ value = @(
                    # Assigned, but the report (mocked below) does not include this PolicyId
                    # - same shape as your Autopilot device prep / empty-group policies.
                    [pscustomobject]@{
                        id = 'sc-orphan'; name = 'Empty group policy'; platforms = 'windows10'
                        assignments = @(@{ target = @{ groupId = 'g-1' } })
                    }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/v1.0/deviceManagement/deviceConfigurations\?' } -MockWith {
                [pscustomobject]@{ value = @() }
            }
            Mock Get-MsecSettingsCatalogStatusReport -MockWith { @{} }  # empty report

            Get-MsecIntuneConfiguration -IncludeStatus
        }

        $r = $rows[0]
        $r.AssignmentCount    | Should -Be 1
        $r.Status             | Should -Be 'NotReporting'
        # NotReporting now zeros every status field (consistent with NotDeployed) so the
        # table doesn't mix blanks and integers per row.
        $r.SuccessCount       | Should -Be 0
        $r.ErrorCount         | Should -Be 0
        $r.ConflictCount      | Should -Be 0
        $r.NotApplicableCount | Should -Be 0
        $r.PendingCount       | Should -Be 0
        $r.SuccessPercent     | Should -Be 0
    }
}

Describe 'Get-MsecIntuneCompliancePolicy' {
    BeforeEach {
        InModuleScope msec -Parameters @{ Thumb = $script:TestThumbBytes } {
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
        $rows = InModuleScope msec {
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

Describe 'Search-MsecGraph' {
    It 'loads KQL/Graph/VM/All.kql by convention and shuttles it to Search-AzGraph unchanged' {
        $result = InModuleScope msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            $script:CapturedQuery = $null
            Mock Search-AzGraph -MockWith {
                $script:CapturedQuery = $Query
                @(
                    [pscustomobject]@{ Name = 'lin-1'; ResourceGroupName = 'rg-a'; Os = 'Linux' }
                )
            }

            $rows = Search-MsecGraph -ResourceType VM
            [pscustomobject]@{ Rows = $rows; Query = $script:CapturedQuery }
        }

        # The query that hit Search-AzGraph is exactly what's in the .kql file -
        # no filter clauses appended.
        $result.Query | Should -Match "type =~ 'microsoft.compute/virtualmachines'"
        $result.Query | Should -Match 'project Name\s*=\s*name'
        $result.Query | Should -Not -Match 'Os =~'           # no in-query filtering anymore
        $result.Query | Should -Not -Match 'Running =='
        $result.Query | Should -Not -Match "ResourceGroupName =~"

        $result.Rows.Count | Should -Be 1
        $result.Rows[0].Name | Should -Be 'lin-1'
    }

    It 'unwraps Search-AzGraph response objects that have a .Data array' {
        # Reproduces what Az.ResourceGraph returns on some installs: ONE object with
        # .SkipToken (string) + .Data (array of rows). Without unwrapping, downstream
        # Where-Object can only filter on 'SkipToken' / 'Data' - useless.
        $rows = InModuleScope msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            Mock Search-AzGraph -MockWith {
                [pscustomobject]@{
                    SkipToken = ''
                    Data      = @(
                        [pscustomobject]@{ Name = 'lin-1'; Os = 'Linux';   Running = $true }
                        [pscustomobject]@{ Name = 'win-1'; Os = 'Windows'; Running = $true }
                    )
                }
            }
            Search-MsecGraph -ResourceType VM
        }

        # We should see two rows, with the actual VM properties accessible for filtering.
        $rows.Count                                    | Should -Be 2
        ($rows | Where-Object Os -eq 'Linux').Name     | Should -Be 'lin-1'
        # SkipToken / Data must not leak through as row properties.
        $rows[0].PSObject.Properties.Name | Should -Not -Contain 'SkipToken'
        $rows[0].PSObject.Properties.Name | Should -Not -Contain 'Data'
    }

    It 'throws a clear error when the named .kql file does not exist' {
        InModuleScope msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            Mock Search-AzGraph -MockWith { @() }
            { Search-MsecGraph -ResourceType VM -Name 'NoSuchQuery' } |
                Should -Throw -ExpectedMessage 'KQL query file not found:*'
        }
    }

    # Tab-completion tests go through PowerShell's real completion entry point
    # (TabExpansion2), NOT InModuleScope + & $scriptblock - the latter passed even when the
    # completer was actually broken because it ran the scriptblock with module $script:
    # scope available, whereas the real completion engine does not. These tests would
    # catch a regression to module-scoped state usage in the completer scriptblock.
    It 'tab completion for -ResourceType returns folders containing .kql files' {
        $line = 'Search-MsecGraph -ResourceType '
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $result.CompletionMatches.CompletionText | Should -Contain 'VM'
    }

    It 'tab completion for -Name returns the .kql file basenames in the chosen ResourceType folder' {
        $line = 'Search-MsecGraph -ResourceType VM -Name '
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $result.CompletionMatches.CompletionText | Should -Contain 'All'
    }

    It 'pipes cleanly through Where-Object into Invoke-MsecVMScriptLinux' {
        # End-to-end: ARG-shaped rows -> Where-Object -> OS-specific runner. Validates that
        # Search-MsecGraph's output (Name + ResourceGroupName) binds correctly to the runner.
        $captured = InModuleScope msec {
            Mock Get-AzContext  -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            Mock Search-AzGraph -MockWith {
                @(
                    [pscustomobject]@{ Name = 'lin-1'; ResourceGroupName = 'rg-a'; Os = 'Linux';   Running = $true }
                    [pscustomobject]@{ Name = 'win-1'; ResourceGroupName = 'rg-a'; Os = 'Windows'; Running = $true }
                )
            }
            $script:CapturedVmNames = @()
            Mock Invoke-AzVMRunCommand -MockWith {
                $script:CapturedVmNames += $Name
                [pscustomobject]@{ Status = 'Succeeded'; Value = @() }
            }

            Search-MsecGraph -ResourceType VM |
                Where-Object Os -eq Linux |
                Invoke-MsecVMScriptLinux -ScriptName os-info |
                Out-Null
            ,$script:CapturedVmNames
        }

        $captured.Count | Should -Be 1
        $captured[0]    | Should -Be 'lin-1'
    }
}

Describe 'Invoke-MsecVMScriptLinux' {
    It 'runs the bundled .sh script via RunShellScript and projects the response' {
        $results = InModuleScope msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            $script:CapturedScriptPath = $null
            $script:CapturedCommandId  = $null
            Mock Invoke-AzVMRunCommand -MockWith {
                $script:CapturedScriptPath = $ScriptPath
                $script:CapturedCommandId  = $CommandId
                [pscustomobject]@{
                    Status = 'Succeeded'
                    Value  = @(
                        [pscustomobject]@{ Code = 'ComponentStatus/StdOut/succeeded'; Message = "ran $ScriptPath" }
                        [pscustomobject]@{ Code = 'ComponentStatus/StdErr/succeeded'; Message = '' }
                    )
                }
            }

            $vm = [pscustomobject]@{ Name = 'lin-1'; ResourceGroupName = 'rg-a' }
            $out = $vm | Invoke-MsecVMScriptLinux -ScriptName os-info
            [pscustomobject]@{ Out = $out; Path = $script:CapturedScriptPath; Cmd = $script:CapturedCommandId }
        }

        $results.Cmd        | Should -Be 'RunShellScript'
        $results.Path       | Should -Match '/Scripts/Linux/os-info\.sh$'
        $results.Out.VmName | Should -Be 'lin-1'
        $results.Out.Status | Should -Be 'Succeeded'
        $results.Out.Output | Should -Match 'os-info\.sh'
    }

    It 'throws a clear "Linux script not found" error at runtime when the .sh does not exist' {
        InModuleScope msec {
            Mock Get-AzContext         -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            Mock Invoke-AzVMRunCommand -MockWith { throw 'should not be called' }

            $vm = [pscustomobject]@{ Name = 'lin-1'; ResourceGroupName = 'rg-a' }
            { $vm | Invoke-MsecVMScriptLinux -ScriptName does-not-exist } |
                Should -Throw -ExpectedMessage 'Linux script not found:*'
        }
    }

    It 'tab completion for -ScriptName returns the .sh basenames in Scripts/Linux' {
        $line = 'Invoke-MsecVMScriptLinux -ScriptName '
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $result.CompletionMatches.CompletionText | Should -Contain 'os-info'
    }
}

Describe 'Invoke-MsecVMScriptWindows' {
    It 'runs the bundled .ps1 script via RunPowerShellScript and projects the response' {
        $results = InModuleScope msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            $script:CapturedScriptPath = $null
            $script:CapturedCommandId  = $null
            Mock Invoke-AzVMRunCommand -MockWith {
                $script:CapturedScriptPath = $ScriptPath
                $script:CapturedCommandId  = $CommandId
                [pscustomobject]@{
                    Status = 'Succeeded'
                    Value  = @(
                        [pscustomobject]@{ Code = 'ComponentStatus/StdOut/succeeded'; Message = "ran $ScriptPath" }
                        [pscustomobject]@{ Code = 'ComponentStatus/StdErr/succeeded'; Message = '' }
                    )
                }
            }

            $vm = [pscustomobject]@{ Name = 'win-1'; ResourceGroupName = 'rg-a' }
            $out = $vm | Invoke-MsecVMScriptWindows -ScriptName os-info
            [pscustomobject]@{ Out = $out; Path = $script:CapturedScriptPath; Cmd = $script:CapturedCommandId }
        }

        $results.Cmd        | Should -Be 'RunPowerShellScript'
        $results.Path       | Should -Match '/Scripts/Windows/os-info\.ps1$'
        $results.Out.VmName | Should -Be 'win-1'
        $results.Out.Status | Should -Be 'Succeeded'
        $results.Out.Output | Should -Match 'os-info\.ps1'
    }

    It 'throws a clear "Windows script not found" error at runtime when the .ps1 does not exist' {
        InModuleScope msec {
            Mock Get-AzContext         -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            Mock Invoke-AzVMRunCommand -MockWith { throw 'should not be called' }

            $vm = [pscustomobject]@{ Name = 'win-1'; ResourceGroupName = 'rg-a' }
            { $vm | Invoke-MsecVMScriptWindows -ScriptName does-not-exist } |
                Should -Throw -ExpectedMessage 'Windows script not found:*'
        }
    }

    It 'tab completion for -ScriptName returns the .ps1 basenames in Scripts/Windows' {
        $line = 'Invoke-MsecVMScriptWindows -ScriptName '
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $result.CompletionMatches.CompletionText | Should -Contain 'os-info'
    }
}

Describe 'Export-MsecIntuneConfiguration' {
    BeforeEach {
        InModuleScope msec -Parameters @{ Thumb = $script:TestThumbBytes } {
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

    It 'exports a Settings Catalog policy by pulling policy + settings + assignments' {
        $export = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/configurationPolicies/sc-1$' } -MockWith {
                [pscustomobject]@{ id = 'sc-1'; name = 'Win10 Hardening'; platforms = 'windows10' }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/configurationPolicies/sc-1/settings' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = '0'; settingInstance = @{ settingDefinitionId = 'foo' } }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/configurationPolicies/sc-1/assignments' } -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ target = @{ groupId = 'g-1' } }) }
            }

            Export-MsecIntuneConfiguration -Id 'sc-1' -Source 'SettingsCatalog'
        }

        $export.Id          | Should -Be 'sc-1'
        $export.Source      | Should -Be 'SettingsCatalog'
        $export.DisplayName | Should -Be 'Win10 Hardening'
        $export.Policy      | Should -Not -BeNullOrEmpty
        $export.Settings.Count     | Should -Be 1
        $export.Assignments.Count  | Should -Be 1
        $export.ExportedAt  | Should -Not -BeNullOrEmpty
    }

    It 'exports a classic Template by pulling the full config + assignments' {
        $export = InModuleScope msec {
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceConfigurations/tpl-1$' } -MockWith {
                [pscustomobject]@{
                    id = 'tpl-1'; displayName = 'iOS Restrictions'
                    '@odata.type' = '#microsoft.graph.iosGeneralDeviceConfiguration'
                    passcodeMinimumLength = 6
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceConfigurations/tpl-1/assignments' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            Export-MsecIntuneConfiguration -Id 'tpl-1' -Source 'Templates'
        }

        $export.Id            | Should -Be 'tpl-1'
        $export.Source        | Should -Be 'Templates'
        $export.DisplayName   | Should -Be 'iOS Restrictions'
        $export.Configuration.passcodeMinimumLength | Should -Be 6
        $export.Assignments.Count | Should -Be 0
    }

    It 'writes one JSON file per config to -OutDir, using the DisplayName for the filename' {
        $outDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().Guid)

        $files = InModuleScope msec -Parameters @{ OutDir = $outDir } {
            param($OutDir)
            Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceConfigurations/tpl-1$' } -MockWith {
                [pscustomobject]@{ id = 'tpl-1'; displayName = 'iOS Restrictions' }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/deviceConfigurations/tpl-1/assignments' } -MockWith {
                [pscustomobject]@{ value = @() }
            }

            # Simulate a pipeline row from Get-MsecIntuneConfiguration
            [pscustomobject]@{ Id = 'tpl-1'; Source = 'Templates'; DisplayName = 'iOS Restrictions' } |
                Export-MsecIntuneConfiguration -OutDir $OutDir
        }

        $files.Count       | Should -Be 1
        $files[0].Name     | Should -Be 'iOS Restrictions.json'
        $files[0].Exists   | Should -BeTrue

        # Re-read and parse to make sure the JSON is valid.
        $json = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
        $json.Id | Should -Be 'tpl-1'

        Remove-Item -LiteralPath $outDir -Recurse -Force
    }
}
