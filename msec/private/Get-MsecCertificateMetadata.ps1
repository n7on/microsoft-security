function Get-MsecCertificateMetadata {
    <#
    .SYNOPSIS
        Reads the certificate's public metadata from Key Vault: SHA-1 thumbprint and key name.

    .DESCRIPTION
        Used by Connect-Msec to set up the session. We do NOT pull the cert's PFX (private key);
        signing happens inside Key Vault via Invoke-AzKeyVaultKeyOperation. This call requires
        only the 'Key Vault Certificate User' role (cert read).

        Returns the SHA-1 thumbprint as both hex (informational) and bytes (used directly in the
        JWT x5t header per RFC 7515), and the key name (same as the cert name when KV created
        them together via Add-AzKeyVaultCertificate).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $VaultName,

        [Parameter(Mandatory)]
        [string] $CertificateName
    )

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw 'No Azure context. Run Connect-AzAccount before Connect-Msec.'
    }

    Write-Verbose "Reading certificate metadata for '$CertificateName' from Key Vault '$VaultName'"
    $kvCert = Get-AzKeyVaultCertificate -VaultName $VaultName -Name $CertificateName -ErrorAction Stop
    if (-not $kvCert) {
        throw "Certificate '$CertificateName' not found in Key Vault '$VaultName'."
    }

    # Thumbprint comes back as an uppercase hex string. Decode to bytes for x5t.
    $hex = $kvCert.Thumbprint
    $bytes = New-Object byte[] ($hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16)
    }

    # Tags are stamped on by New-MsecApp so Connect-Msec can recover AppId/TenantId
    # without the user having to pass them. Missing tags surface as $null - the caller decides.
    $tags = if ($kvCert.Tags) { $kvCert.Tags } else { @{} }

    [PSCustomObject]@{
        Thumbprint      = $hex
        ThumbprintBytes = [byte[]]$bytes
        KeyName         = $kvCert.Name
        AppId           = $tags['AppId']
        TenantId        = $tags['TenantId']
    }
}
