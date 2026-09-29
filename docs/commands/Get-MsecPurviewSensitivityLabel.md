---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecPurviewSensitivityLabel

## SYNOPSIS
Sensitivity labels, with what protection each one actually applies and which policy
publishes it.

## SYNTAX

```
Get-MsecPurviewSensitivityLabel [[-Name] <String>] [<CommonParameters>]
```

## DESCRIPTION
THE PROTECTION SETTINGS ARE NOT WHERE YOU WOULD LOOK FOR THEM.
Get-Label has no
EncryptionEnabled property - asking for one returns empty on every label, which reads
exactly like "no label encrypts anything" and is wrong.
The settings live in
LabelActions, a collection of JSON strings, one per action, each carrying its own
settings including whether that action is switched off.

SO CONFIGURED AND ENABLED ARE SEPARATE COLUMNS, because they genuinely differ.
Measured
on one tenant: Internal and Confidential both carry an encrypt action, and both have it
disabled.
The effect is the same as having none, but the cause is the opposite - someone
set encryption up and turned it off, which is a decision to revisit rather than work
never done.

NB THE DISABLED FLAG ARRIVES AS THE STRING 'true' OR 'false'.
In PowerShell the string
'false' is TRUTHY, so a plain truthiness test on it reports every action as disabled.
This compares the text explicitly; anything writing new checks against LabelActions has
to do the same.

A LABEL NOBODY PUBLISHES CANNOT BE APPLIED.
PublishedBy lists the label policies that
offer it to users, and IsPublished is false when none do - a label that exists but
reaches nobody is a common leftover from a pilot and is invisible in the label list.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecPurviewSensitivityLabel |
    Format-Table Priority, DisplayName, EncryptionConfigured, EncryptionEnabled, IsPublished
```

### EXAMPLE 2
```
# Labels where protection was set up and then switched off.
Get-MsecPurviewSensitivityLabel |
    Where-Object { $_.EncryptionConfigured -and -not $_.EncryptionEnabled }
```

### EXAMPLE 3
```
# Labels that exist but reach nobody.
Get-MsecPurviewSensitivityLabel | Where-Object { -not $_.IsPublished }
```

## PARAMETERS

### -Name
Limit to labels whose name or display name matches.
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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### One PSCustomObject per label, PSTypeName 'MsecPurviewSensitivityLabel'.
## NOTES
Needs Connect-Msec.
The compliance session is opened automatically on first use - that
handshake takes a few seconds and imports a few hundred cmdlets, so it is reported rather
than done silently.
Call Connect-MsecPurview yourself to control -Organization, or to
choose when those 102 cmdlet names land in your runspace.

Read-only.

## RELATED LINKS
