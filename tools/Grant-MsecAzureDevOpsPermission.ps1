<#
.SYNOPSIS
    Grants an Azure DevOps permission to an identity or group, at organization or project scope.

.DESCRIPTION
    ONE-TIME SETUP, RUN AS A PERSON. Not part of msec: msec is read-only and this WRITES an
    access control entry. It lives in tools/ so it is never published with the module.

    Some things msec needs cannot be granted through Entra. New-MsecApp handles API permissions
    and directory roles; Azure DevOps keeps its own permission system, and an app that is a
    member of the organization still reads nothing until permissions are set INSIDE Azure
    DevOps. This is the tool for that half.

    AZURE DEVOPS HAS TWO PERMISSION SYSTEMS AND THEY ARE NOT INTERCHANGEABLE.

      -Permission  classic security namespaces, granted as ACL bits on a hierarchical token.
                   Repositories and Advanced Security live here.
      -RoleName    role assignments (Reader / User / Administrator) on a resource scope.
                   Pipeline resources - service connections, agent pools, variable groups,
                   secure files - live here, and have no organization root.

    Picking the wrong one fails SILENTLY: an allow on the ServiceEndpoints namespace is
    accepted, stored, reported back by the ACL API, and confers nothing at all. Verified the
    hard way.

    NOTHING IS HARDCODED. The namespace id and the permission bit are resolved by NAME at run
    time from the security namespace metadata, so a renumbered bit fails loudly instead of
    silently granting a different permission. The bit for 'view alerts' happens to be 65536
    today; that is a fact about this organization on this date, not something to rely on.

    THE ROOT TOKEN IS NAMESPACE-SPECIFIC AND HAS NO TRAILING SLASH. Git Repositories is
    'repoV2'; 'repoV2/' returns 400 "The request is invalid" for the same body. That one
    character is the difference between granting once for the whole organization and granting
    once per project, and it cost an afternoon to find. Namespaces this script has not been
    proven against are refused rather than guessed at.

.PARAMETER Organization
    Azure DevOps organization name: the path segment after dev.azure.com/.

.PARAMETER Identity
    Who to grant to - a group or an app, by display name. A GROUP is usually right: the
    permission is then granted once and membership becomes the control.

.PARAMETER Permission
    Permission names as the namespace defines them, e.g. ViewAdvSecAlerts. Run with
    -ListPermissions to see what a namespace offers. Several may be given; they are combined.

.PARAMETER Namespace
    Security namespace. Default 'Git Repositories', which is where the Advanced Security
    permissions live.

.PARAMETER Scope
    'Organization' writes one entry at the namespace root, inherited by every project.
    'Project' writes one per project, or one for -Project.

.PARAMETER ListPermissions
    Print the permissions the namespace offers, with their bits, and exit. Reads only.

.PARAMETER Pat
    A PAT with Security (manage). The delegated Azure token cannot read or write ACLs (403).
    Make it short-lived.

.EXAMPLE
    # What can be granted here?
    ./Grant-MsecAzureDevOpsPermission.ps1 -Organization contoso -Pat $pat -ListPermissions

