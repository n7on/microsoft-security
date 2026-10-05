---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecSentinelRule

## SYNOPSIS
Microsoft Sentinel analytics rules with their tuning state - severity, alert grouping,
suppression - and the id that joins them to the alerts they produced.

## SYNTAX

```
Get-MsecSentinelRule [[-SubscriptionId] <String>] [[-ResourceGroupName] <String>] [[-WorkspaceName] <String>]
 [-EnabledOnly] [<CommonParameters>]
```

## DESCRIPTION
A Sentinel workspace accumulates rules from the Content Hub faster than anyone tunes
them, and the portal shows one rule at a time.
This returns all of them as flat rows,
so 'which rules have never been tuned' and 'which rules produce every alert we close as
a false positive' are both one pipeline.

RULEID IS THE JOIN TO THE ALERTS.
A rule's resource name is a GUID, and that GUID is
the alertPolicyId on every alert the rule raised - so RuleId joins directly to
Get-MsecDefenderAlert's Raw.alertPolicyId.
Matching on the display name instead looks
equivalent and is not: titles are edited, duplicated between a stock rule and a tuned
copy, and localised.

TUNING STATE IS THE POINT, NOT THE QUERY.
GroupingEnabled, SuppressionEnabled and
TriggerThreshold are what decide how much noise a rule makes.
Alert grouping in
particular is off by default on every Content Hub rule, and with it off each alert
becomes its own incident - measured on one workspace, 0 of 48 rules had it enabled.
The KQL is in Raw for the rules you actually want to read.

RUNS AS THE SIGNED-IN USER, NOT AS THE msec APP.
Sentinel is an Azure resource, so this
reads through ARM on your Az context like Get-MsecAzureSecureScore and
Search-MsecAzureResourceGraph.
The app certificate holds Graph permissions, not Azure
RBAC.
One command, one identity.

A WORKSPACE THAT IS NOT ONBOARDED TO SENTINEL IS SKIPPED WHEN DISCOVERING, AND NAMED
WHEN ASKED FOR.
Discovery walks the Log Analytics workspaces in scope and most of them
are ordinary log workspaces; naming one explicitly and getting silence back would read
as a Sentinel with no rules, which is a different and much more alarming thing.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecSentinelRule | Where-Object { $_.Enabled -and -not $_.GroupingEnabled }
```

Enabled rules with alert grouping off - every alert becomes its own incident.

### EXAMPLE 2
```
$rules  = Get-MsecSentinelRule
$alerts = Get-MsecDefenderAlert
$alerts | Group-Object { $_.Raw.alertPolicyId } | ForEach-Object {
    $rule = $rules | Where-Object RuleId -eq $_.Name
    [pscustomobject]@{
        Rule       = if ($rule) { $rule.DisplayName } else { '(not a Sentinel rule)' }
        Alerts     = $_.Count
        Grouping   = $rule.GroupingEnabled
        Severity   = $rule.Severity
    }
} | Sort-Object Alerts -Descending
```

Alert volume per rule, with whether that rule has ever been tuned.
This is the join the
command exists for.

### EXAMPLE 3
```
Get-MsecSentinelRule -EnabledOnly |
    Group-Object Severity | Sort-Object Count -Descending
```

How many rules sit at each severity.
A tier with most of the rules in it is a volume
band, not a severity.

## PARAMETERS

### -SubscriptionId
Subscription to search.
Defaults to the active Az context.
Use Select-MsecAzureContext
to move the context itself.

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

### -ResourceGroupName
Only workspaces in this resource group.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -WorkspaceName
A specific Log Analytics workspace.
Omit to find every Sentinel-onboarded workspace in
scope.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -EnabledOnly
Only rules that are switched on.

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

### System.Management.Automation.PSObject
## NOTES

## RELATED LINKS
