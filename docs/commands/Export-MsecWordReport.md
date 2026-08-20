---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Export-MsecWordReport

## SYNOPSIS
Build a Word (.docx) report from any pipeline of objects.
Detects the shape
of the input and renders with the matching template.

## SYNTAX

```
Export-MsecWordReport [-InputObject] <PSObject> [-Path] <String> [[-Title] <String>] [[-Subtitle] <String>]
 [[-TableStyle] <String>] [<CommonParameters>]
```

## DESCRIPTION
Shape-aware: the function inspects the first row's properties and picks the
right layout.

  - VMScript : Invoke-MsecAzureVMScript rows (have VmName + ScriptName + Output).
              One VM per page, with captured Output/Error rendered in
              Courier New.
The ISO-27001-evidence layout.
  - Generic  : anything else.
A single Word table whose columns are the
              visible properties of the first row.
Useful for piping things
              like Get-MsecSecureScore, Get-MsecIntuneConfigurationProfile, etc.

Pure-PowerShell via PSWriteOffice (which wraps OfficeIMO).
No pandoc,
no Word, no Windows-only Interop.
Install once:

    Install-Module PSWriteOffice -Scope CurrentUser

## EXAMPLES

### EXAMPLE 1
```
one VM per page, monospaced script output.
Search-MsecAzureResourceGraph -ResourceType VM | Where-Object Running |
    Invoke-MsecAzureVMScript -ScriptName ntp-status |
    Export-MsecWordReport -Path ./ntp-evidence.docx -Title 'NTP / Time sync evidence'
```

### EXAMPLE 2
```
single banded-row Word table.
Get-MsecSecureScore -History 12 |
    Export-MsecWordReport -Path ./secure-score-history.docx -Title 'Secure Score Trend'
```

## PARAMETERS

### -InputObject
Pipeline input.
Any shape - the function detects it after the pipeline ends.

```yaml
Type: PSObject
Parameter Sets: (All)
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: True (ByValue)
Accept wildcard characters: False
```

### -Path
Output .docx path.
Existing files are overwritten.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Title
Cover-page title.
Defaults to a shape-appropriate label when omitted.

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

### -Subtitle
Optional subtitle / context line (e.g.
'ISO 27001 A.8.17 Evidence').

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -TableStyle
Word table style for the Generic shape.
Defaults to 'PlainTable3' (banded
rows + bold header).
Any value of OfficeIMO.Word.WordTableStyle is valid
(TableGrid, GridTable1Light, GridTable4Accent1, ...).
Ignored for the
VMScript shape.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: PlainTable3
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### FileInfo for the produced .docx.
## NOTES

## RELATED LINKS
