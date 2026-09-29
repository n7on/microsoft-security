function Grant-MsecAzureDevOpsPermission {
    <#
    .SYNOPSIS
        Grants an Azure DevOps permission to an identity or group, at organization or project
        scope. Runs as YOU - one-time setup, not something the app can do for itself.

    .DESCRIPTION
        Some things msec needs cannot be granted through Entra. New-MsecApp handles API
        permissions and directory roles; Azure DevOps keeps its own permission system, and an
        app that is a member of the organization still reads nothing until permissions are set
        INSIDE Azure DevOps. This is the other half.

        IT RUNS AS YOU, NOT AS THE APP, and that is not a detail. The app is usually the
        GRANTEE, and an identity that could grant itself permissions would make the whole
        exercise circular. Managing permissions in Azure DevOps needs Project Collection
        Administrator or equivalent, which a person has and the app should not.

        NO PERSONAL ACCESS TOKEN. An earlier version of this took a PAT. It does not need one:
        the security namespace, access control list and identity APIs all accept an ordinary
        Entra token for the Azure DevOps resource, which was verified against all three before
        the PAT was removed. A PAT is a long-lived credential, and asking people to create one
        for a setup task is worse than using the sign-in they already have.

        AZURE DEVOPS HAS TWO PERMISSION SYSTEMS AND THEY ARE NOT INTERCHANGEABLE.

          -Permission  classic security namespaces, granted as ACL bits on a hierarchical token.
                       Repositories and Advanced Security live here.
          -RoleName    role assignments (Reader / User / Administrator) on a resource scope.
                       Pipeline resources - service connections, agent pools, variable groups,
                       secure files - live here, and have no organization root.

        Picking the wrong one fails SILENTLY: an allow on the ServiceEndpoints namespace is
        accepted, stored, reported back by the ACL API, and confers nothing at all. Verified the
        hard way.

        NOTHING IS HARDCODED. The namespace id and the permission bit are resolved by NAME at
        run time from the security namespace metadata, so a renumbered bit fails loudly instead
        of silently granting a different permission. The bit for 'view alerts' happens to be
        65536 today; that is a fact about one organization on one date, not something to rely on.

        THE ROOT TOKEN IS NAMESPACE-SPECIFIC AND HAS NO TRAILING SLASH. Git Repositories is
        'repoV2'; 'repoV2/' returns 400 "The request is invalid" for the same body. That one
        character is the difference between granting once for the whole organization and
        granting once per project, and it cost an afternoon to find. Namespaces this command has
        not been proven against are refused rather than guessed at.

    .PARAMETER Organization
        Azure DevOps organization name: the path segment after dev.azure.com/.

    .PARAMETER Identity
        Who to grant to - a group or an app, by display name. A GROUP is usually right: the
        permission is then granted once and membership becomes the control.

    .PARAMETER Permission
        Permission names as the namespace defines them, e.g. ViewAdvSecAlerts. Run with
        -ListPermissions to see them.

    .PARAMETER RoleName
        Role assignment instead of a namespace ACL - Reader, User or Administrator. Use this for
        pipeline resources; see the note above on the two systems.

    .PARAMETER RoleScope
        The roles scope. distributedtask.serviceendpointrole is service connections.

    .PARAMETER Namespace
        Security namespace name, for -Permission. Case-sensitive.

    .PARAMETER Scope
        Organization or Project.

    .PARAMETER Project
        Limit to one project by name.

    .PARAMETER ListPermissions
        Emit the permission names and bits in the namespace, and stop. Reads only.

    .PARAMETER ListRoles
        Emit the role assignments that exist on the scope, and stop. Reads only. Use it when a
        grant reports "already" and nothing changed - it shows what is actually there rather
        than what a match against one identity implies.

    .PARAMETER Revoke
        Take the permission away instead of granting it. Working out which permission an API
        actually checks tends to leave grants behind that turned out not to enable anything,
        and those should not just be left in place.

    .EXAMPLE
        Connect-AzAccount
        Grant-MsecAzureDevOpsPermission -Organization contoso -ListPermissions

    .EXAMPLE
        Grant-MsecAzureDevOpsPermission -Organization contoso -Identity 'Security Reporting Readers' `
            -Permission ViewAdvSecAlerts -Scope Organization -WhatIf

        Shows what would change. Drop -WhatIf to write it.

    .EXAMPLE
        # Service connections use ROLES, not namespace bits.
        Grant-MsecAzureDevOpsPermission -Organization contoso -Identity 'Security Reporting Readers' `
            -RoleName Reader -Scope Project

    .OUTPUTS
        One PSCustomObject per target describing what was found and what was done.

    .NOTES
        Needs an Az sign-in (Connect-AzAccount) as someone who can manage Azure DevOps
        permissions - Project Collection Administrator or equivalent. It does NOT need
        Connect-Msec: this grants the app its access, so it runs before the app has any.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string] $Organization,

        [string] $Identity,

        [string[]] $Permission,

        # THE OTHER MECHANISM - see the help. Service connections use ROLES; an allow on the
        # ServiceEndpoints namespace is accepted, stored, and confers nothing.
        [string] $RoleName,

        [string] $RoleScope = 'distributedtask.serviceendpointrole',

        [string] $Namespace = 'Git Repositories',

        [ValidateSet('Organization', 'Project')]
        [string] $Scope = 'Organization',

        [string] $Project,

        [switch] $ListPermissions,

        [switch] $ListRoles,

        [switch] $Revoke
    )

    # Azure DevOps' own well-known application id. Get-AzAccessToken wants the resource, and the
    # ADO APIs accept the resulting bearer token directly - no PAT, no Basic auth.
    $adoResource = '499b84ac-1321-427f-aa17-267ca6975798'

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw ('No Azure context. Run Connect-AzAccount first - this command grants permissions AS YOU, ' +
               'not as the msec app, because the app is usually the grantee and must not be able to grant ' +
               'itself access.')
    }

    try { $tokenInfo = Get-AzAccessToken -ResourceUrl $adoResource -ErrorAction Stop }
    catch { throw "Could not get an Azure DevOps token for the signed-in user: $($_.Exception.Message)" }

    $token = if ($tokenInfo.Token -is [securestring]) {
        $tokenInfo.Token | ConvertFrom-SecureString -AsPlainText
    }
    else { [string] $tokenInfo.Token }

    $headers = @{ Authorization = "Bearer $token" }

    # Root tokens per namespace. See the help: no trailing slash, and unproven namespaces are
    # refused rather than guessed at.
    $tokenGrammar = @{
        'Git Repositories' = @{ Root = @('repoV2');                   Project = { param($id) "repoV2/$id" } }
        'ServiceEndpoints' = @{ Root = @('endpoints');                Project = { param($id) "endpoints/$id" } }
        # Agent pools. Root spelling unverified - the candidates are tried in order.
        'DistributedTask'  = @{ Root = @('AgentPools', 'agentpools'); Project = { param($id) "AgentPools/$id" } }
    }

    # ---- namespace, resolved by name ----------------------------------------------------------
    $namespaces = @((Invoke-RestMethod -Uri "https://dev.azure.com/$Organization/_apis/securitynamespaces?api-version=7.1" -Headers $headers).value)
    $ns = @($namespaces | Where-Object { $_.name -eq $Namespace })
    if ($ns.Count -ne 1) { throw "Security namespace '$Namespace' matched $($ns.Count). Names are case-sensitive here." }
    $ns = $ns[0]

    if ($ListPermissions) {
        Write-Verbose "namespace $($ns.name) ($($ns.namespaceId)), $(if ($ns.structureValue -eq 1) { 'hierarchical' } else { 'flat' })"
        foreach ($action in ($ns.actions | Sort-Object bit)) {
            [PSCustomObject]@{
                PSTypeName  = 'MsecAzureDevOpsPermissionName'
                Namespace   = [string] $ns.name
                Name        = [string] $action.name
                Bit         = $action.bit
                DisplayName = [string] $action.displayName
            }
        }
        return
    }

    if ($ListRoles) {
        $projects = @((Invoke-RestMethod -Uri "https://dev.azure.com/$Organization/_apis/projects?api-version=7.1" -Headers $headers).value)
        if ($Project) { $projects = @($projects | Where-Object { $_.name -eq $Project }) }
        foreach ($proj in $projects) {
            $assignments = @()
            try {
                $assignments = @((Invoke-RestMethod -Headers $headers -Uri ("https://dev.azure.com/$Organization/_apis/securityroles/scopes/$RoleScope" +
                                    "/roleassignments/resources/$($proj.id)?api-version=7.1-preview.1")).value)
            }
            catch { Write-Warning "$($proj.name): could not read role assignments - $($_.Exception.Message)" }

            foreach ($a in $assignments) {
                [PSCustomObject]@{
                    PSTypeName = 'MsecAzureDevOpsRoleAssignment'
                    Project    = [string] $proj.name
                    Scope      = $RoleScope
                    Resource   = '(project)'
                    Identity   = [string] $a.identity.displayName
                    Role       = [string] $a.role.name
                    Access     = [string] $a.access
                }
            }

            # Service connections are permissioned per CONNECTION as well as per project, and a
            # connection whose inheritance is off ignores whatever the project scope says. The
            # resource id for one connection is {projectId}_{endpointId}.
            if ($Project) {
                $endpoints = @()
                try {
                    $endpoints = @((Invoke-RestMethod -Headers $headers -Uri ("https://dev.azure.com/$Organization/$([uri]::EscapeDataString($proj.name))" +
                                     "/_apis/serviceendpoint/endpoints?api-version=7.1-preview.4")).value)
                }
                catch { Write-Warning "$($proj.name): could not list service connections - $($_.Exception.Message)" }

                foreach ($ep in $endpoints) {
                    try {
                        $epRoles = @((Invoke-RestMethod -Headers $headers -Uri ("https://dev.azure.com/$Organization/_apis/securityroles/scopes/$RoleScope" +
                                       "/roleassignments/resources/$($proj.id)_$($ep.id)?api-version=7.1-preview.1")).value)
                        foreach ($a in $epRoles) {
                            [PSCustomObject]@{
                                PSTypeName = 'MsecAzureDevOpsRoleAssignment'
                                Project    = [string] $proj.name
                                Scope      = $RoleScope
                                Resource   = [string] $ep.name
                                Identity   = [string] $a.identity.displayName
                                Role       = [string] $a.role.name
                                Access     = [string] $a.access
                            }
                        }
                    }
                    catch { Write-Warning "$($proj.name)/$($ep.name): [$($_.Exception.Response.StatusCode.value__)]" }
                }
            }
        }
        return
    }

    if (-not $Identity) { throw 'Identity is required unless -ListPermissions or -ListRoles is given.' }
    if ($Permission -and $RoleName) { throw 'Use -Permission (namespace ACL) or -RoleName (role assignment), not both.' }
    if (-not $Permission -and -not $RoleName) { throw 'One of -Permission or -RoleName is required.' }

    # ---- permission bits, resolved by name ----------------------------------------------------
    # @($null) is an array containing one $null, not an empty array - so an unguarded loop here
    # ran once with an empty name and failed a -RoleName call with "'' is not a permission".
    $mask = 0
    foreach ($name in @($Permission | Where-Object { $_ })) {
        $action = @($ns.actions | Where-Object { $_.name -eq $name })
        if ($action.Count -ne 1) {
            throw "'$name' is not a permission in '$Namespace'. Run with -ListPermissions to see the names."
        }
        $mask = $mask -bor $action[0].bit
        Write-Verbose "permission $($action[0].name) = $($action[0].bit) ($($action[0].displayName))"
    }

    # ---- grantee, resolved by name ------------------------------------------------------------
    $found = @((Invoke-RestMethod -Uri ("https://vssps.dev.azure.com/$Organization/_apis/identities?searchFilter=General" +
                "&filterValue=$([uri]::EscapeDataString($Identity))&api-version=7.1") -Headers $headers).value)
    if (-not $found.Count) { throw "No identity matching '$Identity' in '$Organization'. Create the group, or add the app under Organization Settings > Users, first." }
    if ($found.Count -gt 1) {
        $found | ForEach-Object { Write-Warning "  matched: $($_.providerDisplayName)" }
        throw "'$Identity' matched $($found.Count) identities. Use the exact display name."
    }
    $descriptor = $found[0].descriptor
    $identityId = $found[0].id
    Write-Verbose "grantee $($found[0].providerDisplayName)"

    # ---- targets ------------------------------------------------------------------------------
    $grammar = $null
    if (-not $RoleName) {
        $grammar = $tokenGrammar[$Namespace]
        if (-not $grammar) { throw "No token grammar known for namespace '$Namespace'. Add one only after proving it against a live organization." }
    }

    if ($RoleName -and $Scope -eq 'Organization') {
        # Candidate resource ids for the collection-level role scope. Role assignments DO inherit
        # from a scope above the project - a project-scope read showed access=inherited, which has
        # to come from somewhere - but the resource id for that scope is not documented anywhere
        # I could find, so the candidates are tried in order and the one that takes is reported.
        $collectionId = $null
        try { $collectionId = ((Invoke-RestMethod -Uri "https://dev.azure.com/$Organization/_apis/connectionData?api-version=7.1-preview.1" -Headers $headers).instanceId) } catch { }
        $targets = @([pscustomobject]@{ Name = '(collection root)'; Tokens = @($collectionId, $Organization | Where-Object { $_ }) })
    }
    elseif ($RoleName) {
        $projects = @((Invoke-RestMethod -Uri "https://dev.azure.com/$Organization/_apis/projects?api-version=7.1" -Headers $headers).value)
        if ($Project) {
            $projects = @($projects | Where-Object { $_.name -eq $Project })
            if (-not $projects.Count) { throw "No project named '$Project' in '$Organization'." }
        }
        $targets = @($projects | ForEach-Object { [pscustomobject]@{ Name = $_.name; Tokens = @($_.id) } })
    }
    elseif ($Scope -eq 'Organization') {
        $targets = @([pscustomobject]@{ Name = '(organization root)'; Tokens = @($grammar.Root) })
    }
    else {
        $projects = @((Invoke-RestMethod -Uri "https://dev.azure.com/$Organization/_apis/projects?api-version=7.1" -Headers $headers).value)
        if ($Project) {
            $projects = @($projects | Where-Object { $_.name -eq $Project })
            if (-not $projects.Count) { throw "No project named '$Project' in '$Organization'." }
        }
        $targets = @($projects | ForEach-Object { [pscustomobject]@{ Name = $_.name; Tokens = @((& $grammar.Project $_.id)) } })
    }

    Write-Verbose "scope $Scope, $($targets.Count) target(s)"

    $verb = if ($Revoke) { 'Revoke' } else { 'Grant' }
    $what = if ($RoleName) { "role '$RoleName'" } else { "permission(s) $($Permission -join ', ')" }

    # ---- apply --------------------------------------------------------------------------------
    foreach ($target in $targets) {
        $already = $false
        $result  = $null
        $detail  = $null

        if ($RoleName) {
            try {
                $existing = @((Invoke-RestMethod -Headers $headers -Uri ("https://dev.azure.com/$Organization/_apis/securityroles/scopes/$RoleScope" +
                                "/roleassignments/resources/$($target.Tokens[0])?api-version=7.1-preview.1")).value)
                $already = [bool] @($existing | Where-Object { $_.identity.id -eq $identityId -and $_.role.name -eq $RoleName }).Count
            }
            catch { Write-Warning "$($target.Name): could not read current role assignments - $($_.Exception.Message)" }

            if ($already) { $result = 'AlreadyAssigned' }
            elseif (-not $PSCmdlet.ShouldProcess("$($target.Name) in $Organization", "$verb $what to '$Identity'")) { $result = 'Skipped' }
            else {
                $assigned = $false
                # EVERY candidate's failure, not just the last. Reporting only the last hid the
                # real error behind a malformed URL from a later candidate.
                $failures = [System.Collections.Generic.List[string]]::new()
                foreach ($resource in $target.Tokens) {
                    try {
                        $body = ConvertTo-Json -Depth 4 -InputObject @(@{ roleName = $RoleName; userId = $identityId })
                        Invoke-RestMethod -Method PUT -ContentType 'application/json' -Body $body -Headers $headers `
                            -Uri "https://dev.azure.com/$Organization/_apis/securityroles/scopes/$RoleScope/roleassignments/resources/$resource`?api-version=7.1-preview.1" | Out-Null
                        $result = 'Assigned'; $detail = "resource '$resource'"; $assigned = $true
                        break
                    }
                    catch {
                        $msg = ''
                        try { $msg = ($_.ErrorDetails.Message | ConvertFrom-Json).message } catch { $msg = $_.Exception.Message }
                        $failures.Add(("resource '{0}' [{1}] {2}" -f $resource, $_.Exception.Response.StatusCode.value__, $msg))
                    }
                }
                if (-not $assigned) {
                    $result = 'Failed'; $detail = ($failures -join ' | ')
                    Write-Warning "$($target.Name): no candidate resource accepted the assignment. $detail"
                }
            }
        }
        else {
            try {
                $acl = (Invoke-RestMethod -Headers $headers -Uri ("https://dev.azure.com/$Organization/_apis/accesscontrollists/$($ns.namespaceId)" +
                        "?token=$([uri]::EscapeDataString($target.Tokens[0]))&descriptors=$([uri]::EscapeDataString($descriptor))&api-version=7.1")).value
                foreach ($entry in @($acl)) {
                    foreach ($ace in @($entry.acesDictionary.PSObject.Properties)) {
                        if (($ace.Value.allow -band $mask) -eq $mask) { $already = $true }
                    }
                }
            }
            catch { Write-Warning "$($target.Name): could not read current ACL - $($_.Exception.Message)" }

            if ($Revoke -and -not $already) { $result = 'NotGranted' }
            elseif (-not $Revoke -and $already) { $result = 'AlreadyAllowed' }
            elseif (-not $PSCmdlet.ShouldProcess("$($target.Name) in $Organization", "$verb $what to '$Identity'")) { $result = 'Skipped' }
            elseif ($Revoke) {
                $removed = $false
                foreach ($candidate in $target.Tokens) {
                    try {
                        # DELETE removes this DESCRIPTOR's entry at this token. Other identities
                        # keep theirs, which is why this is not a rewrite of the ACL.
                        Invoke-RestMethod -Method DELETE -Headers $headers -Uri (
                            "https://dev.azure.com/$Organization/_apis/accesscontrolentries/$($ns.namespaceId)" +
                            "?token=$([uri]::EscapeDataString($candidate))&descriptors=$([uri]::EscapeDataString($descriptor))&api-version=7.1") | Out-Null
                        $result = 'Revoked'; $detail = "token '$candidate'"; $removed = $true
                        break
                    }
                    catch { }
                }
                if (-not $removed) { $result = 'Failed'; Write-Warning "$($target.Name): could not revoke at any candidate token." }
            }
            else {
                $wrote = $false
                $lastError = $null
                foreach ($candidate in $target.Tokens) {
                    try {
                        # merge = true so other permissions on this token are preserved, not replaced.
                        $body = @{
                            token                = $candidate
                            merge                = $true
                            accessControlEntries = @(@{ descriptor = $descriptor; allow = $mask; deny = 0 })
                        } | ConvertTo-Json -Depth 5

                        Invoke-RestMethod -Method POST -ContentType 'application/json' -Body $body -Headers $headers `
                            -Uri "https://dev.azure.com/$Organization/_apis/accesscontrolentries/$($ns.namespaceId)?api-version=7.1" | Out-Null

                        $result = 'Allowed'; $detail = "token '$candidate'"; $wrote = $true
                        break
                    }
                    catch { $lastError = $_ }
                }
                if (-not $wrote) {
                    # Named, not swallowed: a target left ungranted is data that stays missing,
                    # and a silent skip would look like success. The BODY carries the real
                    # complaint on a 400.
                    $body = ''
                    try { $body = $lastError.ErrorDetails.Message } catch { }
                    $result = 'Failed'
                    $detail = "$($lastError.Exception.Message) $($body.Substring(0, [Math]::Min(300, $body.Length)))".Trim()
                    Write-Warning "$($target.Name): FAILED - $detail"
                }
            }
        }

        [PSCustomObject]@{
            PSTypeName   = 'MsecAzureDevOpsGrant'
            Organization = $Organization
            Target       = [string] $target.Name
            Identity     = [string] $found[0].providerDisplayName
            Granted      = $(if ($RoleName) { $RoleName } else { ($Permission -join ', ') })
            Mechanism    = $(if ($RoleName) { 'RoleAssignment' } else { 'NamespaceAcl' })
            Result       = $result
            Detail       = $detail
        }
    }
}
