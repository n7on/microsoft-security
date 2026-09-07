---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecSharePointSiteUser

## SYNOPSIS
Who owns and who can edit a SharePoint site - one row per (site, person, role), with
security groups expanded to the people inside them.

## SYNTAX

```
Get-MsecSharePointSiteUser [[-Url] <String>] [-IncludeVisitors]
 [<CommonParameters>]
```

## DESCRIPTION
A site's Owners and Members groups are the permission model for SharePoint, and they
are NOT visible from Entra.
Graph exposes the Microsoft 365 group behind a
group-connected site, which is a different thing: it does not exist for classic (STS#3)
sites, and even where it does it is not what SharePoint checks.
Only PnP reads the
site's own groups, which is why this command needs it.

SECURITY GROUPS ARE EXPANDED TO PEOPLE.
A site whose Owners group contains one Entra
security group has one member as far as SharePoint is concerned and possibly forty as
far as access is concerned.
The question being asked is who can do this, so the group
is resolved through Graph and its members are emitted individually.

A GROUP THAT CANNOT BE RESOLVED EMITS A ROW SAYING SO.
SharePoint keeps the group's SID
in its login name long after the group is deleted from Entra, and it keeps granting
access to a principal that no longer resolves.
Dropping those would report the site as
having fewer owners than it does; the row carries IsResolved = $false and the group's
object id so it can be chased.

'System Account' IS EXCLUDED.
It is SharePoint's own service identity, present on every
site, and means nothing for an access review.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Get-MsecSharePointSiteUser -Url https://contoso.sharepoint.com/sites/finance
```

### EXAMPLE 2
```
# Every site, one connection each - which is how PnP works.
Connect-MsecSharePointOnline -Url https://contoso-admin.sharepoint.com
Get-PnPTenantSite | ForEach-Object { Get-MsecSharePointSiteUser -Url $_.Url }
```

### EXAMPLE 3
```
# Owners who are not in the directory any more.
Get-MsecSharePointSiteUser | Where-Object { -not $_.IsResolved }
```

## PARAMETERS

### -Url
The site collection to read.
Given this, the command connects itself - you only need
Connect-Msec beforehand, like every other command here.

Your own PnP session is left alone: the connection is made explicitly and passed to
each PnP call rather than becoming the ambient one, so a script working against another
site is not moved out from under it.

Omit it to use whatever Connect-MsecSharePointOnline last connected to.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeVisitors
Also report the Visitors (read-only) group.
Excluded by default: read access to a site
is rarely the finding, and including it roughly triples the row count.

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

### PSCustomObject per (site, principal, role), PSTypeName 'MsecSharePointSiteUser'.
## NOTES
Needs Connect-MsecSharePointOnline for the site, AND an msec Graph session
(Connect-Msec) to expand security groups - the two use different tokens for different
audiences.

Group.Read.All is what expands the groups.
Without it every group-backed entry comes
back IsResolved = $false, which is honest but much less useful.

## RELATED LINKS
