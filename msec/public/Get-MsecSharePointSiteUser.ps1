function Get-MsecSharePointSiteUser {
    <#
    .SYNOPSIS
        Who owns and who can edit a SharePoint site - one row per (site, person, role), with
        security groups expanded to the people inside them.

    .DESCRIPTION
        A site's Owners and Members groups are the permission model for SharePoint, and they
        are NOT visible from Entra. Graph exposes the Microsoft 365 group behind a
        group-connected site, which is a different thing: it does not exist for classic (STS#3)
        sites, and even where it does it is not what SharePoint checks. Only PnP reads the
        site's own groups, which is why this command needs it.

        SECURITY GROUPS ARE EXPANDED TO PEOPLE. A site whose Owners group contains one Entra
        security group has one member as far as SharePoint is concerned and possibly forty as
        far as access is concerned. The question being asked is who can do this, so the group
        is resolved through Graph and its members are emitted individually.

        A GROUP THAT CANNOT BE RESOLVED EMITS A ROW SAYING SO. SharePoint keeps the group's SID
        in its login name long after the group is deleted from Entra, and it keeps granting
        access to a principal that no longer resolves. Dropping those would report the site as
        having fewer owners than it does; the row carries IsResolved = $false and the group's
        object id so it can be chased.

        'System Account' IS EXCLUDED. It is SharePoint's own service identity, present on every
        site, and means nothing for an access review.

    .PARAMETER Url
        The site collection to read. Given this, the command connects itself - you only need
        Connect-Msec beforehand, like every other command here.

        Your own PnP session is left alone: the connection is made explicitly and passed to
        each PnP call rather than becoming the ambient one, so a script working against another
        site is not moved out from under it.

        Omit it to use whatever Connect-MsecSharePointOnline last connected to.

    .PARAMETER IncludeVisitors
        Also report the Visitors (read-only) group. Excluded by default: read access to a site
        is rarely the finding, and including it roughly triples the row count.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Get-MsecSharePointSiteUser -Url https://contoso.sharepoint.com/sites/finance

    .EXAMPLE
        # Every site, one connection each - which is how PnP works.
        Connect-MsecSharePointOnline -Url https://contoso-admin.sharepoint.com
        Get-PnPTenantSite | ForEach-Object { Get-MsecSharePointSiteUser -Url $_.Url }

    .EXAMPLE
        # Owners who are not in the directory any more.
        Get-MsecSharePointSiteUser | Where-Object { -not $_.IsResolved }

    .OUTPUTS
        PSCustomObject per (site, principal, role), PSTypeName 'MsecSharePointSiteUser'.

    .NOTES
        Needs Connect-MsecSharePointOnline for the site, AND an msec Graph session
        (Connect-Msec) to expand security groups - the two use different tokens for different
        audiences.

        Group.Read.All is what expands the groups. Without it every group-backed entry comes
        back IsResolved = $false, which is honest but much less useful.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string] $Url,

        [switch] $IncludeVisitors
    )

    if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
        throw 'PnP.PowerShell is required for Get-MsecSharePointSiteUser. Install with: Install-Module PnP.PowerShell -Scope CurrentUser'
    }
    Import-Module PnP.PowerShell -ErrorAction Stop

    # CONNECTS ITSELF WHEN GIVEN -Url, because every other command in this module is one call
    # after Connect-Msec and there is no reason this should be the exception.
    #
    # WITHOUT MOVING THE CALLER'S SESSION. PnP keeps ONE ambient connection, so a command that
    # simply called Connect-PnPOnline would leave the caller pointed at a different site than
    # they were on - a side effect nobody asked for, and one that only shows up later. The
    # connection is created with -PassThru and threaded through every PnP call explicitly.
    $connection = $null
    if ($Url) {
        $connection = Connect-MsecSharePointOnline -Url $Url -PassThru
    }
    elseif (-not (Get-PnPConnection -ErrorAction SilentlyContinue)) {
        throw 'Not connected to SharePoint, and no -Url given. Either pass -Url <site>, or run Connect-MsecSharePointOnline first.'
    }

    # Only added where a connection was made here; omitted otherwise so the ambient one is used.
    $pnp = @{}
    if ($connection) { $pnp['Connection'] = $connection }

    # EXPANDING GROUPS NEEDS A SECOND SESSION, and its absence must be loud. Without an msec
    # Graph session every security group comes back IsResolved = $false - which is exactly what
    # a deleted group looks like. The output would be a table of unresolved rows that reads as
    # a tenant full of orphaned groups rather than as a missing connection.
    $canExpand = $null -ne $script:MsecSession
    if (-not $canExpand) {
        Write-Warning 'No msec session, so security groups will NOT be expanded to their members - each will appear as a single unresolved row. Run Connect-Msec as well as Connect-MsecSharePointOnline: this command needs both, and they use different tokens.'
    }

    $siteUrl = $Url
    if (-not $siteUrl) {
        try { $siteUrl = (Get-PnPWeb @pnp -ErrorAction Stop).Url }
        catch { throw "Could not determine the current site. Run Connect-MsecSharePointOnline -Url <site> first. $($_.Exception.Message)" }
    }

    # PrincipalType COMES FROM TWO PLACES and has to read the same from both. A direct member
    # is typed by SharePoint ('User', 'SecurityGroup'); an expanded group member is typed by
    # Graph ('#microsoft.graph.user'). Left alone the same person appears as 'User' or 'user'
    # depending on how they got access, and any filter on one silently misses the other.
    # Normalised to Graph's lowercase form, which is the one that is also stable across the
    # rest of this module.
    $normaliseType = {
        param($Value)
        if (-not $Value) { return 'unknown' }
        $bare = [string] $Value -replace '^#microsoft\.graph\.', ''
        switch -Regex ($bare) {
            '^(?i)user$'             { 'user' }
            '^(?i)securitygroup$'    { 'group' }
            '^(?i)group$'            { 'group' }
            '^(?i)serviceprincipal$' { 'servicePrincipal' }
            '^(?i)device$'           { 'device' }
            default                  { $bare }
        }
    }

    # SharePoint stores an Entra group's object id inside the login name, e.g.
    # 'c:0t.c|tenant|<guid>'. There is no structured field for it, so it is extracted.
    $guidPattern = '(\{){0,1}[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}(\}){0,1}'

    $groups = @(
        @{ Role = 'Owner';  Param = @{ AssociatedOwnerGroup  = $true } }
        @{ Role = 'Member'; Param = @{ AssociatedMemberGroup = $true } }
    )
    if ($IncludeVisitors) {
        $groups += @{ Role = 'Visitor'; Param = @{ AssociatedVisitorGroup = $true } }
    }

    foreach ($spec in $groups) {
        $role = $spec.Role

        # SPLATTED FROM A VARIABLE. '@($spec.Param)' is an array subexpression, not splatting -
        # it hands Get-PnPGroup a one-element array which then binds POSITIONALLY to -Identity,
        # and the failure reads as "this site has no owners group" rather than as a bug here.
        $groupParams = $spec.Param
        $spGroup = $null
        try { $spGroup = Get-PnPGroup @groupParams @pnp -ErrorAction Stop }
        catch {
            # A site with no Owners group at all is unusual but real - and worth saying rather
            # than silently producing no rows for that role.
            # Deliberately NOT "this site has no $role group". That is one possible cause among
            # several - a permission failure and a bug in this command produce the same
            # exception - and asserting the friendly one sent a real splatting bug here
            # undiagnosed for a while. State what happened, then the cause.
            Write-Warning "Could not read the associated $role group for '$siteUrl'. The site may genuinely not have one, or the call failed. Graph/PnP said: $($_.Exception.Message)"
            continue
        }
        if (-not $spGroup) { continue }

        foreach ($user in @($spGroup.Users)) {
            if ($user.Title -eq 'System Account') { continue }

            $principalType = [string] $user.PrincipalType

            if ($principalType -eq 'User') {
                [PSCustomObject]@{
                    PSTypeName    = 'MsecSharePointSiteUser'
                    SiteUrl       = $siteUrl
                    Role          = $role
                    Name          = $user.Title
                    UserPrincipalName = $user.Email
                    PrincipalType = (& $normaliseType 'User')
                    ViaGroup      = $null
                    IsResolved    = $true
                    UnresolvedReason = $null
                    Id            = $user.LoginName
                }
                continue
            }

            if ($principalType -ne 'SecurityGroup') {
                # SharePoint groups nested inside site groups, and other principal kinds. Named
                # rather than dropped - an unexpanded container is still access.
                [PSCustomObject]@{
                    PSTypeName    = 'MsecSharePointSiteUser'
                    SiteUrl       = $siteUrl
                    Role          = $role
                    Name          = $user.Title
                    UserPrincipalName = $null
                    PrincipalType = (& $normaliseType $principalType)
                    ViaGroup      = $null
                    IsResolved    = $false
                    UnresolvedReason = 'Unexpected principal type'
                    Id            = $user.LoginName
                }
                continue
            }

            # ---- a security group: expand it to the people inside ----
            $groupId = [regex]::Matches([string] $user.LoginName, $guidPattern).Value | Select-Object -First 1

            $members = $null
            if ($groupId -and $canExpand) {
                try {
                    $path = if ($role -eq 'Owner') { "/v1.0/groups/$groupId/owners" } else { "/v1.0/groups/$groupId/members" }
                    $members = @(Invoke-MsecGraphRequest -All -Path $path)
                }
                catch {
                    Write-Verbose "Could not expand group '$($user.Title)' ($groupId): $($_.Exception.Message)"
                }
            }

            if (-not $members) {
                # SharePoint keeps granting access through a group Entra no longer has - see
                # the note in .DESCRIPTION. Reported, not dropped.
                [PSCustomObject]@{
                    PSTypeName    = 'MsecSharePointSiteUser'
                    SiteUrl       = $siteUrl
                    Role          = $role
                    Name          = $user.Title
                    UserPrincipalName = $null
                    PrincipalType = (& $normaliseType 'SecurityGroup')
                    ViaGroup      = $user.Title
                    IsResolved    = $false
                    # Which of the three reasons this is unresolved: no session at all, or the
                    # group genuinely could not be read (deleted, or no Group.Read.All).
                    UnresolvedReason = $(if (-not $canExpand) { 'No msec session' }
                                         elseif (-not $groupId) { 'No group id in the SharePoint login name' }
                                         else { 'Group could not be read from Entra' })
                    Id            = $groupId
                }
                continue
            }

            foreach ($member in $members) {
                [PSCustomObject]@{
                    PSTypeName    = 'MsecSharePointSiteUser'
                    SiteUrl       = $siteUrl
                    Role          = $role
                    Name          = $member.displayName
                    UserPrincipalName = $member.userPrincipalName
                    PrincipalType = (& $normaliseType $member.'@odata.type')
                    # Which group carried the access, so a reviewer knows where to remove it -
                    # the site itself is not where this person was added.
                    ViaGroup      = $user.Title
                    IsResolved    = $true
                    UnresolvedReason = $null
                    Id            = $member.id
                }
            }
        }
    }
}
