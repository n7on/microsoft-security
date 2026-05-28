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