.EXAMPLE
    # Let a group read Advanced Security alerts across the whole organization.
    ./Grant-MsecAzureDevOpsPermission.ps1 -Organization contoso -Identity 'Security Reporting Readers' `
        -Permission ViewAdvSecAlerts -Scope Organization -Pat $pat -Apply

.NOTES
    Verified against a live organization: granting ViewAdvSecAlerts at the root token took every
    repository from refusing its alerts to none refusing, in one write.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Organization,
    [Parameter(Mandatory)] [securestring] $Pat,

    [string] $Identity,
    [string[]] $Permission,

    # THE OTHER MECHANISM. Azure DevOps has two permission systems and they are not
    # interchangeable: the classic security namespaces (-Permission, ACL bits) and role
    # assignments (-RoleName, Reader/User/Administrator). Service connections use ROLES - an
    # allow on the ServiceEndpoints namespace is accepted, stored, and confers nothing.
    #
    # Repositories and Advanced Security use the namespace side; pipeline resources - service
    # connections, agent pools, variable groups, secure files - use roles.
    [string] $RoleName,

    # The roles scope. distributedtask.serviceendpointrole is service connections.
    [string] $RoleScope = 'distributedtask.serviceendpointrole',

    [string] $Namespace = 'Git Repositories',

    [ValidateSet('Organization', 'Project')]
    [string] $Scope = 'Organization',

    [string] $Project,

    [switch] $ListPermissions,

    # Print the role assignments that exist on the scope, and exit. Reads only. Use it when a
    # grant reports "already" and nothing changed - it shows what is actually there rather than
    # what a match against one identity implies.
    [switch] $ListRoles,

    # Take the permission away instead of granting it. Same targets, same -Apply gate. Working
    # out which permission an API actually checks tends to leave grants behind that turned out
    # not to enable anything, and those should not just be left in place.
    [switch] $Revoke,

    [switch] $Apply
)

$ErrorActionPreference = 'Stop'

# Root and project token grammar is namespace-specific. Only namespaces proven against a live
# organization are listed; anything else is refused rather than guessed at.
# Root is a LIST of candidate spellings, tried in order, because the difference between working
# and 400 "The request is invalid" was a single trailing slash on repoV2 and there is no way to
# tell from the metadata which form a namespace wants. The spelling that took is printed.
$TokenGrammar = @{
    'Git Repositories' = @{ Root = @('repoV2');              Project = { param($id) "repoV2/$id" } }
    'ServiceEndpoints' = @{ Root = @('endpoints');           Project = { param($id) "endpoints/$id" } }
    # Agent pools. Root spelling unverified - the candidates are tried in order.
    'DistributedTask'  = @{ Root = @('AgentPools', 'agentpools'); Project = { param($id) "AgentPools/$id" } }
}

$plain   = [System.Net.NetworkCredential]::new('', $Pat).Password
$headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$plain")) }

# ---- namespace, resolved by name -------------------------------------------------------------
$namespaces = @((Invoke-RestMethod -Uri "https://dev.azure.com/$Organization/_apis/securitynamespaces?api-version=7.1" -Headers $headers).value)
$ns = @($namespaces | Where-Object { $_.name -eq $Namespace })
if ($ns.Count -ne 1) { throw "Security namespace '$Namespace' matched $($ns.Count). Names are case-sensitive here." }
$ns = $ns[0]

if ($ListPermissions) {
    Write-Host "namespace : $($ns.name)  ($($ns.namespaceId))"
    Write-Host "structure : $(if ($ns.structureValue -eq 1) { 'hierarchical' } else { 'flat' })`n"
    $ns.actions | Sort-Object bit | ForEach-Object { '  {0,-34} bit={1,-10} {2}' -f $_.name, $_.bit, $_.displayName }
    return
}

if ($ListRoles) {
    $projects = @((Invoke-RestMethod -Uri "https://dev.azure.com/$Organization/_apis/projects?api-version=7.1" -Headers $headers).value)
    if ($Project) { $projects = @($projects | Where-Object { $_.name -eq $Project }) }
    foreach ($proj in $projects) {
        Write-Host "`n--- $($proj.name)  scope=$RoleScope"
        try {
            $assignments = @((Invoke-RestMethod -Headers $headers -Uri ("https://dev.azure.com/$Organization/_apis/securityroles/scopes/$RoleScope" +
                                "/roleassignments/resources/$($proj.id)?api-version=7.1-preview.1")).value)
            if (-not $assignments.Count) { Write-Host '    no role assignments at this scope'; continue }
            $assignments | ForEach-Object {
                '    {0,-46} {1,-16} access={2}' -f $_.identity.displayName, $_.role.name, $_.access
            }
        }
        catch { Write-Host "    [$($_.Exception.Response.StatusCode.value__)] $($_.Exception.Message)" }

        # Service connections are permissioned per CONNECTION as well as per project, and a
        # connection whose inheritance is off ignores whatever the project scope says. The
        # resource id for one connection is {projectId}_{endpointId}.
        if ($Project) {
            $endpoints = @()
            try {
                $endpoints = @((Invoke-RestMethod -Headers $headers -Uri ("https://dev.azure.com/$Organization/$([uri]::EscapeDataString($proj.name))" +
                                 "/_apis/serviceendpoint/endpoints?api-version=7.1-preview.4")).value)
            }
            catch { Write-Host "    could not list connections: $($_.Exception.Message)" }

            Write-Host "    connections visible to this PAT: $($endpoints.Count)"
            foreach ($ep in ($endpoints | Select-Object -First 4)) {
                try {
                    $epRoles = @((Invoke-RestMethod -Headers $headers -Uri ("https://dev.azure.com/$Organization/_apis/securityroles/scopes/$RoleScope" +
                                   "/roleassignments/resources/$($proj.id)_$($ep.id)?api-version=7.1-preview.1")).value)
                    Write-Host "      $($ep.name)  ($($epRoles.Count) assignment(s))"
                    $epRoles | ForEach-Object { '         {0,-44} {1,-14} access={2}' -f $_.identity.displayName, $_.role.name, $_.access }
                }
                catch { Write-Host "      $($ep.name)  [$($_.Exception.Response.StatusCode.value__)]" }
            }
        }
    }
    return
}

