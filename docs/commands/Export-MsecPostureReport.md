---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Export-MsecPostureReport

## SYNOPSIS
Collects the tenant's security posture into an Excel workbook, appending one row
per measurement per run so the file builds a time series you can chart.

## SYNTAX

```
Export-MsecPostureReport [-Path] <String> [-Days <Int32>] [-Measurement <String[]>] [-Subscription <String[]>]
 [-TableStyle <String>] [-PassThru] [-WhatIf] [-Confirm]
 [<CommonParameters>]
```

## DESCRIPTION
Runs the read-only Get-Msec* commands, then appends a row to each measurement's
sheet.
Nothing is overwritten and nothing is deduped - every run adds rows, so the
workbook is a growing record of how the tenant's posture moved.

EVERY CHART IS ON THE DASHBOARD SHEET, first in the workbook, stacked one per row.
Each plots the RELATED series together - the comparable percentage scores on one
chart, the four incident severities on another, one line per Azure subscription on a
third.
Related numbers on a shared axis is the point; a chart per metric would tell
you far less.

THE DASHBOARD IS SET UP TO PRINT, one chart per page.
A4 landscape, fit to one page
wide and as many tall as it takes, with a page break above every chart and a print
area covering them - charts are drawings anchored to cells, so they print only if
those cells are inside it, and without that a PDF export comes out as blank pages.
Page settings that are a matter of taste (orientation, paper, margins) are written
only when the sheet is first created, so switching to A3 in Excel is not undone.

THE CHARTS ARE NOT REBUILT ON LATER RUNS.
Their series use ordinary cell ranges,
which are pinned to the row count they were written with, so the ranges are refreshed
in place as rows are appended - and nothing else about the chart is touched.
Its
title, position, size, colours and any series you added yourself all survive.

Series colours are NOT set: Excel's own theme palette applies, so the charts match
the workbook and follow it if you change the theme.

Sheets, each data sheet written as an Excel table:
  Dashboard              every chart, first in the workbook
  Scores                 Secure Score, exposure, device configuration score
  SecureScoreByCategory  one column per Secure Score category (Identity, Device, ...)
  AzureSecureScore       one column per Azure subscription
  MfaCoverage            MFA capability overall and for admins
  DeviceCompliance       Intune compliance mix, aggregated from Get-MsecIntuneDevice
  Incidents              Defender XDR volume, severity mix and time-to-resolve
  Email                  inbound volume, delivery actions, threat types
  ConditionalAccess      sign-in outcomes, risk, report-only would-blocks
  TenantSettings         security defaults, admin counts, licensing posture
  RunLog                 what ran, what failed and why

AZURE SECURE SCORE IS ONE COLUMN PER SUBSCRIPTION, not a tenant-wide average -
averaging a well-run production subscription with a neglected sandbox produces a
number that describes neither.
That does mean the columns follow your subscriptions:
a new subscription adds a column (and triggers the one-off reshape described under
Add-MsecExcelRow), and -Subscription is how you keep the sheet to the ones you
actually report on.

DEGRADES RATHER THAN FAILS.
Each measurement is collected independently.
A tenant
without Defender for Endpoint, or without Entra ID P1, answers 403 on some of these
and that is a licensing fact rather than a bug - so the failure is recorded in
RunLog and every other measurement still lands.
A missing measurement contributes
NO row, which leaves a visible gap in its chart rather than a fabricated zero.

SECURE SCORE IS TRIMMED TO ITS NEWEST SNAPSHOT.
Get-MsecSecureScore returns roughly
90 days of history on every call.
Appending all of it would add ~90 largely
duplicate rows per run, so only the most recent snapshot is taken and each run
contributes one row like every other measurement.
The consequence worth knowing:
the chart starts empty and fills in one point per run, rather than arriving with
three months of backfill.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Export-MsecPostureReport -Path ./posture.xlsx
```

### EXAMPLE 2
```
# Monthly, with a matching window, straight into a synced SharePoint library.
$lib = "$HOME/Library/CloudStorage/OneDrive-SharedLibraries-Contoso/Security - Documents"
Export-MsecPostureReport -Path "$lib/tenant-posture.xlsx" -Days 30
```

### EXAMPLE 3
```
# Only the production subscriptions on the Azure sheet, by name.
Export-MsecPostureReport -Path ./posture.xlsx -Subscription 'PROD', 'PROD-EU'
```

### EXAMPLE 4
```
# Just the scores, and see what came back.
Export-MsecPostureReport -Path ./posture.xlsx -Measurement Scores -PassThru
```

## PARAMETERS

### -Path
The .xlsx to append to.
Created on first run.

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

### -Days
Look-back window for the measurements that summarise a period - incidents, email
and Conditional Access sign-ins.
Default 30.
Recorded as WindowDays on those sheets,
because a row means nothing without knowing what window it covered.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: 30
Accept pipeline input: False
Accept wildcard characters: False
```

### -Measurement
Collect only these.
Default is all of them.
Useful for a quick top-up, or to skip
one that is slow or unlicensed on this tenant.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Subscription
Which Azure subscriptions the AzureSecureScore sheet covers.
Names or ids, or a mix -
names are resolved through the same lookup Search-MsecAzureResourceGraph uses, and a
name matching none or several throws with the candidates rather than guessing.
Omit
for every subscription the session can see.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -TableStyle
Excel table style for every data sheet.
One of Light1-21, Medium1-28 or Dark1-11 -
tab-completes.
Default Medium2.
It is applied on every run, not just when a sheet is
created, so changing it restyles the existing sheets next time rather than leaving
the old ones behind.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: Medium2
Accept pipeline input: False
Accept wildcard characters: False
```

### -PassThru
Emit the collected rows as objects as well as writing them.

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

### -WhatIf
Shows what would happen if the cmdlet runs.
The cmdlet is not run.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: wi

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Confirm
Prompts you for confirmation before running the cmdlet.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: cf

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### With -PassThru, one PSCustomObject per sheet written, each carrying Sheet, RowCount
### and the row itself. Always writes the workbook.
## NOTES
Needs the ImportExcel module: Install-Module ImportExcel -Scope CurrentUser.

RunUtc is written as an ISO-8601 STRING, not a DateTime.
Excel dates round-trip
through Import-Excel as OADate serial numbers, and re-exporting them turns a date
column into five-digit integers on the second run.
A string survives the
read-modify-write intact and charts fine as a category axis.

The workbook must not be open in Excel while this runs - the file is locked and the
write fails.

## RELATED LINKS
