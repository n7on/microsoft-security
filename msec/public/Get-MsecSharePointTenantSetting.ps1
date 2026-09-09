function Get-MsecSharePointTenantSetting {
    <#
    .SYNOPSIS
        The tenant-wide SharePoint and OneDrive settings that decide how far content can travel
        outside the organisation - one row per setting.

    .DESCRIPTION
        These are TENANT settings, not site properties, and they are the ceiling every site sits
        under. A site can be locked down and still sit in a tenant where anyone-links are on;
        reviewing sites one by one never surfaces that.

        ONE ROW PER SETTING, grouped into a Category, the same shape as Get-MsecTeamsPolicy.
        /admin/sharepoint/settings returns roughly thirty properties covering sync clients,
        storage quotas, time zones and newsfeeds; only the ones that bear on access and data
        movement are projected, and which ones is a judgement this command makes on your behalf,
        so it is written out in the source. -All returns every property for checking it.

        AN EMPTY LIST IS REPORTED AS '(none)' AND A MISSING VALUE AS '(not set)'. The
        distinction matters most for the domain lists: with SharingDomainRestrictionMode set to
        allowList, an EMPTY SharingAllowedDomainList means nobody outside can be invited at all,
        which is the opposite of what a blank cell suggests. Neither is rendered as blank,
        because a blank reads as "we did not look".

        READ-ONLY, LIKE THE REST OF msec. Changing any of this needs
        SharePointTenantSettings.ReadWrite.All, which New-MsecApp does not grant - use the
        SharePoint admin centre.

    .PARAMETER All
        Return every property Graph reports, not just the security-relevant projection.
        Unprojected settings come back with Category 'Other'.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Get-MsecSharePointTenantSetting

    .EXAMPLE
        # The three that decide external reach.
        Get-MsecSharePointTenantSetting |
            Where-Object Category -eq 'Sharing' |
            Format-Table Setting, Value

    .OUTPUTS
        PSCustomObject per setting, PSTypeName 'MsecSharePointTenantSetting'.

    .NOTES
        Needs Connect-Msec and SharePointTenantSettings.Read.All on MICROSOFT GRAPH, which
        New-MsecApp -Workload SharePoint grants. Sites.Read.All does NOT cover this endpoint -
        that one reads sites, and these are tenant settings - and without the right permission
        Graph returns a bare 403 that names no permission at all.

        This is the only route msec has to these settings. The PnP equivalent, Get-PnPTenant,
        needs a token whose audience is the tenant's ADMIN HOST, and Get-AzAccessToken cannot
        mint one - see Connect-MsecSharePointOnline's notes.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch] $All
    )

    Assert-MsecSession

    # The settings worth reporting, and why. Written out rather than derived, because "which of
    # these thirty properties is a security control" is exactly the judgement a reader needs to
    # be able to check and argue with.
    $projection = [ordered]@{
        # How far content can travel, and to whom.
        sharingCapability                             = 'Sharing'  # anyone-links, guests, or off
        sharingDomainRestrictionMode                  = 'Sharing'  # none, allowList or blockList
        sharingAllowedDomainList                      = 'Sharing'
        sharingBlockedDomainList                      = 'Sharing'
        isResharingByExternalUsersEnabled             = 'Sharing'  # a guest passing access on
        isRequireAcceptingUserToMatchInvitedUserEnabled = 'Sharing' # or the link works for anyone who gets it

        # Legacy auth is the one most worth seeing: it bypasses Conditional Access entirely.
        isLegacyAuthProtocolsEnabled                  = 'Authentication'
        idleSessionSignOut                            = 'Authentication'

        # Content leaving onto a machine nobody manages.
        isUnmanagedSyncAppForTenantRestricted         = 'Sync'
        allowedDomainGuidsForSyncApp                  = 'Sync'
        excludedFileExtensionsForSyncApp              = 'Sync'

        # Where content can appear, and how long it lingers after someone leaves.
        isSiteCreationEnabled                         = 'Governance'
        isLoopEnabled                                 = 'Governance'
        deletedUserPersonalSiteRetentionPeriodInDays  = 'Governance'
    }

    try {
        $settings = Invoke-MsecGraphRequest -Path '/v1.0/admin/sharepoint/settings'
    }
    catch {
        $detail = $_.Exception.Message
        if ($detail -match '403|Forbidden|accessDenied') {
            throw "Forbidden reading the SharePoint tenant settings. The msec app needs 'SharePointTenantSettings.Read.All' on MICROSOFT GRAPH - Sites.Read.All does NOT cover this endpoint, and Graph's 403 names no permission. Run New-MsecApp -Workload SharePoint, then Connect-Msec again so the new grant is in the token. Original error: $detail"
        }
        throw "Could not read the SharePoint tenant settings: $detail"
    }

    # Graph returns the object itself, not a collection, so there is no .value to unwrap.
    $names = if ($All) {
        @($settings.PSObject.Properties.Name | Where-Object { $_ -notmatch '^@odata' })
    }
    else {
        # Only what this tenant actually reports - the property set moves as Microsoft adds
        # settings, and asking for an absent one would emit a row of nulls that reads as
        # "configured off" rather than "not present in this tenant".
        @($projection.Keys | Where-Object { $_ -in $settings.PSObject.Properties.Name })
    }

    foreach ($name in $names) {
        $raw = $settings.$name

        # One level of nesting is flattened rather than printed as a type name:
        # idleSessionSignOut is an object, and 'Setting = idleSessionSignOut,
        # Value = System.Management.Automation.PSCustomObject' tells a reader nothing.
        $isNested = $null -ne $raw -and
                    $raw -isnot [string] -and
                    $raw -isnot [ValueType] -and
                    $raw -isnot [System.Collections.IEnumerable]

        $pairs = if ($isNested) {
            foreach ($child in $raw.PSObject.Properties) {
                @{ Name = "$name.$($child.Name)"; Value = $child.Value }
            }
        }
        else {
            , @{ Name = $name; Value = $raw }
        }

        foreach ($pair in $pairs) {
            $value = $pair.Value

            $rendered =
                if ($null -eq $value) { '(not set)' }
                elseif ($value -isnot [string] -and $value -is [System.Collections.IEnumerable]) {
                    $items = @($value)
                    # '(none)' rather than blank: with an allowList restriction mode an EMPTY
                    # allowed-domain list means nobody outside can be invited, and a blank cell
                    # reads as "not measured" instead.
                    if ($items.Count) { ($items | ForEach-Object { "$_" }) -join '; ' } else { '(none)' }
                }
                else { [string] $value }

            [PSCustomObject]@{
                PSTypeName = 'MsecSharePointTenantSetting'
                Category   = if ($projection.Contains($name)) { $projection[$name] } else { 'Other' }
                Setting    = $pair.Name
                Value      = $rendered
            }
        }
    }
}
