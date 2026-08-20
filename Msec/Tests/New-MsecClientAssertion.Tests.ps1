#Requires -Module Pester
#
# Tests for New-MsecClientAssertion. Signing is delegated to Key Vault (via
# Invoke-MsecKeyVaultSign), so the private key never touches local disk - these
# tests mock that call and verify:
#   1. The JWT header carries alg=RS256, typ=JWT, x5t = base64url(thumbprint).
#   2. The JWT payload carries the right aud/iss/sub.
#   3. The digest passed to KV is SHA-256 of "<header>.<payload>".
#   4. The signature bytes returned by KV land verbatim in the JWT.

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
