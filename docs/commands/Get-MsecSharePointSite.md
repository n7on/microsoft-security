---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecSharePointSite

## SYNOPSIS
Every SharePoint site in the tenant, classified - the inventory to run a site access
review against.

## SYNTAX

```
Get-MsecSharePointSite [-IncludeAppContainer] [-IncludePersonal] [-All]
 [<CommonParameters>]
```

## DESCRIPTION
Enumerates sites through Microsoft Graph rather than the SharePoint tenant-admin API,
and that choice is about privilege rather than preference.

Get-PnPTenantSite talks to the tenant-admin endpoint, which accepts nothing less than
Sites.FullControl.All - full read, WRITE and DELETE over every site in the tenant.
For a
list of site names, in a module that only reads, that is a bad trade.
Graph answers the
same question with Sites.Read.All.

MOST OF WHAT GRAPH CALLS A SITE IS NOT A SITE YOU WANT.
On a real tenant /sites?search=*
returned 432 results of which 286 were app containers - the backing storage for Loop
workspaces, Designer files and similar, one per artefact.
Running a site access review
across those is noise and hundreds of wasted calls.
They are classified and excluded by
default rather than filtered out silently, so the count you see is the count you meant.

SUBWEBS COME BACK TOO, not only site collections.
/sites?search=* indexes them, so
'.../sites/Finance/Archive' appears as its own row.
Worth knowing because the obvious
alternative - walking Get-PnPSubWeb per site - CANNOT work app-only: enumerating
Web.Webs needs the Browse Directories right, which the Read level that Sites.Read.All
maps to does not include, and every call returns a bare E_ACCESSDENIED.

The corollary is that a subweb is classified by its URL like anything else, so it
reports SiteType 'SiteCollection'.
The type describes the shape of the URL, not the
object's place in the hierarchy.

SiteType is one of:
  SiteCollection  a real site - /sites/ or /teams/.
What a review is about.
  AppContainer    /contentstorage/ - Loop, Designer and other app-created storage.
  Personal        someone's OneDrive.
Technically a site, never part of a site review,
                  and there is one per person in the tenant.
  Root            the tenant root site.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Get-MsecSharePointSite
```

### EXAMPLE 2
```
# The access review: every real site, and who owns it.
Get-MsecSharePointSite | ForEach-Object {
    Get-MsecSharePointSiteUser -Url $_.WebUrl
}
```

### EXAMPLE 3
```
# What the tenant actually holds, before deciding what to review.
Get-MsecSharePointSite -All | Group-Object SiteType | Sort-Object Count -Descending
```

## PARAMETERS

### -IncludeAppContainer
Include Loop and other app-created storage containers.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludePersonal
Include OneDrive personal sites.
Note these do not appear in the search Graph uses here
anyway on most tenants; the switch exists so the exclusion is explicit rather than
accidental.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -All
Include everything, classified but unfiltered.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per site, PSTypeName 'MsecSharePointSite'.
## NOTES
Needs Connect-Msec and Sites.Read.All on MICROSOFT GRAPH - which is a different
permission from the identically-named one on the SharePoint service principal.
Both are
granted by New-MsecApp -Workload SharePoint, and they do different jobs: this one
enumerates sites, the SharePoint one lets PnP read what is inside them.

No PnP session is needed here.
Get-MsecSharePointSiteUser is what needs that, and it
connects itself.

## RELATED LINKS
