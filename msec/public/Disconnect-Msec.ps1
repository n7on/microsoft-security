function Disconnect-Msec {
    <#
    .SYNOPSIS
        Clears the Microsoft Security session (cached tokens and key/vault references).

    .DESCRIPTION
        Drops the module-scoped session that Connect-Msec created: the tenant and client
        ids, the Key Vault and key names, the certificate thumbprint, and every cached
        access token.

        Nothing is revoked. The tokens already issued remain valid at the API until they
        expire on their own - this only forgets them locally, so the next command has to
        acquire a fresh one. That is what makes it the fix for a permission that was
        granted after the session started: consent does not apply to a token that was
        already minted, so the cached one has to go.

        Safe to call when there is no session.

    .EXAMPLE
        Disconnect-Msec

    .EXAMPLE
        # Pick up a newly consented permission without restarting the shell.
        Disconnect-Msec
        Connect-Msec -KeyVaultName kv-msec -TenantId $tenant -ClientId $client

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param()

    $script:MsecSession = $null
    Write-Verbose 'Msec session cleared.'
}
