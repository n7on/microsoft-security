---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecDefenderOfficePolicy

## SYNOPSIS
The Defender for Office 365 and Exchange Online Protection policies that filter mail -
anti-phishing, Safe Links, Safe Attachments, anti-spam, anti-malware, outbound spam -
as one row per setting, with whether the policy applies to anyone.

## SYNTAX

```
Get-MsecDefenderOfficePolicy [[-PolicyType] <String[]>] [-UnappliedOnly] [-All] [<CommonParameters>]
```

## DESCRIPTION
msec already reads Exchange MAIL FLOW: transport rules, remote domains, outbound
forwarding.
This reads the protection stack sitting on top of it, which is where
phishing and malware are actually caught or missed.

A POLICY THAT APPLIES TO NOBODY IS THE POINT, not an empty result.
In Exchange Online
Protection a policy and the rule that applies it are separate objects, and a custom
policy with no rule is inert however carefully it was written.
Every row therefore
carries IsApplied and AppliedBy, so \`Where-Object { -not $_.IsApplied }\` is the whole
question.

HOW A POLICY COMES TO APPLY, in the order this command tests:
  Default    - IsDefault.
Applies to everyone not matched by something above it.
Never
               has a rule, and must not be reported as unapplied.
  Preset     - named by an enabled EOP or ATP protection policy rule (the Standard and
               Strict preset security policies).
These also have no rule of their own,
               for the same reason.
Microsoft evaluates presets BEFORE custom policies,
               so a weak custom policy does not necessarily win just by existing.
  Built-in   - Microsoft's Built-In Protection Policy, the floor for Safe Links and
               Safe Attachments.
  Rule       - a custom policy named by its own *Rule.
AppliedTo carries the rule's
               recipient conditions.
  (none)     - a custom policy no rule references.
Inert.

PRESET POLICIES ARE NOT MISCONFIGURATION.
Reporting 'Strict Preset Security Policy' as
unapplied because Get-AntiPhishRule does not mention it would be crying wolf on the one
configuration Microsoft most recommends.

ADVANCED DELIVERY IS REPORTED AS UNREADABLE WHERE IT CANNOT BE READ.
The phishing
simulation and SecOps overrides fail server-side under an app-only session on at least
some tenants, and 'could not read' must not render as 'not configured' - that is the
difference between a tenant with a phishing-simulation exemption and one without.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecDefenderOfficePolicy -UnappliedOnly
```

Policies someone wrote that are not in force.

### EXAMPLE 2
```
Get-MsecDefenderOfficePolicy -PolicyType AntiSpam |
    Where-Object Setting -eq 'AllowedSenderDomains'
```

Domains exempted from spam filtering - an allow list here bypasses filtering entirely.

### EXAMPLE 3
```
Get-MsecDefenderOfficePolicy -PolicyType Preset
```

Which preset security policies are on, and who they cover.

## PARAMETERS

### -PolicyType
Which areas to read.
Default is all of them.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: @('Preset', 'AntiPhish', 'SafeLinks', 'SafeAttachment',
                                   'AntiSpam', 'AntiMalware', 'OutboundSpam', 'AdvancedDelivery')
Accept pipeline input: False
Accept wildcard characters: False
```

### -UnappliedOnly
Only policies that currently apply to nobody.

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
Every property of every policy, not just the security-relevant projection.

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
