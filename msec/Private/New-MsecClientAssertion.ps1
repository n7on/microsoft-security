function New-MsecClientAssertion {
    <#
    .SYNOPSIS
        Builds a signed JWT client assertion (RFC 7523) where the signature is produced by
        Azure Key Vault - the private key never leaves the vault.

    .DESCRIPTION
        Assembles the JWT header + payload locally, SHA-256 hashes the signing input, and
        calls Invoke-AzKeyVaultKeyOperation -Operation Sign -Algorithm RS256 on the key
        associated with the msec certificate. The returned signature bytes are base64url-
        encoded and appended to form the assertion:

            <header>.<payload>.<signature-from-kv>

        Permissions: the caller needs 'Key Vault Crypto User' on the key. The signing
        operation does not return the private key material.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $TenantId,
        [Parameter(Mandatory)][string] $ClientId,
        [Parameter(Mandatory)][string] $VaultName,
        [Parameter(Mandatory)][string] $KeyName,

        # SHA-1 thumbprint of the public cert, as raw bytes. Goes into the JWT x5t header.
        [Parameter(Mandatory)]
        [byte[]] $ThumbprintBytes,

        # Assertion lifetime in seconds; Entra accepts up to ~600.
        [Parameter()]
        [int] $LifetimeSeconds = 300
    )

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = [ordered]@{
        alg = 'RS256'
        typ = 'JWT'
        x5t = ConvertTo-MsecBase64Url -InputObject $ThumbprintBytes
    }
    $payload = [ordered]@{
        aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        iss = $ClientId
        sub = $ClientId
        jti = [guid]::NewGuid().Guid
        nbf = $now
        exp = $now + $LifetimeSeconds
    }

    $headerJson   = ($header  | ConvertTo-Json -Compress)
    $payloadJson  = ($payload | ConvertTo-Json -Compress)
    $signingInput = (ConvertTo-MsecBase64Url $headerJson) + '.' + (ConvertTo-MsecBase64Url $payloadJson)

    # SHA-256 the signing input locally; KV signs the pre-computed digest for RS256.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($signingInput))
    }
    finally {
        $sha.Dispose()
    }

    [byte[]] $sigBytes = Invoke-MsecKeyVaultSign `
        -VaultName $VaultName -KeyName $KeyName -Digest $digest -Algorithm 'RS256'

    $signingInput + '.' + (ConvertTo-MsecBase64Url $sigBytes)
}
