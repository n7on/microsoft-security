---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Search-MsecLogAnalytics

## SYNOPSIS
Runs a bundled KQL query against a Log Analytics workspace and returns the rows.

## SYNTAX

### Days (Default)
```
Search-MsecLogAnalytics -Subject <String> [-Name <String>] -WorkspaceName <String>
 [-ResourceGroupName <String>] [-Days <Int32>] [-MaxRows <Int32>]
 [<CommonParameters>]
```

### Timespan
```
Search-MsecLogAnalytics -Subject <String> [-Name <String>] -WorkspaceName <String>
 [-ResourceGroupName <String>] -Timespan <TimeSpan> [-MaxRows <Int32>]
 [<CommonParameters>]
```

## DESCRIPTION
The Log Analytics counterpart to Search-MsecAzureResourceGraph.
Same idea, same
file-on-disk convention, different engine - and the differences matter, so read the
four NB sections below before writing a .kql for this.

The query is loaded by convention from:

    msec/Kql/Law/\<Subject\>/\<Name\>.kql

For example, Search-MsecLogAnalytics -Subject Waf loads Kql/Law/Waf/All.kql.
Each
subject folder has at least an All.kql; named variants (e.g.
"TopRules.kql") live
alongside it and are selected via -Name.

SUBJECT, NOT RESOURCE TYPE.
Resource Graph keys its folders on the ARM resource type
because every row genuinely has one.
Log Analytics rows do not: SigninLogs is about
identities and AuditLogs about directory changes, neither of which is an ARM resource.
So the first level here is the SUBJECT the rows are about.
Where a subject also exists
under Kql/Graph the folder name is deliberately the same, so the two trees line up -
Graph/Waf tells you which managed rules are switched off, Law/Waf tells you which ones
actually fired.

Keying on the TABLE was the obvious alternative and it does not survive contact with
reality: AzureDiagnostics is one table holding App Gateway, Key Vault and a dozen other
resource types' logs, and the same App Gateway data lands either there or in
AGWFirewallLogs depending on one per-resource diagnostic setting.
A folder key that
flips based on a diagnostic setting is not a key.

Required: Az.OperationalInsights, Az.ResourceGraph, an Az context, and Log Analytics
Reader on the workspace.

## EXAMPLES

### EXAMPLE 1
```
Search-MsecLogAnalytics -Subject Waf -Name TopRules -WorkspaceName prod-sentinel-log
```

### EXAMPLE 2
```
# Last four hours - what is firing right now, during an incident:
Search-MsecLogAnalytics -Subject Waf -WorkspaceName prod-sentinel-log -Timespan 4:00
```

### EXAMPLE 3
```
# Which WAF rules actually fire, against which rules are switched off:
$fired    = Search-MsecLogAnalytics -Subject Waf -Name TopRules -WorkspaceName prod-sentinel-log -Days 30
$disabled = Search-MsecAzureResourceGraph -ResourceType Waf -Name ManagedRules |
                Where-Object Disabled
$fired | Where-Object { $_.RuleId -in $disabled.RuleId }   # firing despite being disabled
```

### EXAMPLE 4
```
# Discover workspace names to pass to -WorkspaceName, and prime tab completion:
Search-MsecAzureResourceGraph -ResourceType LogAnalytics |
    Select-Object Name, SubscriptionName, Location, RetentionDays
```

## PARAMETERS

### -Subject
The subject folder under Kql/Law/.
Tab-completes from every folder that actually
contains at least one .kql file.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Name
KQL file base name (without extension).
Defaults to 'All'.
Tab-completes from the .kql
files in the selected Subject folder.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: All
Accept pipeline input: False
Accept wildcard characters: False
```

### -WorkspaceName
The workspace to query.
MANDATORY and deliberately so - see the NB on workspace scope.
Resolved by name through Resource Graph across every accessible subscription, so you do
not need to know which subscription or resource group it lives in.
A name that matches
nothing, or matches more than one workspace, fails with the list of candidates rather
than picking one.

Tab-completes from a local cache, never from a live query - see the comment on the
parameter.
Any call that reaches Azure refreshes it; on a fresh machine prime it with
Search-MsecAzureResourceGraph -ResourceType LogAnalytics.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ResourceGroupName
Disambiguates when the same workspace name exists in more than one resource group.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Days
Time window in whole days, passed to the API as a server-side timespan.
Default 7.
The .kql files do NOT carry their own time filter - see the NB below.

```yaml
Type: Int32
Parameter Sets: Days
Aliases:

Required: False
Position: Named
Default value: 7
Accept pipeline input: False
Accept wildcard characters: False
```

### -Timespan
Time window for anything shorter or finer than a day - 4:00 for four hours, 0:30 for
thirty minutes, 1.12:00:00 for a day and a half.
Mutually exclusive with -Days.

A BARE INTEGER is a trap here: PowerShell coerces it to ticks, so -Timespan 7 means 700
nanoseconds, not 7 days.
Anything under a minute is rejected rather than silently
returning an empty result set.

```yaml
Type: TimeSpan
Parameter Sets: Timespan
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -MaxRows
Safety ceiling on rows returned.
Default 50000.
Hitting it emits a warning and stops;
results are never truncated silently.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: 50000
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject rows shaped by the .kql file's project or summarize clause.
## NOTES
NB - WORKSPACE SCOPE.
Search-MsecAzureResourceGraph defaults to every accessible
subscription because Resource Graph is genuinely tenant-wide.
Log Analytics is not:
data lives in whichever workspace the diagnostic setting pointed at, and a mid-sized
estate has dozens of workspaces sharded by region and purpose.
Defaulting to a fan-out
would mean most queries fail against most workspaces, because a table that does not
exist in a workspace is a hard query error rather than an empty result.
So the
workspace is mandatory and explicit.
Nothing is ever queried that you did not name.

NB - TIME IS A PARAMETER, NOT PART OF THE QUERY.
-Days (or -Timespan) is passed to the
API as a timespan, which the service applies server-side against the TimeGenerated
index.
The .kql files therefore contain NO \`where TimeGenerated \> ago(...)\` clause.
This
is the same separation as Search-MsecAzureResourceGraph doing no filtering in KQL: a
window baked into the file is invisible at the call site and cannot be widened without
editing the file.
It is also why a sub-day window needed a new parameter rather than a
change to any query.

NB - NO PAGINATION.
Resource Graph hands out a skip token and this module follows it
until the result set is exhausted.
The Log Analytics query API has no equivalent: it
caps a response at 500,000 rows / 64 MB and there is no continuation token, so you
page by narrowing -Days.
That is why the bundled .kql files summarize server-side
wherever the raw grain would be large - Application Gateway alone writes millions of
access-log rows a day, and pulling those through PowerShell to filter them is not a
plan.
A response that comes back exactly at the cap is warned about, loudly, because a
truncated security query looks exactly like a clean one.

NB - VALUES ARRIVE AS STRINGS.
The query API is untyped on the wire and
Invoke-AzOperationalInsightsQuery surfaces every column as a string.
A column that is
a number in KQL sorts lexically in PowerShell unless you cast it - '9' sorts after
'10'.
Cast at the call site: Sort-Object { \[int\]$_.Hits } -Descending.

## RELATED LINKS
