function Connect-Msec {
    <#
    .SYNOPSIS
        Establishes a Microsoft Security session bound to a certificate in Azure Key Vault.

    .DESCRIPTION
        Use this once per PowerShell session before calling any Get-Msec* function. It:
          1. Requires you to be signed into Azure (Connect-AzAccount) - that's your *own*
             identity and is what Key Vault sees for RBAC and audit.
          2. Reads the certificate's metadata from Key Vault. New-MsecApp stamped the cert
             with two tags - AppId and TenantId - so the caller normally only needs the
             Key Vault and certificate names.
          3. Stores tenant + client IDs, vault name, key name, and thumbprint in a
             module-scoped session.
          4. Acquires the Graph and Defender tokens up front - each acquisition signs a
             fresh JWT client assertion inside Key Vault via Invoke-AzKeyVaultKeyOperation.
             The private key never leaves the vault.

        Identity resolution order:
          ClientId  ->  -ClientId param   ->  AppId tag on the cert   ->  error
          TenantId  ->  -TenantId param   ->  TenantId tag on the cert ->  Get-AzContext tenant

        Required Azure RBAC for the calling user (or group):
          - 'Key Vault Certificate User' on the vault (to read cert metadata + tags).
          - 'Key Vault Crypto User'      on the vault (to sign with the key).

        A SUCCESSFUL CONNECTION IS REMEMBERED for the tenant, so a later
        Select-MsecAzureContext into it reconnects the app session on its own rather than
        leaving the two identities pointing at different tenants. Vault name, client id and
        certificate name only - no secret, because there isn't one to store: signing happens
        inside Key Vault. Written only after the tokens have been obtained, so a saved profile
        always describes a connection that actually worked. -NoSave skips it.

    .PARAMETER NoSave
        Do not remember this connection for Select-MsecAzureContext to replay.
    .PARAMETER KeyVaultName
        The Azure Key Vault containing the certificate.
    .PARAMETER CertificateName
        The name of the certificate in Key Vault. Defaults to 'msec-app' (matches the
        default used by New-MsecApp).
    .PARAMETER ClientId
        Optional override. App registration (client) ID. Only needed if the cert was not
        tagged by New-MsecApp.
    .PARAMETER TenantId
        Optional override. Entra ID tenant ID. Only needed if the cert was not tagged by
        New-MsecApp AND the current Az context tenant is wrong.

    .EXAMPLE
        Connect-AzAccount
        Connect-Msec -KeyVaultName 'kv-mysec'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $KeyVaultName,
        [Parameter()][string] $CertificateName = 'msec-app',
        [Parameter()][string] $ClientId,
        [Parameter()][string] $TenantId,

        # Do not remember this connection for Select-MsecAzureContext to reuse.
        [Parameter()][switch] $NoSave
    )

    $azCtx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $azCtx) {
        throw 'No Azure context. Run Connect-AzAccount before Connect-Msec.'
    }

    $meta = Get-MsecCertificateMetadata -VaultName $KeyVaultName -CertificateName $CertificateName

    # Resolve ClientId: explicit param wins, else cert tag.
    if (-not $ClientId) { $ClientId = $meta.AppId }
    if (-not $ClientId) {
        throw "Could not resolve ClientId. The certificate '$CertificateName' has no 'AppId' tag and -ClientId was not provided. If the cert was created by New-MsecApp, the tag should be present; otherwise pass -ClientId explicitly."
    }

    # Resolve TenantId: explicit param > cert tag > Az context.
    if (-not $TenantId) { $TenantId = $meta.TenantId }
    if (-not $TenantId) { $TenantId = $azCtx.Tenant.Id }

    # Resolve the cloud's endpoints from the Az context (commercial, China, US Gov).
    # Pins the whole session to one cloud; switching clouds means a fresh Connect-AzAccount
    # + Connect-Msec, because a single Az session is one cloud at a time.
    $endpoints = Get-MsecEnvironment

    $script:MsecSession = @{
        TenantId        = $TenantId
        ClientId        = $ClientId
        KeyVaultName    = $KeyVaultName
        KeyName         = $meta.KeyName
        ThumbprintBytes = $meta.ThumbprintBytes
        Endpoints       = $endpoints
        Tokens          = @{}
    }

    # Prime tokens so configuration errors surface here, not deep in a Get-Msec* call.
    # Graph exists in every cloud; Defender (securitycenter) is commercial-only, so prime
    # it only where it has an endpoint (e.g. it is retired in Azure China).
    [void](Get-MsecAccessToken -Resource $endpoints.GraphResource)
    if ($endpoints.DefenderResource) {
        [void](Get-MsecAccessToken -Resource $endpoints.DefenderResource)
    }
    else {
        Write-Verbose "Defender (securitycenter) has no endpoint in $($endpoints.EnvironmentName); skipping Defender token. Defender functions will be unavailable."
    }

    # Remembered so Select-MsecAzureContext can reconnect this tenant on its own. Written only
    # after the tokens above succeeded, so a profile always describes a connection that worked
    # rather than one that was merely typed.
    if (-not $NoSave) {
        Save-MsecTenantProfile -TenantId $TenantId -KeyVaultName $KeyVaultName `
                               -ClientId $ClientId -CertificateName $CertificateName
    }

    Write-Verbose "Connected to tenant $TenantId as app $ClientId in $($endpoints.EnvironmentName) (cert: $($meta.Thumbprint))"
}
