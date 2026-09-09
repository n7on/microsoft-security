function Invoke-MsecKeyVaultSign {
    <#
    .SYNOPSIS
        Signs a digest using a Key Vault key via the Key Vault data-plane REST API.

    .DESCRIPTION
        POSTs to https://{vault}.vault.azure.net/keys/{name}/sign?api-version=7.4 with the
        digest base64url-encoded. Returns the signature as a raw byte array.

        We call REST directly because some Az.KeyVault versions ship
        Invoke-AzKeyVaultKeyOperation with -Operation 'Sign' declared but unimplemented
        ("Not supported operation 'Sign' yet"). REST is stable across vault API versions.

        Required Azure RBAC for the *calling user*: 'Key Vault Crypto User' on the vault
        (data action Microsoft.KeyVault/vaults/keys/sign/action).

    .PARAMETER VaultName
        Short name of the Key Vault (the host becomes <name>.vault.azure.net).
    .PARAMETER KeyName
        Name of the key inside the vault.
    .PARAMETER Digest
        The pre-computed message digest (e.g. SHA-256 hash of the JWT signing input).
    .PARAMETER Algorithm
        Signing algorithm. Defaults to 'RS256' which is what Entra expects for JWT client assertions.
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][string] $VaultName,
        [Parameter(Mandatory)][string] $KeyName,
        [Parameter(Mandatory)][byte[]] $Digest,
        [Parameter()][string] $Algorithm = 'RS256'
    )

    # Key Vault data-plane endpoint for the current cloud (vault.azure.cn in China). Derive
    # from the Az context; fall back to commercial if environment resolution is unavailable.
    $envInfo    = try { Get-MsecEnvironment } catch { $null }
    $kvResource = if ($envInfo) { $envInfo.KeyVaultResource }  else { 'https://vault.azure.net' }
    $kvSuffix   = if ($envInfo) { $envInfo.KeyVaultDnsSuffix } else { 'vault.azure.net' }

    # User token for the vault (the user is the one with Crypto User on the vault).
    $tokenInfo = Get-AzAccessToken -ResourceUrl $kvResource -ErrorAction Stop
    $kvToken = if ($tokenInfo.Token -is [securestring]) {
        $tokenInfo.Token | ConvertFrom-SecureString -AsPlainText
    }
    else {
        [string]$tokenInfo.Token
    }

    $body = @{
        alg   = $Algorithm
        value = ConvertTo-MsecBase64Url -InputObject $Digest
    } | ConvertTo-Json -Compress

    Write-Verbose "POST https://$VaultName.$kvSuffix/keys/$KeyName/sign"
    $response = Invoke-RestMethod -Method Post -ErrorAction Stop `
        -Uri "https://$VaultName.$kvSuffix/keys/$KeyName/sign?api-version=7.4" `
        -Headers @{ Authorization = "Bearer $kvToken" } `
        -ContentType 'application/json' `
        -Body $body

    # Response.value is base64url. Decode to raw signature bytes.
    $padded = $response.value + ('=' * ((4 - ($response.value.Length % 4)) % 4))
    [byte[]] $sig = [Convert]::FromBase64String($padded.Replace('-', '+').Replace('_', '/'))
    $sig
}
