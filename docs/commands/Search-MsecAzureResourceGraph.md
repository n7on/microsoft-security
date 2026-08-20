---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Search-MsecAzureResourceGraph

## SYNOPSIS
Runs a bundled KQL query against Azure Resource Graph and returns the rows.

## SYNTAX

```
Search-MsecAzureResourceGraph [-ResourceType] <String> [[-Name] <String>] [[-Subscription] <String[]>]
 [-CurrentSubscription] [[-First] <Int32>] [[-MaxRows] <Int32>] [-NoCache]
 [<CommonParameters>]
```

## DESCRIPTION
The query is loaded by convention from:

    msec/Kql/Graph/\<ResourceType\>/\<Name\>.kql

For example, Search-MsecAzureResourceGraph -ResourceType VM loads Kql/Graph/VM/All.kql.
Each
resource-type folder has at least an All.kql; named variants (e.g.
"Running.kql")
live alongside it and are selected via -Name.

Filtering is intentionally NOT done here - that's what PowerShell pipelines are
for.
Pipe the output into Where-Object / Sort-Object / Select-Object:

    Search-MsecAzureResourceGraph -ResourceType VM | Where-Object Os -eq 'Linux' | ...

Required: Az.ResourceGraph, an Az context, and Reader RBAC at the resources'
scope (ARG honours RBAC and just omits resources you cannot see).

Pagination is automatic: pages of -First rows (max 1000, ARG's own per-page
ceiling) are followed via the response skip token until the result set is
exhausted, so row counts above 1000 come back whole.
Rule-per-row queries
blow past 1000 easily - KeyVault/NetworkRules alone is over 1100 on a
mid-sized tenant.

-MaxRows is a runaway guard, not a page size.
If a query somehow exceeds it,
output STOPS there and a warning says so.
It never truncates silently: an
under-reported security query looks exactly like a clean one.

## EXAMPLES

### EXAMPLE 1
```
Search-MsecAzureResourceGraph -ResourceType VM
```

### EXAMPLE 2
```
# Just the subscription you're currently working in - lines up with what
# Invoke-MsecAzureVMScript will act on:
Search-MsecAzureResourceGraph -ResourceType VM -CurrentSubscription
```

### EXAMPLE 3
```
Search-MsecAzureResourceGraph -ResourceType VM | Where-Object { $_.Os -eq 'Linux' -and $_.Running } |
    Invoke-MsecAzureVMScript -Os Linux -ScriptName os-info
```

### EXAMPLE 4
```
# You just closed a vault firewall and want to confirm it - do not trust a cached answer:
Search-MsecAzureResourceGraph -ResourceType KeyVault -NoCache |
    Where-Object NetworkExposure -eq 'OpenToAllNetworks'
```

## PARAMETERS

### -ResourceType
The resource-type folder under Kql/Graph/.
Tab-completes from every folder that
actually contains at least one .kql file.
A typo isn't caught at parameter binding
- it's caught a moment later when the file lookup fails with a clear path-not-found
error.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Name
KQL file base name (without extension).
Defaults to 'All'.
Tab-completes
from the .kql files in the selected ResourceType folder.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: All
Accept pipeline input: False
Accept wildcard characters: False
```

### -Subscription
Restrict to specific subscriptions, by NAME or id - 'PROD' rather than a GUID.
Names are
not unique (this estate has three called 'Cloud Subscription'), so an ambiguous name
fails with the candidate ids rather than picking one.
Omit to query every accessible
subscription.
Aliased to -SubscriptionId for anything already written against that name.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases: SubscriptionId

Required: False
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -CurrentSubscription
Scope the query to just the active Az context's subscription - shorthand for
-Subscription (Get-AzContext).Subscription.Id.
Mutually exclusive with
-Subscription.
Handy when you want results that line up with the single
subscription Invoke-MsecAzureVMScript will act on.

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

### -First
Page size (1-1000).
Default 1000, which is ARG's maximum per page.
This is not a
result limit - pages are followed until the query is exhausted.
Use -MaxRows for
a limit.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: 1000
Accept pipeline input: False
Accept wildcard characters: False
```

### -MaxRows
Safety ceiling on total rows returned across all pages.
Default 50000.
Hitting it
emits a warning and stops; results are never truncated silently.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: 50000
Accept pipeline input: False
Accept wildcard characters: False
```

### -NoCache
Query Azure instead of reusing a recent result.
The result still refreshes the cache.

Results are cached and reused BY DEFAULT, because Azure resource inventory changes on the
timescale of deployments rather than seconds.
A cached result is only reused when it was
written under the SAME tenant, for the SAME subscription scope, and within the cache
window (15 minutes) - a scoped result is never handed back to an unscoped call, which
would report a fraction of the estate as all of it.
A result truncated by -MaxRows is
never cached.

Use -NoCache when you have just changed something and are checking whether the change
took: that is the one case where minutes-old data actively misleads.

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

### PSCustomObject rows shaped by the .kql file's project clause.
## NOTES

## RELATED LINKS
