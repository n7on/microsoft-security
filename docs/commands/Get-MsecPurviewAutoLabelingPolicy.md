---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecPurviewAutoLabelingPolicy

## SYNOPSIS
Auto-labeling policies - the thing that applies a sensitivity label without a user.

## SYNTAX

```
Get-MsecPurviewAutoLabelingPolicy [[-Name] <String>] [-IncludeRule]
 [<CommonParameters>]
```

## DESCRIPTION
A SENSITIVITY LABEL THAT NOBODY APPLIES PROTECTS NOTHING, and auto-labeling is the only
mechanism that applies one without a person choosing it.
A tenant with labels published
and no auto-labeling policy is relying entirely on users to classify their own content,
which is worth stating plainly in a review rather than leaving as an absence nobody
noticed.
Zero rows here is a finding, not an empty section.

Same configured-versus-enforcing split as Get-MsecPurviewDlpPolicy: Mode carries
'Enable', 'TestWithoutNotifications', 'TestWithNotifications' or 'Disable', and only
'Enable' actually labels anything.
Everything else simulates.

THE COLUMN PROJECTION HERE IS UNVERIFIED AGAINST LIVE DATA.
It was written on a tenant
with no auto-labeling policies at all, and Microsoft's cmdlet reference does not document
the returned properties, so the columns follow the DLP policy shape this cmdlet family
shares.
Nothing breaks if that is incomplete - a property PowerShell cannot find is
$null rather than an error - and Raw carries the untouched object so a missing column can
be recovered without a module change.
Check Raw first on a tenant that actually has one.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecPurviewAutoLabelingPolicy | Format-Table Name, Mode, IsEnforcing, AppliedLabel
```

### EXAMPLE 2
```
# Labels that are published to users but applied by no automatic policy.
$auto = Get-MsecPurviewAutoLabelingPolicy
Get-MsecPurviewSensitivityLabel |
    Where-Object { $_.IsPublished -and $_.DisplayName -notin $auto.AppliedLabel }
```

## PARAMETERS

### -Name
Limit to policies whose name matches.
Wildcards allowed.

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

### -IncludeRule
Attach the policy's auto-labeling rules as a Rules property.
The rules hold the
conditions - which sensitive information types trigger the label - so a policy is not
really reviewable without them.

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

### One PSCustomObject per policy, PSTypeName 'MsecPurviewAutoLabelingPolicy'.
## NOTES
Needs Connect-Msec; the compliance session opens on first use.

Read-only.

## RELATED LINKS