if (-not $Identity) { throw 'Identity is required unless -ListPermissions is given.' }
if ($Permission -and $RoleName) { throw 'Use -Permission (namespace ACL) or -RoleName (role assignment), not both.' }
if (-not $Permission -and -not $RoleName) { throw 'One of -Permission or -RoleName is required.' }
# No throw for -RoleName -Scope Organization. Role assignments DO inherit from a scope above the
# project - a project-scope read showed access=inherited, which has to come from somewhere - but
# the resource id for that scope is not documented anywhere I could find, so the candidates below
# are tried in order and the one that takes is printed.

# ---- permission bits, resolved by name --------------------------------------------------------
# @($null) is an array containing one $null, not an empty array - so an unguarded loop here ran
# once with an empty name and failed a -RoleName call with "'' is not a permission".
$mask = 0
foreach ($name in @($Permission | Where-Object { $_ })) {
    $action = @($ns.actions | Where-Object { $_.name -eq $name })
    if ($action.Count -ne 1) {
        throw "'$name' is not a permission in '$Namespace'. Run with -ListPermissions to see the names."
    }
    $mask = $mask -bor $action[0].bit
    Write-Host "permission: $($action[0].name) = $($action[0].bit)  ($($action[0].displayName))"
}

# ---- grantee, resolved by name ----------------------------------------------------------------
$found = @((Invoke-RestMethod -Uri "https://vssps.dev.azure.com/$Organization/_apis/identities?searchFilter=General&filterValue=$([uri]::EscapeDataString($Identity))&api-version=7.1" -Headers $headers).value)
if (-not $found.Count) { throw "No identity matching '$Identity' in '$Organization'. Create the group, or add the app under Organization Settings > Users, first." }
if ($found.Count -gt 1) {
    $found | ForEach-Object { Write-Host "  $($_.providerDisplayName)" }
    throw "'$Identity' matched $($found.Count) identities. Use the exact display name."
}
$descriptor = $found[0].descriptor
$identityId = $found[0].id
Write-Host "grantee   : $($found[0].providerDisplayName)"

# ---- targets ----------------------------------------------------------------------------------
$grammar = $null
if (-not $RoleName) {
    $grammar = $TokenGrammar[$Namespace]
    if (-not $grammar) { throw "No token grammar known for namespace '$Namespace'. Add one only after proving it against a live organization." }
}

