function New-MsecApp {
    <#
    .SYNOPSIS
        Sets up (or updates) the msec app registration: app + service principal + certificate
        in Key Vault + admin consent. Safe to re-run.

    .DESCRIPTION
        Idempotent. Re-run this whenever permissions change (e.g. when msec adds a new
        Graph scope) and it will *adjust* the existing app rather than creating a duplicate.
        Concretely each step is find-or-create / merge-don't-clobber:

          1. Verifies an Azure context (Connect-AzAccount must have been run first).
          2. Acquires a Microsoft Graph access token for *the user* via Az.Accounts and uses
             it for all Graph create/consent calls (we cannot use the app's own token here -
             the app may not exist yet).
          3. Resolves the Graph and Defender resource service principals + the app role IDs
             for every required permission, by name (no hardcoded role GUIDs).
          4. Finds an app registration by displayName, or creates one if missing.
          5. PATCHes requiredResourceAccess - existing entries for unrelated resources are
             preserved; for Graph / WindowsDefenderATP, missing role IDs are added.
          6. Finds or creates the matching service principal.
          7. Finds or issues the self-signed certificate inside the named Key Vault.
          8. Stamps the cert with AppId / TenantId tags (overwrites - idempotent).
          9. Attaches the cert to the app only if a credential with that thumbprint is not
             already present.
         10. Grants admin consent by creating appRoleAssignments - only for (resource, role)
             pairs not already assigned.
         11. Returns an object with TenantId, ClientId, KeyVaultName, CertificateName.

        Current required permissions (configured at the top of the function in $resources):
          - Microsoft Graph: SecurityEvents.Read.All, DeviceManagementConfiguration.Read.All,
                             ThreatHunting.Read.All, SecurityIncident.Read.All
          - WindowsDefenderATP: Score.Read.All

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
    # Each resource can declare multiple roles. Add new permissions here when needed.
    $resources = @(
        @{
            Name       = 'Microsoft Graph'
            AppId      = '00000003-0000-0000-c000-000000000000'
            RoleValues = @(
                'SecurityEvents.Read.All',                # Microsoft Secure Score (Graph)
                'DeviceManagementConfiguration.Read.All', # Intune configurations / compliance policies
                'ThreatHunting.Read.All',                 # Advanced hunting / EmailEvents (Get-MsecDefenderEmailStats)
                'SecurityIncident.Read.All'               # Defender XDR incidents (Get-MsecDefenderIncidentStats)
            )
        }
        @{
            Name       = 'WindowsDefenderATP'
            AppId      = 'fc780465-2017-40d4-a0c5-307022471b92'
            RoleValues = @('Score.Read.All')              # Defender exposure + device config score
        }
    )

    foreach ($r in $resources) {
        Write-Verbose "Resolving $($r.Name) service principal and app roles"
        $sp = & $graph GET "/v1.0/servicePrincipals(appId='$($r.AppId)')"
        $r.ResourceSpId = $sp.id
        $r.Roles = foreach ($rv in $r.RoleValues) {
            $role = $sp.appRoles | Where-Object {
                $_.value -eq $rv -and $_.allowedMemberTypes -contains 'Application'
            } | Select-Object -First 1
            if (-not $role) {
                throw "Could not find app role '$rv' on $($r.Name) ($($r.AppId))."
            }
            [PSCustomObject]@{ Value = $rv; Id = $role.id }
        }
    }

    # ---- 2. Find-or-create the application (idempotent) ----
    $existingApps = & $graph GET "/v1.0/applications?`$filter=displayName eq '$DisplayName'"
    if ($existingApps.value -and $existingApps.value.Count -gt 0) {
        if ($existingApps.value.Count -gt 1) {
            Write-Warning "Multiple apps named '$DisplayName' exist; using the first ($($existingApps.value[0].appId))."
        }
        $app = $existingApps.value[0]
        Write-Host "Found existing app: $($app.displayName) ($($app.appId))"
    }
    else {
        $app = & $graph POST '/v1.0/applications' @{
            displayName    = $DisplayName
            signInAudience = 'AzureADMyOrg'
        }
        Write-Host "Created app: $($app.displayName) ($($app.appId))"
    }
    $clientId = $app.appId

    # ---- 3. Ensure requiredResourceAccess includes every desired role (merge, don't clobber) ----
    $desiredByResource = @{}
    foreach ($r in $resources) {
        $desiredByResource[$r.AppId] = @($r.Roles | ForEach-Object { @{ id = $_.Id; type = 'Role' } })
    }

    $newRRA = @()
    $touched = @{}
    foreach ($entry in @($app.requiredResourceAccess)) {
        if ($desiredByResource.ContainsKey($entry.resourceAppId)) {
            $existingIds = @($entry.resourceAccess | ForEach-Object { $_.id })
            $merged = @($entry.resourceAccess | ForEach-Object { @{ id = $_.id; type = $_.type } })
            foreach ($d in $desiredByResource[$entry.resourceAppId]) {
                if ($d.id -notin $existingIds) { $merged += $d }
            }
            $newRRA += @{ resourceAppId = $entry.resourceAppId; resourceAccess = $merged }
            $touched[$entry.resourceAppId] = $true
        }
        else {
            $newRRA += $entry
        }
    }
    foreach ($k in $desiredByResource.Keys) {
        if (-not $touched.ContainsKey($k)) {
            $newRRA += @{ resourceAppId = $k; resourceAccess = $desiredByResource[$k] }
        }
    }
    Write-Verbose 'Patching requiredResourceAccess (merged with any existing entries)'
    & $graph PATCH "/v1.0/applications/$($app.id)" @{ requiredResourceAccess = $newRRA } | Out-Null

    # ---- 4. Find-or-create the matching service principal ----
    $existingSp = & $graph GET "/v1.0/servicePrincipals?`$filter=appId eq '$clientId'"
    $appSp = if ($existingSp.value -and $existingSp.value.Count -gt 0) {
        Write-Verbose "Reusing existing service principal $($existingSp.value[0].id)"
        $existingSp.value[0]
    }
    else {
        Write-Verbose 'Creating service principal for the app'
        & $graph POST '/v1.0/servicePrincipals' @{ appId = $clientId }
    }

    # ---- 5. Find-or-create the certificate in Key Vault ----
    $kvCert = try {
        Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName -ErrorAction Stop
    }
    catch { $null }

    if ($kvCert) {
        Write-Verbose "Using existing certificate '$CertificateName' (thumbprint $($kvCert.Thumbprint))"
    }
    else {
        Write-Verbose "Issuing self-signed certificate '$CertificateName' in Key Vault '$KeyVaultName'"
        $policy = New-AzKeyVaultCertificatePolicy `
            -SecretContentType 'application/x-pkcs12' `
            -SubjectName "CN=$DisplayName" `
            -IssuerName 'Self' `
            -ValidityInMonths $ValidityMonths `
            -KeyType 'RSA' -KeySize 2048 `
            -ReuseKeyOnRenewal:$false

        Add-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName -CertificatePolicy $policy | Out-Null

        $deadline = [DateTime]::UtcNow.AddMinutes(2)
        do {
            Start-Sleep -Seconds 2
            $op = Get-AzKeyVaultCertificateOperation -VaultName $KeyVaultName -Name $CertificateName -ErrorAction Stop
        } until ($op.Status -eq 'completed' -or [DateTime]::UtcNow -gt $deadline)

        if ($op.Status -ne 'completed') {
            throw "Key Vault certificate issuance did not complete in time (last status: $($op.Status))."
        }
        $kvCert = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName -ErrorAction Stop
    }

    # Tags overwrite each run - idempotent.
    Write-Verbose 'Tagging certificate with AppId / TenantId'
    Update-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName `
        -Tag @{ AppId = $clientId; TenantId = $tenantId } -PassThru | Out-Null

    # ---- 6. Attach the cert to the app (only if a credential with this thumbprint isn't already there) ----
    $thumbBytes = New-Object byte[] ($kvCert.Thumbprint.Length / 2)
    for ($i = 0; $i -lt $thumbBytes.Length; $i++) {
        $thumbBytes[$i] = [Convert]::ToByte($kvCert.Thumbprint.Substring($i * 2, 2), 16)
    }
    $thumbB64 = [Convert]::ToBase64String($thumbBytes)
    $alreadyAttached = @($app.keyCredentials) | Where-Object { $_.customKeyIdentifier -eq $thumbB64 }

    if ($alreadyAttached) {
        Write-Verbose 'Certificate already attached to app - skipping keyCredentials patch'
    }
    else {
        Write-Verbose 'Attaching certificate to the app registration'
        $publicCertB64 = [Convert]::ToBase64String($kvCert.Certificate.RawData)
        # NB: Graph treats keyCredentials as a replacement collection AND returns existing entries
        # with `key=null` on read, so we can't safely re-include them. We replace with just our
        # credential. The msec app is dedicated to this purpose, so this is acceptable.
        & $graph PATCH "/v1.0/applications/$($app.id)" @{
            keyCredentials = @(@{
                type        = 'AsymmetricX509Cert'
                usage       = 'Verify'
                displayName = $CertificateName
                key         = $publicCertB64
            })
        } | Out-Null
    }

    # ---- 7. Grant admin consent for any (resource, role) pair not already assigned ----
    $existingAssignments = & $graph GET "/v1.0/servicePrincipals/$($appSp.id)/appRoleAssignments"
    $existingPairs = @{}
    foreach ($a in @($existingAssignments.value)) {
        $existingPairs["$($a.resourceId)|$($a.appRoleId)"] = $true
    }
    foreach ($r in $resources) {
        foreach ($role in $r.Roles) {
            $pair = "$($r.ResourceSpId)|$($role.Id)"
            if ($existingPairs.ContainsKey($pair)) {
                Write-Verbose "Already consented: $($r.Name) -> $($role.Value)"
                continue
            }
            Write-Verbose "Granting admin consent: $($r.Name) -> $($role.Value)"
            & $graph POST "/v1.0/servicePrincipals/$($appSp.id)/appRoleAssignments" @{
                principalId = $appSp.id
                resourceId  = $r.ResourceSpId
                appRoleId   = $role.Id
            } | Out-Null
        }
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
