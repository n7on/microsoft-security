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
                             DeviceManagementManagedDevices.Read.All, DeviceManagementScripts.Read.All,
                             ThreatHunting.Read.All,
                             SecurityIncident.Read.All, Policy.Read.All, AuditLog.Read.All,
                             Organization.Read.All, RoleManagement.Read.Directory,
                             User.Read.All, Group.Read.All, Application.Read.All,
                             PrivilegedEligibilitySchedule.Read.AzureADGroup
          - Office 365 Exchange Online: Exchange.ManageAsApp - only with -Workload Exchange,
            and NOT sufficient on its own; see the directory role note below.
          - Office 365 SharePoint Online: Sites.Read.All - only with -Workload SharePoint.
          - Microsoft Graph: Sites.Read.All - also added by -Workload SharePoint, and NOT the
            same permission as the line above despite the name. Graph's enumerates sites;
            SharePoint's reads what is inside one. Enumerating through PnP instead would need
            Sites.FullControl.All, which is write access to every site in the tenant.
            This is a DIFFERENT permission from the identically-named one on Microsoft Graph:
            a token is issued for a resource and carries only the roles granted on THAT
            resource, so PnP presenting a SharePoint-audience token needs the SharePoint one.
          - WindowsDefenderATP: Score.Read.All, Machine.Read.All, Vulnerability.Read.All -
            commercial-only. Skipped automatically in
            clouds without a Defender for Endpoint presence (e.g. Azure China), since its
            service principal doesn't exist there; the rest of the app is still created.

        Prerequisites (the user running this command needs):
          - Azure RBAC to create certificates in the target Key Vault.
          - Microsoft Entra role allowing application creation AND admin consent of application
            permissions (Global Administrator, Privileged Role Administrator, or Application
            Administrator + Cloud Application Administrator).

    .PARAMETER DisplayName
        Display name for the new app registration. Default: 'msec'.

        EXCHANGE ALSO NEEDS A DIRECTORY ROLE, and this is the step that is easy to miss.
        Exchange.ManageAsApp is necessary but not sufficient: the app's service principal must
        also hold a directory role. Without one, Connect-MsecExchangeOnline succeeds and then
        every Get-EXO* call fails with a plain authorisation error naming no permission,
        because from Exchange's point of view the app authenticated and has no rights.

        -Workload Exchange assigns it. That is a real tenant-wide privilege grant rather than
        an API permission, which is why the workloads are opt-in and why creating the
        assignment needs Privileged Role Administrator - a higher bar than the rest of this
        command. If the caller lacks it, everything else is still configured and a warning says
        exactly what to assign by hand.

    .PARAMETER Workload
        Extra workloads to configure: Exchange, SharePoint, or both. Omitted by default -
        each needs fresh admin consent, and Exchange needs a directory role.

    .PARAMETER ExchangeDirectoryRole
        Which directory role to give the app for Exchange. Default 'Global Reader', the
        least-privilege option that can read mailbox permissions.
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
        [Parameter()][ValidateRange(1, 24)][int] $ValidityMonths = 24,

        # Workloads beyond Graph and Defender. OPT-IN, and deliberately not the default:
        #
        #   Exchange   needs Exchange.ManageAsApp AND a DIRECTORY ROLE on the app's service
        #              principal. A directory role is a real privilege grant, it is not
        #              something to hand out as a side effect of running a bootstrap, and
        #              creating one needs Privileged Role Administrator - a higher bar than
        #              the rest of this command.
        #   SharePoint needs Sites.Read.All on the SHAREPOINT service principal, which is a
        #              different permission from the identically-named one on Microsoft Graph.
        #
        # Both need fresh admin consent. Ask for them only when the Exchange or SharePoint
        # commands are actually going to be used.
        [Parameter()]
        [ValidateSet('Exchange', 'SharePoint')]
        [string[]] $Workload,

        # The directory role to give the app for Exchange. Global Reader is the least-privilege
        # option that works for reading mailbox permissions; Exchange Administrator is the
        # alternative and grants far more than this module needs.
        [Parameter()]
        [ValidateSet('Global Reader', 'Exchange Administrator', 'Exchange Recipient Administrator')]
        [string] $ExchangeDirectoryRole = 'Global Reader'
    )

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) {
        throw 'No Azure context. Run Connect-AzAccount before New-MsecApp.'
    }
    $tenantId = $ctx.Tenant.Id

    # Cloud endpoints for the current context (China, US Gov, commercial). The well-known
    # permission resource appIds assigned below are constant across clouds; only the HTTP
    # endpoint to call Graph differs. DefenderResource is null where Defender for Endpoint
    # has no presence (e.g. retired in Azure China) - we use that to skip its permission.
    $envInfo   = Get-MsecEnvironment
    $graphBase = $envInfo.GraphResource

    Write-Verbose 'Acquiring Graph token via Az.Accounts (your identity, not the app)'
    $tokenInfo = Get-AzAccessToken -ResourceUrl $graphBase -ErrorAction Stop
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
        $uri = if ($Path -like 'https://*') { $Path } else { "$graphBase$Path" }
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
                'DeviceManagementManagedDevices.Read.All',# Intune managed devices (Get-MsecIntuneDevice)
                # Intune SCRIPTS are a separate scope from Intune configuration, which is not
                # obvious from the endpoint paths: deviceHealthScripts and
                # deviceCustomAttributeShellScripts both sit under /deviceManagement alongside
                # the configuration policies, but DeviceManagementConfiguration.Read.All does
                # not cover them and they 403 without this (Get-MsecIntuneScriptResult).
                'DeviceManagementScripts.Read.All',
                'ThreatHunting.Read.All',                 # Advanced hunting / EmailEvents (Get-MsecDefenderEmailStats)
                'SecurityIncident.Read.All',              # Defender XDR incidents (Get-MsecDefenderIncidentStats)
                'Policy.Read.All',                        # CA policies + tenant security settings (Get-MsecEntraConditionalAccessPolicy, Get-MsecEntraTenantSecuritySetting)
                'AuditLog.Read.All',                      # Sign-in logs + MFA registration report (Get-MsecEntraConditionalAccessSignInLog, Get-MsecEntraMfaRegistration) - both also need Entra ID P1/P2 on the tenant
                'Organization.Read.All',                  # Licence SKUs / service plans (Get-MsecEntraLicense) - tells "unlicensed" apart from "no permission"
                'RoleManagement.Read.Directory',          # Directory role assignments + eligibility (Get-MsecEntraRoleHolder)
                # Reading role assignments and reading the identities they point at are
                # SEPARATE grants. With RoleManagement.Read.Directory alone, Graph returns
                # every assignment but each principal as an id-and-type shell with all
                # properties null - a privileged-access report that is complete and
                # entirely anonymous. These three name the principals; Group.Read.All also
                # covers expanding role-assignable groups to the users inside them.
                'User.Read.All',                          # Name user principals (Get-MsecEntraRoleHolder)
                'Group.Read.All',                         # Name groups + read their transitive members (Get-MsecEntraRoleHolder)
                'Application.Read.All',                   # Name service principals holding privileged roles (Get-MsecEntraRoleHolder)
                # PIM for Groups. A PIM-governed group has ELIGIBLE members, who are
                # absent from /transitiveMembers entirely - so without this the group
                # reads as empty and everyone who can activate into a role-carrying
                # group is missing from the inventory (Get-MsecEntraRoleHolder).
                'PrivilegedEligibilitySchedule.Read.AzureADGroup'
            )
        }
    )

    # WindowsDefenderATP (Defender for Endpoint) is commercial-only. Its service principal
    # doesn't exist in clouds where Defender has no presence (e.g. Azure China), so resolving
    # it would 404 and abort the whole bootstrap. Add it only where Defender is available;
    # the Defender-backed functions (Get-MsecDefenderScore*) simply won't apply elsewhere.
    if ($envInfo.DefenderResource) {
        $resources += @{
            Name       = 'WindowsDefenderATP'
            AppId      = 'fc780465-2017-40d4-a0c5-307022471b92'
            RoleValues = @(
                'Score.Read.All',          # Defender exposure + device config score
                'Machine.Read.All',        # the device inventory behind Get-MsecDefenderDevice
                'Vulnerability.Read.All'   # the per-device vulnerability assessment export
            )
        }
    }
    else {
        Write-Warning "Defender for Endpoint is not available in '$($envInfo.EnvironmentName)' - skipping the WindowsDefenderATP permissions (Score.Read.All, Machine.Read.All, Vulnerability.Read.All). Defender score, device and vulnerability functions will be unavailable in this cloud."
    }

    # Exchange and SharePoint, when asked for. Their permissions live on their OWN service
    # principals, not on Microsoft Graph - a token is issued FOR a resource and carries only
    # the roles granted on that resource, so Graph's User.Read.All buys nothing in either.
    #
    # Sites.Read.All in particular exists on BOTH Microsoft Graph and the SharePoint service
    # principal, with the same name and different meanings. PnP presents a SharePoint-audience
    # token, so it is the SharePoint one that matters; granting the Graph one looks correct in
    # the portal and still fails.
    if ($Workload -contains 'Exchange') {
        $resources += @{
            Name       = 'Office 365 Exchange Online'
            AppId      = '00000002-0000-0ff1-ce00-000000000000'
            RoleValues = @('Exchange.ManageAsApp')   # necessary, and NOT sufficient - see the role assignment below
        }
    }
    if ($Workload -contains 'SharePoint') {
        $resources += @{
            Name       = 'Office 365 SharePoint Online'
            AppId      = '00000003-0000-0ff1-ce00-000000000000'
            RoleValues = @('Sites.Read.All')
        }

        # AND the Graph one, which despite the identical name is a separate permission on a
        # separate resource. Both are needed and they do different jobs:
        #
        #   SharePoint's  reads a site's CONTENTS through PnP - its own Owners/Members groups,
        #                 which Graph does not expose at all.
        #   Graph's       ENUMERATES sites. The alternative is Get-PnPTenantSite, which talks to
        #                 the SharePoint tenant-admin API and accepts nothing less than
        #                 Sites.FullControl.All - full write and delete over every site in the
        #                 tenant, for a list of site names. Not a trade worth making for a
        #                 read-only module.
        $graphResource = $resources | Where-Object Name -eq 'Microsoft Graph' | Select-Object -First 1
        if ($graphResource -and $graphResource.RoleValues -notcontains 'Sites.Read.All') {
            $graphResource.RoleValues += 'Sites.Read.All'
        }
    }

    # Resolve each requested role to its app-role GUID. Sovereign clouds (notably Azure
    # China) expose a REDUCED set of Microsoft Graph app roles - some security permissions
    # like SecurityEvents.Read.All simply don't exist there. Rather than hard-fail on the
    # first missing role (which would block the whole app), warn and skip the ones this
    # cloud doesn't offer, then proceed with whatever subset is available - same philosophy
    # as the Defender skip above. Functions needing a skipped permission won't work here.
    $missingRoles = @()
    foreach ($r in $resources) {
        Write-Verbose "Resolving $($r.Name) service principal and app roles"

        # A resource whose service principal is absent must not abort the whole bootstrap. It
        # happens for real: a tenant with no Exchange Online, a sovereign cloud without
        # SharePoint. Same philosophy as the Defender skip - warn, drop that resource, and
        # configure everything else.
        $sp = $null
        try { $sp = & $graph GET "/v1.0/servicePrincipals(appId='$($r.AppId)')" }
        catch {
            Write-Warning "The '$($r.Name)' service principal (appId $($r.AppId)) could not be resolved in this tenant, so its permissions are skipped: $($_.Exception.Message)"
            $missingRoles += @($r.RoleValues | ForEach-Object { "$($r.Name): $_ (service principal not found)" })
            $r.ResourceSpId = $null
            $r.Roles = @()
            continue
        }

        $r.ResourceSpId = $sp.id
        $r.Roles = @(foreach ($rv in $r.RoleValues) {
            $role = $sp.appRoles | Where-Object {
                $_.value -eq $rv -and $_.allowedMemberTypes -contains 'Application'
            } | Select-Object -First 1
            if ($role) {
                [PSCustomObject]@{ Value = $rv; Id = $role.id }
            }
            else {
                $missingRoles += "$($r.Name): $rv"
            }
        })
    }

    if ($missingRoles) {
        Write-Warning (
            "These app roles are not available in '$($envInfo.EnvironmentName)' and will be skipped - " +
            "msec functions that need them won't work in this cloud:`n  - " + ($missingRoles -join "`n  - "))
    }

    # Drop resources left with no available roles - nothing to request or consent for them.
    # Existing requiredResourceAccess entries for such resources are preserved untouched by
    # the merge below (they fall through the 'else' branch), so re-runs don't clobber them.
    $resources = @($resources | Where-Object { $_.Roles.Count -gt 0 })
    if ($resources.Count -eq 0) {
        throw "None of the required app roles are available in '$($envInfo.EnvironmentName)'; cannot configure the app."
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
    # NB: this GET is not paged. Graph returns up to 100 assignments by default and msec asks
    # for around fifteen, so a second page would mean the app had been granted a great deal
    # more than this module needs - worth knowing if that ever becomes true.
    $existingAssignments = & $graph GET "/v1.0/servicePrincipals/$($appSp.id)/appRoleAssignments"
    $existingPairs = @{}
    foreach ($a in @($existingAssignments.value)) {
        $existingPairs["$($a.resourceId)|$($a.appRoleId)"] = $true
    }

    # Tracked rather than merely logged. This step used to report only through
    # Write-Verbose, which meant a re-run that added a dozen permissions printed one line
    # about finding the app and nothing whatsoever about the grants - indistinguishable,
    # from the outside, from having done nothing at all.
    $grantedNow     = [System.Collections.Generic.List[string]]::new()
    $alreadyGranted = [System.Collections.Generic.List[string]]::new()

    foreach ($r in $resources) {
        foreach ($role in $r.Roles) {
            $label = "$($r.Name): $($role.Value)"
            $pair  = "$($r.ResourceSpId)|$($role.Id)"
            if ($existingPairs.ContainsKey($pair)) {
                Write-Verbose "Already consented: $label"
                $alreadyGranted.Add($label)
                continue
            }
            Write-Verbose "Granting admin consent: $label"
            & $graph POST "/v1.0/servicePrincipals/$($appSp.id)/appRoleAssignments" @{
                principalId = $appSp.id
                resourceId  = $r.ResourceSpId
                appRoleId   = $role.Id
            } | Out-Null
            $grantedNow.Add($label)
        }
    }

    # ---- 8. Say what happened ----------------------------------------------------------
    Write-Host "Permissions: $($grantedNow.Count) granted now, $($alreadyGranted.Count) already present$(if ($missingRoles) { ", $(@($missingRoles).Count) unavailable in this cloud" })."
    foreach ($g in $grantedNow) { Write-Host "  + $g" }

    if ($grantedNow.Count) {
        # The grant is immediate, but a token already issued does not carry it - consent
        # applies to tokens minted afterwards. Anyone who re-runs this to fix a 403 and then
        # retries the same command in the same session hits the identical 403 and concludes
        # the grant did not work, so this is the one instruction that has to be loud.
        Write-Host ''
        Write-Host 'Run Disconnect-Msec then Connect-Msec to pick up the new permissions - a cached token predates the grant and will still be refused.' -ForegroundColor Yellow
    }

    # ---- Exchange needs a DIRECTORY ROLE, not just an app role -------------------------------
    #
    # This is the step people miss, and Exchange gives no help finding it: with
    # Exchange.ManageAsApp granted and consented but no directory role, every EXO cmdlet fails
    # with a plain authorisation error that names no missing permission. From Exchange's point
    # of view the app authenticated correctly and simply has no rights.
    #
    # A directory role is a REAL privilege grant on the tenant, which is why the whole thing is
    # behind -Workload rather than being done by default, and why it is confirmed separately
    # below. Global Reader is the least-privilege option that can read mailbox permissions.
    $directoryRole = $null

    if ($Workload -contains 'Exchange') {
        $roleAssigned = $false
        try {
            # Role DEFINITIONS are per tenant but their templateIds are well known. Resolved by
            # displayName so this does not carry a table of GUIDs that drift.
            $filter = [uri]::EscapeDataString("displayName eq '$ExchangeDirectoryRole'")
            $definition = @((& $graph GET "/v1.0/roleManagement/directory/roleDefinitions?`$filter=$filter").value)[0]

            if (-not $definition) {
                Write-Warning "The directory role '$ExchangeDirectoryRole' does not exist in this tenant, so it was NOT assigned. Exchange commands will fail until the app holds a directory role."
            }
            else {
                # Already assigned? Re-running must be a no-op, like the rest of this command.
                $assignFilter = [uri]::EscapeDataString("principalId eq '$($appSp.id)' and roleDefinitionId eq '$($definition.id)'")
                $existing = @((& $graph GET "/v1.0/roleManagement/directory/roleAssignments?`$filter=$assignFilter").value)

                if ($existing.Count) {
                    $roleAssigned = $true
                    $directoryRole = "$ExchangeDirectoryRole (already assigned)"
                    Write-Host "  Directory role '$ExchangeDirectoryRole' already assigned." -ForegroundColor DarkGray
                }
                else {
                    Write-Host ''
                    Write-Host "About to assign the DIRECTORY ROLE '$ExchangeDirectoryRole' to this app." -ForegroundColor Yellow
                    Write-Host '  This is a tenant-wide privilege grant, not an API permission. Exchange will not' -ForegroundColor Yellow
                    Write-Host '  work without it, but it is worth knowing you are making it.' -ForegroundColor Yellow

                    & $graph POST '/v1.0/roleManagement/directory/roleAssignments' @{
                        '@odata.type'    = '#microsoft.graph.unifiedRoleAssignment'
                        roleDefinitionId = $definition.id
                        principalId      = $appSp.id
                        directoryScopeId = '/'
                    } | Out-Null

                    $roleAssigned = $true
                    $directoryRole = $ExchangeDirectoryRole
                    Write-Host "  Assigned directory role '$ExchangeDirectoryRole'." -ForegroundColor Green
                }
            }
        }
        catch {
            # Creating a role assignment needs Privileged Role Administrator - a higher bar than
            # the rest of this command, so the caller may legitimately not have it. Said clearly
            # rather than failing the whole bootstrap, since everything else did work.
            Write-Warning "Could not assign the directory role '$ExchangeDirectoryRole' to the app. Exchange commands will fail until someone with Privileged Role Administrator assigns it - in the portal: Entra ID > Roles and administrators > $ExchangeDirectoryRole > Add assignment > pick the '$($app.displayName)' application. Original error: $($_.Exception.Message)"
        }

        if (-not $roleAssigned) {
            Write-Warning "Exchange.ManageAsApp on its own is NOT enough. Until the app holds a directory role, Connect-MsecExchangeOnline will connect and every Get-EXO* call will then fail with an authorisation error that names nothing."
        }
    }

    [PSCustomObject]@{
        TenantId        = $tenantId
        ClientId        = $clientId
        KeyVaultName    = $KeyVaultName
        CertificateName = $CertificateName
        AppObjectId     = $app.id
        DisplayName     = $app.displayName

        # Returned as well as printed, so a caller can assert on them rather than scrape
        # the console - and so the tests can pin this behaviour.
        GrantedNow      = $grantedNow.ToArray()
        AlreadyGranted  = $alreadyGranted.ToArray()
        UnavailableRoles = @($missingRoles)
        # Null unless -Workload included Exchange. Worth asserting on: it is the difference
        # between an Exchange connection that works and one that authenticates and then fails.
        DirectoryRole   = $directoryRole
    }
}
