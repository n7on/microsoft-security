---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecSharePointTenantSetting

## SYNOPSIS
The tenant-wide SharePoint and OneDrive settings that decide how far content can travel
outside the organisation - one row per setting.

## SYNTAX

```
Get-MsecSharePointTenantSetting [-All] [<CommonParameters>]
```

## DESCRIPTION
These are TENANT settings, not site properties, and they are the ceiling every site sits
under.
A site can be locked down and still sit in a tenant where anyone-links are on;
reviewing sites one by one never surfaces that.

ONE ROW PER SETTING, grouped into a Category, the same shape as Get-MsecTeamsPolicy.
/admin/sharepoint/settings returns roughly thirty properties covering sync clients,
storage quotas, time zones and newsfeeds; only the ones that bear on access and data
movement are projected, and which ones is a judgement this command makes on your behalf,
so it is written out in the source.
-All returns every property for checking it.

AN EMPTY LIST IS REPORTED AS '(none)' AND A MISSING VALUE AS '(not set)'.
The
distinction matters most for the domain lists: with SharingDomainRestrictionMode set to
allowList, an EMPTY SharingAllowedDomainList means nobody outside can be invited at all,
which is the opposite of what a blank cell suggests.
Neither is rendered as blank,
because a blank reads as "we did not look".

READ-ONLY, LIKE THE REST OF msec.
Changing any of this needs
SharePointTenantSettings.ReadWrite.All, which New-MsecApp does not grant - use the
SharePoint admin centre.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Get-MsecSharePointTenantSetting
```

### EXAMPLE 2
```
# The three that decide external reach.
Get-MsecSharePointTenantSetting |
    Where-Object Category -eq 'Sharing' |
    Format-Table Setting, Value
```

## PARAMETERS

### -All
Return every property Graph reports, not just the security-relevant projection.
Unprojected settings come back with Category 'Other'.

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

### PSCustomObject per setting, PSTypeName 'MsecSharePointTenantSetting'.
## NOTES
Needs Connect-Msec and SharePointTenantSettings.Read.All on MICROSOFT GRAPH, which
New-MsecApp -Workload SharePoint grants.
Sites.Read.All does NOT cover this endpoint -
that one reads sites, and these are tenant settings - and without the right permission
Graph returns a bare 403 that names no permission at all.

This is the only route msec has to these settings.
The PnP equivalent, Get-PnPTenant,
needs a token whose audience is the tenant's ADMIN HOST, and Get-AzAccessToken cannot
mint one - see Connect-MsecSharePointOnline's notes.

## RELATED LINKS
