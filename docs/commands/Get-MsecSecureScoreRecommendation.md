---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecSecureScoreRecommendation

## SYNOPSIS
Microsoft Secure Score recommended actions as flat rows - what is not done, how many
points it is worth, and the remediation text - joined from the live control scores and
the control profiles.

## SYNTAX

```
Get-MsecSecureScoreRecommendation [[-Category] <String[]>] [[-State] <String[]>] [-IncludeCompleted]
 [-IncludeDeprecated] [-IncludeNotApplicable] [<CommonParameters>]
```

## DESCRIPTION
This is the list the Defender portal shows under Secure Score \> Recommended actions.
Get-MsecSecureScore answers "what is the score and how has it moved"; this answers
"what would move it, and what does each one cost".

IT IS A JOIN OF TWO ENDPOINTS AND THEY DO NOT COVER THE SAME SET.
The current state
lives in the newest /security/secureScores snapshot's controlScores collection; the
title, remediation, rank and impact live in /security/secureScoreControlProfiles.
Measured on one tenant: 244 control scores against 462 profiles.
The mismatch is not
an error - a profile exists for products the tenant does not license - but it means
the join has to be explicit about which side a row came from:

  Matched        both sides present.
The normal case.
  ScoreOnly      a control is being scored with no profile to describe it.
Title and
                 Remediation are $null rather than invented, and the row is still
                 emitted - a scored control that nothing can explain is worth seeing.
  ProfileOnly    only with -IncludeNotApplicable.
Microsoft publishes the action but
                 this tenant is not being scored on it, usually a licensing gap.
                 CurrentScore is $null, NOT zero: nought points earned and not being
                 measured at all are different facts.

'on' IS THE STRING "false", NOT A BOOLEAN.
Graph returns it as text, so
\`if ($control.on)\` is true for both states and silently reports every control as
enabled.
It is converted here, and left $null when absent.

implementationStatus IS FREE TEXT AND SOMETIMES HTML.
Real values from one tenant
include '0/128 exposed devices' and a paragraph of markup listing preset policy
coverage.
It is passed through untouched because it is genuinely useful to read, but
nothing should parse it - the numbers in it move without notice.

AN IGNORED CONTROL IS NOT A COMPLETED ONE.
controlStateUpdates.state carries Default,
Ignored, ThirdParty or Reviewed.
A control someone marked Ignored still shows zero
points earned, so a naive "points available" list presents a deliberate decision as
outstanding work.
State is a column, and -State filters on it.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecSecureScoreRecommendation | Sort-Object PointsAvailable -Descending |
    Select-Object -First 10 Title, Category, PointsAvailable, UserImpact
```

The ten actions worth the most points.

### EXAMPLE 2
```
Get-MsecSecureScoreRecommendation -Category Identity |
    Where-Object { $_.UserImpact -eq 'Low' } | Sort-Object Rank
```

Identity actions that do not inconvenience anyone, in Microsoft's own priority order.

### EXAMPLE 3
```
Get-MsecSecureScoreRecommendation -State Ignored -IncludeCompleted |
    Select-Object Title, PointsAvailable, StateUpdatedBy, StateComment
```

What has been dismissed, by whom, and what it is costing.
Worth re-reading periodically
- an Ignored control is a risk acceptance that nothing expires.

## PARAMETERS

### -Category
Identity, Device, Apps, Data or Infrastructure.
Tab completes but accepts anything, so
a category Microsoft adds later is not silently unreachable.

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

### -State
Only controls in these review states.
Tab completes against the known values but
accepts anything - this tenant returns AlternateMitigation, which is not in the
documented list.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeCompleted
Also return controls with no points left.
Off by default - this command is the
recommended-actions list, and a finished control is not a recommended action.

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

### -IncludeDeprecated
Also return controls whose profile is marked deprecated.
Off by default: Microsoft
retires actions and they linger in the profile list.

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

### -IncludeNotApplicable
Also return ProfileOnly rows - published actions this tenant is not scored on.

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

### One PSCustomObject per control, PSTypeName 'MsecSecureScoreRecommendation'.
## NOTES
Needs Connect-Msec.
Reads with SecurityEvents.Read.All, which New-MsecApp grants.

## RELATED LINKS
