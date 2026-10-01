function Get-MsecEntraAppConsent {
    <#
    .SYNOPSIS
        Which applications have been granted access to your tenant's data, what they can do,
        and who agreed to it - one row per permission.

    .DESCRIPTION
        Get-MsecEntraAppCredential says which apps hold a key. This says what those apps are
        ALLOWED TO DO, which is the half that decides whether a key matters. Illicit consent
        is one of the most common routes into a Microsoft 365 tenant precisely because it needs
        no password, survives a password reset, and leaves the attacker holding a token rather
        than an account.

        TWO DIFFERENT GRANTS, REPORTED TOGETHER.
          Delegated   - oauth2PermissionGrants. The app acts AS A USER and is limited to what
                        that user can reach. ConsentType 'AllPrincipals' means an administrator
                        consented on behalf of EVERYONE; 'Principal' means one user consented
                        for themselves.
          Application - appRoleAssignments. The app acts AS ITSELF, with no user and no user's
                        limits. Mail.Read here is every mailbox in the tenant, not one.
        An Application grant is almost always the more serious of the two for the same
        permission name, so PermissionType belongs in any review that sorts by risk.

        ONE ROW PER PERMISSION, NOT PER GRANT. A single delegated grant carries a whole
        space-separated scope string; left whole it cannot be filtered or compared. Split out,
        'which apps can read mail' is one Where-Object.

        APP ROLE ASSIGNMENTS ARE READ FROM THE RESOURCE SIDE, deliberately. The obvious route -
        expanding appRoleAssignments on each service principal - SILENTLY TRUNCATES at one page
        and does not paginate: measured on one tenant it returned 203 assignments where the
        resource-side read returned 410, and 20 of msec's own 24. A security command that
        under-reports permissions by half is worse than no command, so this one pays for ~200
        extra calls and takes about half a minute.

        ASSIGNMENTS TO USERS AND GROUPS ARE NOT CONSENT AND ARE EXCLUDED. An app role assigned
        to a user or a group says who may USE an app; only an assignment to a service principal
        is an API permission the app holds over your data. Mixing them would inflate every
        count with something that answers a different question.

        HIGH RISK IS A JUDGEMENT AND IS WRITTEN DOWN IN THE SOURCE, not inferred. See
        $highRisk below and argue with it - the three escalation permissions at the top of that
        list let an app grant ITSELF more access, up to and including Global Administrator.

        UNREADABLE IS NOT EMPTY. A resource whose assignments cannot be read is reported as a
        row saying so, rather than omitted - an app with permissions nobody could enumerate
        must not read as an app with none.

    .PARAMETER PermissionType
        Delegated, Application, or both. Default is both.

    .PARAMETER HighRiskOnly
        Only permissions on the curated high-risk list.

    .PARAMETER ThirdPartyOnly
        Exclude applications published by Microsoft. Convenience for review, not a default:
        a first-party app with a surprising permission is still worth seeing.

    .EXAMPLE
        Get-MsecEntraAppConsent -HighRiskOnly | Where-Object PermissionType -eq 'Application'

        Apps that can act on the whole tenant without a user, holding a sensitive permission.

    .EXAMPLE
        Get-MsecEntraAppConsent -ThirdPartyOnly |
            Where-Object ConsentType -eq 'AllPrincipals'

        Third-party apps an administrator consented to on behalf of every user.

    .EXAMPLE
        Get-MsecEntraAppConsent | Group-Object ClientDisplayName |
            Sort-Object Count -Descending | Select-Object -First 20

        The apps holding the most permissions.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateSet('Delegated', 'Application')]
        [string[]] $PermissionType = @('Delegated', 'Application'),

        [switch] $HighRiskOnly,

        [switch] $ThirdPartyOnly
    )

    if (-not $script:MsecSession) {
        throw 'No msec session. Run Connect-Msec first.'
    }

    # Permissions worth a second look. Grouped by why, because "high risk" with no reason
    # attached is not reviewable. This list is the command's opinion and is meant to be edited.
    $highRisk = @(
        # Escalation - these let an app increase its OWN access, so they outrank everything else
        'AppRoleAssignment.ReadWrite.All'     # grant itself any application permission
        'RoleManagement.ReadWrite.Directory'  # put itself in a directory role, incl. Global Admin
        'Application.ReadWrite.All'           # add credentials to any app, then become it
        'Application.ReadWrite.OwnedBy'
        'PrivilegedAccess.ReadWrite.AzureADGroup'

        # Mail - read, send as, or quietly reconfigure where mail goes
        'Mail.Read'; 'Mail.ReadBasic'; 'Mail.ReadBasic.All'; 'Mail.ReadWrite'; 'Mail.Send'
        'MailboxSettings.ReadWrite'           # sets forwarding without touching a rule
        'full_access_as_app'                  # EWS: every mailbox, everything
        'Exchange.ManageAsApp'

        # Content at tenant scope
        'Files.Read.All'; 'Files.ReadWrite.All'
        'Sites.Read.All'; 'Sites.ReadWrite.All'; 'Sites.FullControl.All'; 'Sites.Manage.All'
        'Chat.Read.All'; 'ChatMessage.Read.All'; 'ChannelMessage.Read.All'
        'Calendars.Read'; 'Calendars.ReadWrite'

        # Directory - reconnaissance and modification
        'Directory.Read.All'; 'Directory.ReadWrite.All'
        'User.Read.All'; 'User.ReadWrite.All'
        'Group.Read.All'; 'Group.ReadWrite.All'; 'GroupMember.ReadWrite.All'
        'User.EnableDisableAccount.All'
        'UserAuthenticationMethod.ReadWrite.All'  # reset someone's MFA
    )

    # First-party applications are owned by one of these two tenants. Checked against the OWNER
    # tenant rather than the publisher name, which is free text and absent on many apps.
    $microsoftTenants = @(
        'f8cdef31-a31e-4b4a-93e4-5f571e91255a'
        '72f988bf-86f1-41af-91ab-2d7cd011db47'
    )

    Write-Verbose 'Reading service principals'
    $servicePrincipals = @(Invoke-MsecGraphRequest -All -Path (
        '/v1.0/servicePrincipals?$select=id,appId,displayName,appRoles,appOwnerOrganizationId,' +
        'publisherName,verifiedPublisher,servicePrincipalType,accountEnabled,signInAudience&$top=999'))

    $spById = @{}
    foreach ($sp in $servicePrincipals) { $spById[$sp.id] = $sp }

    # appRoleId is a GUID that only means anything against the RESOURCE's own appRoles list.
    $roleName = @{}
    foreach ($sp in $servicePrincipals) {
        foreach ($role in @($sp.appRoles)) {
            if ($role.id) { $roleName["$($sp.id)/$($role.id)"] = [string] $role.value }
        }
    }

    # Describes a client once, so every row for it agrees.
    $describe = {
        param($sp, $fallbackId, $fallbackName)
        $owner = if ($sp) { [string] $sp.appOwnerOrganizationId } else { '' }
        $publisher = if (-not $sp) { $null }
                     elseif ($sp.verifiedPublisher -and $sp.verifiedPublisher.displayName) { [string] $sp.verifiedPublisher.displayName }
                     elseif ($sp.publisherName) { [string] $sp.publisherName }
                     else { $null }
        [PSCustomObject]@{
            Name       = if ($sp) { [string] $sp.displayName } else { $fallbackName }
            AppId      = if ($sp) { [string] $sp.appId } else { $null }
            ObjectId   = if ($sp) { [string] $sp.id } else { $fallbackId }
            Publisher  = $publisher
            # $null, not $false, when the owning tenant is unknown - an app msec could not
            # resolve is not evidence of a third-party app.
            IsMicrosoft = if ($owner) { $owner -in $microsoftTenants } else { $null }
            Enabled    = if ($sp) { $sp.accountEnabled } else { $null }
            Type       = if ($sp) { [string] $sp.servicePrincipalType } else { $null }
        }
    }

    $emit = {
        param($row)
        if ($HighRiskOnly -and -not $row.IsHighRisk) { return }
        # -ThirdPartyOnly drops only apps KNOWN to be Microsoft's. An unresolved owner stays in.
        if ($ThirdPartyOnly -and $row.ClientIsMicrosoft -eq $true) { return }
        $row
    }

    # ---------- Delegated ----------
    if ($PermissionType -contains 'Delegated') {
        Write-Verbose 'Reading delegated permission grants'
        $grants = $null
        try {
            $grants = @(Invoke-MsecGraphRequest -All -Path '/v1.0/oauth2PermissionGrants?$top=999')
        }
        catch {
            Write-Warning "Could not read delegated permission grants (/oauth2PermissionGrants), so NO delegated consent is covered by this output - this is not the same as a tenant with none. Graph said: $($_.Exception.Message)"
        }

        if ($null -ne $grants) {
            # One batched lookup instead of one call per user: a tenant can easily hold
            # hundreds of individual-user consents, and resolving them singly is the
            # difference between seconds and minutes.
            $principalName = @{}
            $ids = @($grants | Where-Object { $_.principalId } | ForEach-Object { [string] $_.principalId } | Select-Object -Unique)
            for ($i = 0; $i -lt $ids.Count; $i += 1000) {
                $chunk = @($ids[$i..([math]::Min($i + 999, $ids.Count - 1))])
                try {
                    $resolved = Invoke-MsecGraphRequest -Method POST -Path '/v1.0/directoryObjects/getByIds' -Body @{
                        ids   = $chunk
                        types = @('user')
                    }
                    foreach ($o in @($resolved.value)) {
                        $principalName[[string] $o.id] = [pscustomobject]@{
                            DisplayName = [string] $o.displayName
                            Upn         = [string] $o.userPrincipalName
                        }
                    }
                }
                catch {
                    Write-Warning "Could not resolve $($chunk.Count) consenting user(s) to names; PrincipalDisplayName and PrincipalUpn are null for those rows rather than wrong. Graph said: $($_.Exception.Message)"
                }
            }

            foreach ($grant in $grants) {
                $client   = & $describe $spById[[string] $grant.clientId]   ([string] $grant.clientId)   $null
                $resource = & $describe $spById[[string] $grant.resourceId] ([string] $grant.resourceId) $null

                $who = if ($grant.principalId) { $principalName[[string] $grant.principalId] } else { $null }

                # A space-separated scope string, sometimes with leading whitespace.
                foreach ($scope in @(([string] $grant.scope) -split '\s+' | Where-Object { $_ })) {
                    & $emit ([PSCustomObject]@{
                        PSTypeName           = 'MsecEntraAppConsent'
                        ClientDisplayName    = $client.Name
                        ClientAppId          = $client.AppId
                        ClientObjectId       = $client.ObjectId
                        ClientPublisher      = $client.Publisher
                        ClientIsMicrosoft    = $client.IsMicrosoft
                        ClientEnabled        = $client.Enabled
                        ResourceDisplayName  = $resource.Name
                        ResourceAppId        = $resource.AppId
                        Permission           = $scope
                        PermissionType       = 'Delegated'
                        # AllPrincipals = an admin agreed for the whole tenant.
                        ConsentType          = [string] $grant.consentType
                        PrincipalId          = [string] $grant.principalId
                        PrincipalDisplayName = if ($who) { $who.DisplayName } else { $null }
                        PrincipalUpn         = if ($who) { $who.Upn } else { $null }
                        IsHighRisk           = ($scope -in $highRisk)
                        GrantId              = [string] $grant.id
                        CreatedDateTime      = $null   # not exposed on oauth2PermissionGrant
                    })
                }
            }
        }
    }

    # ---------- Application ----------
    if ($PermissionType -contains 'Application') {
        # Only a service principal that PUBLISHES app roles can be the resource of one, so the
        # sweep is over those rather than over every principal in the tenant.
        $resources = @($servicePrincipals | Where-Object { @($_.appRoles).Count -gt 0 })
        Write-Verbose "Reading app role assignments from $($resources.Count) resource service principal(s)"

        foreach ($resource in $resources) {
            $assignments = $null
            try {
                $assignments = @(Invoke-MsecGraphRequest -All -Path "/v1.0/servicePrincipals/$($resource.id)/appRoleAssignedTo?`$top=999")
            }
            catch {
                Write-Warning "Could not read app role assignments on '$($resource.displayName)', so any application permission granted on it is MISSING from this output. Graph said: $($_.Exception.Message)"
                & $emit ([PSCustomObject]@{
                    PSTypeName           = 'MsecEntraAppConsent'
                    ClientDisplayName    = 'Unreadable'
                    ClientAppId          = $null
                    ClientObjectId       = $null
                    ClientPublisher      = $null
                    ClientIsMicrosoft    = $null
                    ClientEnabled        = $null
                    ResourceDisplayName  = [string] $resource.displayName
                    ResourceAppId        = [string] $resource.appId
                    Permission           = $null
                    PermissionType       = 'Application'
                    ConsentType          = 'Application'
                    PrincipalId          = $null
                    PrincipalDisplayName = $null
                    PrincipalUpn         = $null
                    IsHighRisk           = $null
                    GrantId              = $null
                    CreatedDateTime      = $null
                })
                continue
            }

            foreach ($assignment in $assignments) {
                # User and Group assignments say who may USE the app. Not consent.
                if ([string] $assignment.principalType -ne 'ServicePrincipal') { continue }

                $client = & $describe $spById[[string] $assignment.principalId] `
                                      ([string] $assignment.principalId) `
                                      ([string] $assignment.principalDisplayName)

                $permission = $roleName["$($resource.id)/$($assignment.appRoleId)"]

                & $emit ([PSCustomObject]@{
                    PSTypeName           = 'MsecEntraAppConsent'
                    ClientDisplayName    = $client.Name
                    ClientAppId          = $client.AppId
                    ClientObjectId       = $client.ObjectId
                    ClientPublisher      = $client.Publisher
                    ClientIsMicrosoft    = $client.IsMicrosoft
                    ClientEnabled        = $client.Enabled
                    ResourceDisplayName  = [string] $resource.displayName
                    ResourceAppId        = [string] $resource.appId
                    # Null when the resource no longer publishes the role the grant names -
                    # a real state after an app is updated, and not the same as no permission.
                    Permission           = $permission
                    PermissionType       = 'Application'
                    # No user is involved at all, which is the point.
                    ConsentType          = 'Application'
                    PrincipalId          = $null
                    PrincipalDisplayName = $null
                    PrincipalUpn         = $null
                    IsHighRisk           = if ($permission) { $permission -in $highRisk } else { $null }
                    GrantId              = [string] $assignment.id
                    CreatedDateTime      = $assignment.createdDateTime
                })
            }
        }
    }
}
