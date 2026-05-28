function New-MsecApp {
    <#
    .SYNOPSIS
        One-time setup. Creates the msec app registration, generates a self-signed certificate
        in Azure Key Vault, attaches it to the app, and grants admin consent for the required
        Graph and Defender application permissions.

    .DESCRIPTION
        Steps performed (idempotent only at the high level - re-running creates fresh resources):
          1. Verifies an Azure context (Connect-AzAccount must have been run first).
          2. Acquires a Microsoft Graph access token for *the user* via Az.Accounts and uses it
             for all Graph create/consent calls (we cannot use the app's own token here - the
             app does not exist yet).
          3. Resolves the Graph and Defender resource service principals + their app role IDs
             by name (so we do not hardcode role GUIDs).
          4. Creates the app registration with the required application permissions declared.
          5. Creates a service principal for the new app in the tenant.
          6. Issues a self-signed certificate inside the named Key Vault (policy: RSA 2048,
             24-month validity, exportable). Waits for issuance to complete.
          7. Attaches the certificate's public key to the app as a keyCredential.
          8. Grants admin consent by creating appRoleAssignments from the new SP to each
             resource SP / app role.
          9. Returns an object with TenantId, ClientId, KeyVaultName, CertificateName -
             everything Connect-Msec needs.

        Prerequisites (the user running this command needs):
          - Azure RBAC to create certificates in the target Key Vault.
          - Microsoft Entra role allowing application creation AND admin consent of application
            permissions (Global Administrator, Privileged Role Administrator, or Application
            Administrator + Cloud Application Administrator).

    .PARAMETER DisplayName
        Display name for the new app registration. Default: 'msec'.

    .PARAMETER KeyVaultName
        Name of an existing Azure Key Vault that will store the certificate.

    .PARAMETER CertificateName
        Name of the certificate object inside Key Vault. Default: 'msec-app'.

    .PARAMETER ValidityMonths
        Certificate lifetime in months. Default: 24.

    .EXAMPLE
        Connect-AzAccount
        $app = New-MsecApp -KeyVaultName 'kv-mysec'
        # Hand $app.TenantId / $app.ClientId / $app.KeyVaultName / $app.CertificateName to anyone
        # who should run reports; they Connect-Msec with those values.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string] $DisplayName = 'msec',
        [Parameter(Mandatory)][string] $KeyVaultName,
        [Parameter()][string] $CertificateName = 'msec-app',
        [Parameter()][ValidateRange(1, 24)][int] $ValidityMonths = 24
    )

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) {
        throw 'No Azure context. Run Connect-AzAccount before New-MsecApp.'
    }
    $tenantId = $ctx.Tenant.Id

    Write-Verbose 'Acquiring Graph token via Az.Accounts (your identity, not the app)'
    $tokenInfo = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -ErrorAction Stop
    $userGraphToken = if ($tokenInfo.Token -is [securestring]) {
        $tokenInfo.Token | ConvertFrom-SecureString -AsPlainText
    }
    else {
        $tokenInfo.Token
    }

    # Local Graph caller using the user's token (the module's Invoke-MsecGraphRequest needs a
    # session that does not exist yet).
    $graph = {
        param($Method, $Path, $Body)
        $uri = if ($Path -like 'https://*') { $Path } else { "https://graph.microsoft.com$Path" }
        $p = @{
            Method      = $Method
            Uri         = $uri
            Headers     = @{ Authorization = "Bearer $userGraphToken" }
            ErrorAction = 'Stop'
        }
        if ($null -ne $Body) {
            $p['ContentType'] = 'application/json'
            $p['Body'] = ($Body | ConvertTo-Json -Depth 20)
        }
        Invoke-RestMethod @p
    }

    # ---- 1. Resolve resource SPs + app role IDs by name (no hardcoded role GUIDs) ----
    $resources = @(
        @{ Name = 'Microsoft Graph';       AppId = '00000003-0000-0000-c000-000000000000'; RoleValue = 'SecurityEvents.Read.All' }
        @{ Name = 'WindowsDefenderATP';    AppId = 'fc780465-2017-40d4-a0c5-307022471b92'; RoleValue = 'Score.Read.All' }
    )

    foreach ($r in $resources) {
        Write-Verbose "Resolving $($r.Name) service principal and '$($r.RoleValue)' app role"
        $sp = & $graph GET "/v1.0/servicePrincipals(appId='$($r.AppId)')"
        $role = $sp.appRoles | Where-Object { $_.value -eq $r.RoleValue -and $_.allowedMemberTypes -contains 'Application' } | Select-Object -First 1
        if (-not $role) {
            throw "Could not find app role '$($r.RoleValue)' on $($r.Name) ($($r.AppId))."
        }
        $r.ResourceSpId = $sp.id
        $r.RoleId      = $role.id
    }

    # ---- 2. Create the application with required resource access declared ----
    $requiredResourceAccess = $resources | ForEach-Object {
        @{
            resourceAppId  = $_.AppId
            resourceAccess = @(@{ id = $_.RoleId; type = 'Role' })
        }
    }

    Write-Verbose "Creating app registration '$DisplayName'"
    $app = & $graph POST '/v1.0/applications' @{
        displayName            = $DisplayName
        signInAudience         = 'AzureADMyOrg'
        requiredResourceAccess = $requiredResourceAccess
    }
    $clientId = $app.appId
    Write-Host "Created app: $($app.displayName) ($clientId)"

    # ---- 3. Create the matching service principal ----
    Write-Verbose 'Creating service principal for the new app'
    $appSp = & $graph POST '/v1.0/servicePrincipals' @{ appId = $clientId }

    # ---- 4. Issue self-signed certificate in Key Vault ----
    Write-Verbose "Issuing self-signed certificate '$CertificateName' in Key Vault '$KeyVaultName'"
    $policy = New-AzKeyVaultCertificatePolicy `
        -SecretContentType 'application/x-pkcs12' `
        -SubjectName "CN=$DisplayName" `
        -IssuerName 'Self' `
        -ValidityInMonths $ValidityMonths `
        -KeyType 'RSA' -KeySize 2048 `
        -ReuseKeyOnRenewal:$false

    Add-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName -CertificatePolicy $policy | Out-Null

    # Poll until the cert is ready (usually a few seconds for self-signed).
    $deadline = [DateTime]::UtcNow.AddMinutes(2)
    do {
        Start-Sleep -Seconds 2
        $op = Get-AzKeyVaultCertificateOperation -VaultName $KeyVaultName -Name $CertificateName -ErrorAction Stop
    } until ($op.Status -eq 'completed' -or [DateTime]::UtcNow -gt $deadline)

    if ($op.Status -ne 'completed') {
        throw "Key Vault certificate issuance did not complete in time (last status: $($op.Status))."
    }

    $kvCert = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName -ErrorAction Stop
    $publicCertB64 = [Convert]::ToBase64String($kvCert.Certificate.RawData)

    # Stamp the app identity onto the cert so Connect-Msec can recover it without the user
    # passing TenantId / ClientId every time.
    Write-Verbose 'Tagging certificate with AppId / TenantId'
    Update-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName `
        -Tag @{ AppId = $clientId; TenantId = $tenantId } -PassThru | Out-Null

    # ---- 5. Attach the cert to the app as a key credential ----
    Write-Verbose 'Attaching certificate to the app registration'
    & $graph PATCH "/v1.0/applications/$($app.id)" @{
        keyCredentials = @(@{
            type        = 'AsymmetricX509Cert'
            usage       = 'Verify'
            displayName = $CertificateName
            key         = $publicCertB64
        })
    } | Out-Null

    # ---- 6. Grant admin consent: appRoleAssignments from our SP to each resource SP/role ----
    foreach ($r in $resources) {
        Write-Verbose "Granting admin consent: $($r.Name) -> $($r.RoleValue)"
        & $graph POST "/v1.0/servicePrincipals/$($appSp.id)/appRoleAssignments" @{
            principalId = $appSp.id
            resourceId  = $r.ResourceSpId
            appRoleId   = $r.RoleId
        } | Out-Null
    }

    [PSCustomObject]@{
        TenantId        = $tenantId
        ClientId        = $clientId
        KeyVaultName    = $KeyVaultName
        CertificateName = $CertificateName
        AppObjectId     = $app.id
        DisplayName     = $app.displayName
    }
}
