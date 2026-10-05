---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecEntraPimPolicy

## SYNOPSIS
The Privileged Identity Management rules for each directory role - what activation
demands, and whether a permanent assignment is allowed at all - as one row per setting.

## SYNTAX

```
Get-MsecEntraPimPolicy [[-Role] <String[]>] [-HighlyPrivilegedOnly] [-All]
 [<CommonParameters>]
```

## DESCRIPTION
Get-MsecEntraRoleHolder says WHO holds a role and whether it is active or eligible.
This says what the eligibility is actually worth: a role that can be activated for
eight hours with no MFA, no approval and no ticket is barely different from a permanent
assignment, and nothing in the holder list shows that.

TWO SETS OF RULES, AND THEY ANSWER DIFFERENT QUESTIONS.
  Activation (EndUser) - what an eligible person must do to switch the role on: MFA,
                         justification, a ticket, an approver, an authentication
                         context, and for how long it stays on.
  Assignment (Admin)   - what an administrator may hand out in the first place.
This is
                         where PermanentActiveAllowed lives, and it is the setting that
                         decides whether standing privilege is even possible.

'ActivationRequiresMfa = False' DOES NOT MEAN ACTIVATION HAPPENS WITHOUT MFA.
The
person may already be covered by a Conditional Access policy that required MFA at
sign-in.
What this setting controls is whether PIM demands a FRESH authentication at
the moment of activation - the thing that stops a stolen, already-authenticated session
from quietly switching a role on.
Read it as "no re-authentication", not "no MFA".

A POLICY ON A ROLE NOBODY IS ELIGIBLE FOR GOVERNS NOTHING.
There are around 150
directory roles and a typical tenant has eligible holders for a handful, so
HasEligibleHolder is on every row and -HighlyPrivilegedOnly narrows further.
Rows are
still returned for roles with no holders: a policy may be deliberately pre-configured
ahead of an assignment, and hiding it would make that invisible.

HIGHLY PRIVILEGED USES THE SAME LIST AS EVERY OTHER msec COMMAND, from
Get-MsecPrivilegedRoleTemplate, so this report cannot silently disagree with
Get-MsecEntraRoleHolder about which roles matter.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraPimPolicy -HighlyPrivilegedOnly |
    Where-Object { $_.Setting -eq 'ActivationRequiresMfa' -and $_.Value -eq 'False' }
```

Privileged roles that can be activated without re-authenticating.

### EXAMPLE 2
```
Get-MsecEntraPimPolicy |
    Where-Object { $_.Setting -eq 'PermanentActiveAllowed' -and $_.Value -eq 'True' -and $_.HasEligibleHolder }
```

Roles where standing privilege is still permitted.

### EXAMPLE 3
```
Get-MsecEntraPimPolicy -Role 'Global Administrator'
```

## PARAMETERS

### -Role
Role display names or roleTemplateIds.
Omit for every role.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -HighlyPrivilegedOnly
Only the roles msec treats as highly privileged.

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
One row per underlying PIM rule rather than the curated projection.

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
