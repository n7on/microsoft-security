---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecIntuneAsrRule

## SYNOPSIS
Every Attack Surface Reduction rule, the mode it is set to, which policy sets it, who
that policy reaches - and the rules no policy configures at all.

## SYNTAX

```
Get-MsecIntuneAsrRule [[-Rule] <String>] [[-Mode] <String>] [-ConfiguredOnly] [-NoGroupNameLookup] [<CommonParameters>]
```

## DESCRIPTION
ASR rules are configured as settings INSIDE endpoint security policies, so neither
"list the policies" nor "list the settings" answers the question anyone actually has,
which is "which rules are we enforcing, on whom, and which are we not".
This flattens
the policies into one row per rule per policy and fills in the gaps.

THE RULES NOBODY CONFIGURED ARE THE POINT, AND THEY ARE INVISIBLE IN THE PORTAL.
A
policy blade shows the rules that policy sets; a rule set by no policy appears nowhere,
so the gap can only be found by diffing against the full catalogue by hand.
Every rule
is emitted, with Configured = $false and Mode = $null where nothing sets it.
Measured on
one tenant: two baseline policies carrying 16 rules each, and 'Block rebooting machine
in Safe Mode' configured in neither - a gap invisible from either policy blade.

THE CATALOGUE COMES FROM GRAPH, NOT FROM A LIST IN THIS FILE.
The rule set is read from
the setting definitions, so a rule Microsoft adds appears here the day it ships instead
of being silently absent until somebody updates the module.
Only the GUIDs are local -
they are not in the definitions and are what documentation and PowerShell use - and a
rule with no GUID mapping is still emitted, with RuleId $null, rather than dropped.

MODE IS NOT A BOOLEAN AND 'OFF' IS NOT 'NOT CONFIGURED'.
A rule explicitly set to off
in a policy that reaches a device beats a rule left unconfigured, because the explicit
value wins conflict resolution.
Those two are different rows here - Mode 'off' with
Configured $true, against Mode $null with Configured $false - and conflating them is how
a deliberate carve-out gets mistaken for an oversight and quietly 'fixed'.

TWO MODES IS NOT AUTOMATICALLY A CONFLICT.
The most common deliberate ASR design is a
rule in audit for one group and block for everyone else, with the two policies excluding
each other's groups - measured on one tenant, the single rule set to two modes was
exactly that.
So ModesDiffer is the fact, and Conflicting is the judgement: it is $true
only where the policies do NOT carve each other out and a device may therefore receive
both, which Intune resolves silently with the losing value shown in neither blade.
Proving real overlap would need group membership evaluation and this does not do it, so
Conflicting is deliberately the weaker claim of the two.

PER-RULE EXCLUSIONS TRAVEL WITH THE RULE.
Each ASR setting carries its own exclusion
list, and an exclusion is a deliberate hole in a control - it belongs next to the mode,
not three blades away.
Excluded paths are projected to PerRuleExclusion.

That list is nested UNDER the rule's own value rather than beside it, which the setting
id ('\<rule\>_perruleexclusions') does not suggest.
Read at the wrong depth it comes back
empty, so a policy carrying a real exclusion reports none - measured on one tenant
against a live Git exclusion.
The subtree is walked rather than indexed at a fixed
depth.

ONLY SETTINGS CATALOG AND ENDPOINT SECURITY POLICIES ARE PARSED.
ASR can also be set
through the older intents API, classic endpoint protection profiles, Group Policy or
local PowerShell, and none of those are read here.
Where the tenant has any of the first
two, a warning names them, because an unqualified Configured = $false would be a claim
this command cannot support.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecIntuneAsrRule | Where-Object { -not $_.Configured }
```

The rules no policy sets.
The gap no portal blade will show you.

### EXAMPLE 2
```
Get-MsecIntuneAsrRule | Where-Object Conflicting |
    Sort-Object RuleName | Format-Table RuleName, Mode, PolicyName
```

Rules set to different modes by two policies.
Intune picks a winner silently.

### EXAMPLE 3
```
Get-MsecIntuneAsrRule -Mode audit
```

What is being measured rather than enforced - the staging area of an ASR rollout, and
the set most likely to have been left there and forgotten.

### EXAMPLE 4
```
Get-MsecIntuneAsrRule | Where-Object PerRuleExclusion |
    Select-Object RuleName, PolicyName, PerRuleExclusion
```

Every deliberate hole in an ASR rule, with the policy it lives in.

## PARAMETERS

### -Rule
Only rules whose name or slug matches this substring, case-insensitive.
'safe mode',
'psexec', 'office'.

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

### -Mode
Only rules set to this mode: 'block', 'audit', 'warn' or 'off'.

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

### -ConfiguredOnly
Drop the rules no policy configures.
Off by default, because those rows are usually the
reason to run this.

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

### -NoGroupNameLookup
Report assignment group ids instead of resolving their display names.
One Graph call per
distinct group is spent on the lookup otherwise, cached across the run.

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

### PSCustomObject per rule-and-policy pair, PSTypeName 'MsecIntuneAsrRule'.
## NOTES
Needs 'DeviceManagementConfigurationPolicy.Read.All' or
'DeviceManagementConfiguration.Read.All', which New-MsecApp grants, plus Group.Read.All
for the assignment group names.

## RELATED LINKS
