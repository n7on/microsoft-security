function Get-MsecSharePointSite {
    <#
    .SYNOPSIS
        Every SharePoint site in the tenant, classified - the inventory to run a site access
        review against.

    .DESCRIPTION
        Enumerates sites through Microsoft Graph rather than the SharePoint tenant-admin API,
        and that choice is about privilege rather than preference.

        Get-PnPTenantSite talks to the tenant-admin endpoint, which accepts nothing less than
        Sites.FullControl.All - full read, WRITE and DELETE over every site in the tenant. For a
        list of site names, in a module that only reads, that is a bad trade. Graph answers the
        same question with Sites.Read.All.

        MOST OF WHAT GRAPH CALLS A SITE IS NOT A SITE YOU WANT. On a real tenant /sites?search=*
        returned 432 results of which 286 were app containers - the backing storage for Loop
        workspaces, Designer files and similar, one per artefact. Running a site access review
        across those is noise and hundreds of wasted calls. They are classified and excluded by
        default rather than filtered out silently, so the count you see is the count you meant.

        SiteType is one of:
          SiteCollection  a real site - /sites/ or /teams/. What a review is about.
          AppContainer    /contentstorage/ - Loop, Designer and other app-created storage.
          Personal        someone's OneDrive. Technically a site, never part of a site review,
                          and there is one per person in the tenant.
          Root            the tenant root site.

    .PARAMETER IncludeAppContainer
        Include Loop and other app-created storage containers.

    .PARAMETER IncludePersonal
        Include OneDrive personal sites. Note these do not appear in the search Graph uses here
        anyway on most tenants; the switch exists so the exclusion is explicit rather than
        accidental.

    .PARAMETER All
        Include everything, classified but unfiltered.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Get-MsecSharePointSite

    .EXAMPLE
        # The access review: every real site, and who owns it.
        Get-MsecSharePointSite | ForEach-Object {
            Get-MsecSharePointSiteUser -Url $_.WebUrl
        }

    .EXAMPLE
        # What the tenant actually holds, before deciding what to review.
        Get-MsecSharePointSite -All | Group-Object SiteType | Sort-Object Count -Descending

    .OUTPUTS
        PSCustomObject per site, PSTypeName 'MsecSharePointSite'.

    .NOTES
        Needs Connect-Msec and Sites.Read.All on MICROSOFT GRAPH - which is a different
        permission from the identically-named one on the SharePoint service principal. Both are
        granted by New-MsecApp -Workload SharePoint, and they do different jobs: this one
        enumerates sites, the SharePoint one lets PnP read what is inside them.

        No PnP session is needed here. Get-MsecSharePointSiteUser is what needs that, and it
        connects itself.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch] $IncludeAppContainer,
        [switch] $IncludePersonal,
        [switch] $All
    )

    Assert-MsecSession

    $sites = @()
    try {
        # search=* is the documented way to enumerate every site an app can see. The plain
        # /sites collection returns a different and less complete set.
        $sites = @(Invoke-MsecGraphRequest -All -Path '/v1.0/sites?search=*')
    }
    catch {
        $detail = $_.Exception.Message
        if ($detail -match '403|Forbidden') {
            throw "Forbidden enumerating sites. The msec app needs 'Sites.Read.All' on MICROSOFT GRAPH - note this is NOT the same permission as Sites.Read.All on the SharePoint service principal, and having one does not grant the other. Run New-MsecApp -Workload SharePoint. Original error: $detail"
        }
        throw
    }

    if (-not $sites.Count) {
        Write-Warning 'No sites returned. Check that Sites.Read.All is granted on Microsoft Graph and consented.'
        return
    }

    foreach ($site in $sites) {
        $webUrl = [string] $site.webUrl

        $siteType =
            if ($webUrl -match '(?i)-my\.sharepoint\.[a-z.]+/personal/') { 'Personal' }
            elseif ($webUrl -match '(?i)/contentstorage/')               { 'AppContainer' }
            elseif ($webUrl -match '(?i)/(sites|teams)/')                { 'SiteCollection' }
            elseif ($site.root)                                          { 'Root' }
            else                                                         { 'Other' }

        if (-not $All) {
            if ($siteType -eq 'AppContainer' -and -not $IncludeAppContainer) { continue }
            if ($siteType -eq 'Personal' -and -not $IncludePersonal) { continue }
        }

        [PSCustomObject]@{
            PSTypeName       = 'MsecSharePointSite'
            DisplayName      = $site.displayName
            SiteType         = $siteType
            WebUrl           = $webUrl
            Name             = $site.name
            Description      = $site.description
            CreatedDateTime  = $site.createdDateTime
            LastModifiedDateTime = $site.lastModifiedDateTime
            Hostname         = $site.siteCollection.hostname
            Id               = $site.id
        }
    }
}