if ($RoleName -and $Scope -eq 'Organization') {
    # Candidate resource ids for the collection-level role scope. The collection id comes from
    # connectionData; the empty string is how some Azure DevOps scopes name their root.
    $collectionId = $null
    try { $collectionId = ((Invoke-RestMethod -Uri "https://dev.azure.com/$Organization/_apis/connectionData?api-version=7.1-preview.1" -Headers $headers).instanceId) } catch { }
    $candidates = @($collectionId, $Organization) | Where-Object { $_ }
    $targets = @([pscustomobject]@{ Name = '(collection root)'; Tokens = $candidates })
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
Write-Host "scope     : $Scope"
Write-Host "targets   : $($targets.Count)`n"

# ---- grant ------------------------------------------------------------------------------------
foreach ($target in $targets) {
    $already = $false

    if ($RoleName) {
        # Roles: read the assignments on this project's scope and look for the grantee.
        try {
            $existing = @((Invoke-RestMethod -Headers $headers -Uri ("https://dev.azure.com/$Organization/_apis/securityroles/scopes/$RoleScope" +
                            "/roleassignments/resources/$($target.Tokens[0])?api-version=7.1-preview.1")).value)
            $already = [bool] @($existing | Where-Object { $_.identity.id -eq $identityId -and $_.role.name -eq $RoleName }).Count
        }
        catch { Write-Warning "  $($target.Name): could not read current role assignments - $($_.Exception.Message)" }

        if ($already)   { Write-Host ("  {0,-40} already '{1}'" -f $target.Name, $RoleName) -ForegroundColor DarkGray; continue }
        if (-not $Apply) { Write-Host ("  {0,-40} would assign '{1}'" -f $target.Name, $RoleName) -ForegroundColor Yellow; continue }

        $assigned = $false
        # EVERY candidate's failure, not just the last. Reporting only the last hid the real
        # error behind a malformed URL from a later candidate, which is worse than useless.
        $failures = [System.Collections.Generic.List[string]]::new()
        foreach ($resource in $target.Tokens) {
            try {
                $body = ConvertTo-Json -Depth 4 -InputObject @(@{ roleName = $RoleName; userId = $identityId })
                Invoke-RestMethod -Method PUT -ContentType 'application/json' -Body $body -Headers $headers `
                    -Uri "https://dev.azure.com/$Organization/_apis/securityroles/scopes/$RoleScope/roleassignments/resources/$resource?api-version=7.1-preview.1" | Out-Null
                Write-Host ("  {0,-40} assigned '{1}'  (resource '{2}')" -f $target.Name, $RoleName, $resource) -ForegroundColor Green
                $assigned = $true
                break
            }
            catch {
                $detail = ''
                try { $detail = ($_.ErrorDetails.Message | ConvertFrom-Json).message } catch { $detail = $_.Exception.Message }
                $failures.Add(("resource '{0}' [{1}] {2}" -f $resource, $_.Exception.Response.StatusCode.value__, $detail))
            }
        }
        if (-not $assigned) {
            Write-Warning "  $($target.Name): no candidate resource accepted the assignment."
            $failures | ForEach-Object { Write-Warning "      $_" }
        }
        continue
    }

    try {
        $acl = (Invoke-RestMethod -Headers $headers -Uri ("https://dev.azure.com/$Organization/_apis/accesscontrollists/$($ns.namespaceId)" +
                "?token=$([uri]::EscapeDataString($target.Tokens[0]))&descriptors=$([uri]::EscapeDataString($descriptor))&api-version=7.1")).value
        foreach ($entry in @($acl)) {
            foreach ($ace in @($entry.acesDictionary.PSObject.Properties)) {
                if (($ace.Value.allow -band $mask) -eq $mask) { $already = $true }
            }
        }
    }
    catch { Write-Warning "  $($target.Name): could not read current ACL - $($_.Exception.Message)" }

    if ($Revoke) {
        if (-not $already) { Write-Host ("  {0,-40} not granted here" -f $target.Name) -ForegroundColor DarkGray; continue }
        if (-not $Apply)   { Write-Host ("  {0,-40} would revoke" -f $target.Name) -ForegroundColor Yellow; continue }
        $removed = $false
        foreach ($candidate in $target.Tokens) {
            try {
                # DELETE removes this DESCRIPTOR's entry at this token. Other identities keep
                # theirs, which is why this is not a rewrite of the ACL.
                Invoke-RestMethod -Method DELETE -Headers $headers -Uri (
                    "https://dev.azure.com/$Organization/_apis/accesscontrolentries/$($ns.namespaceId)" +
                    "?token=$([uri]::EscapeDataString($candidate))&descriptors=$([uri]::EscapeDataString($descriptor))&api-version=7.1") | Out-Null
                Write-Host ("  {0,-40} revoked  (token '{1}')" -f $target.Name, $candidate) -ForegroundColor Green
                $removed = $true
                break
            }
            catch { }
        }
        if (-not $removed) { Write-Warning "  $($target.Name): could not revoke at any candidate token." }
        continue
    }

    if ($already) { Write-Host ("  {0,-40} already allowed" -f $target.Name) -ForegroundColor DarkGray; continue }
    if (-not $Apply) { Write-Host ("  {0,-40} would allow" -f $target.Name) -ForegroundColor Yellow; continue }

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

            Write-Host ("  {0,-40} allowed  (token '{1}')" -f $target.Name, $candidate) -ForegroundColor Green
            $wrote = $true
            break
        }
        catch { $lastError = $_ }
    }
    if (-not $wrote) {
        $_ = $lastError
        # Named, not swallowed: a target left ungranted is data that stays missing, and a silent
        # skip would look like success. The BODY carries the real complaint on a 400.
        $body = ''
        try { $body = $_.ErrorDetails.Message } catch { }
        Write-Warning "  $($target.Name): FAILED - $($_.Exception.Message)"
        if ($body) { Write-Warning "      $($body.Substring(0, [Math]::Min(300, $body.Length)))" }
    }
}

if (-not $Apply) { Write-Host "`nDry run. Re-run with -Apply to write." -ForegroundColor Yellow }
