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
 [-PolicyInitiative <String[]>] [-Target <Hashtable>] [-TableStyle <String>] [-ChartWidth <Int32>]
 [-ChartHeight <Int32>] [-ResetDashboard] [-PassThru] [-WhatIf] [-Confirm]
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

CHARTS ARE SIZED FOR PASTING INTO WORD, not for filling Excel's page.
Word pastes a
copied chart at its true pixel size with no scaling, so the document's printable
width is the real constraint - about 602 px on A4 portrait at standard margins, 930
on landscape.
A chart sized to fill Excel's own landscape page is wider than either
and has to be dragged smaller on every paste, so the default (-ChartWidth 600) fits
the tighter case and therefore any document.
Excel printing does not lose out: the
print area follows the chart width, so fit-to-one-page-wide scales the narrow band
back up to fill the sheet.

THE CHARTS ARE NOT REBUILT ON LATER RUNS.
Their series use ordinary cell ranges,
which are pinned to the row count they were written with, so the ranges are refreshed
in place as rows are appended.
Title, size, colours and any series you added yourself
all survive.

POSITION IS THE EXCEPTION - it belongs to the layout and is reasserted every run,
because it is what the page breaks are aligned to.
It also has to be: charts are
packed densely, so a chart that stayed where it was would have its neighbour drawn
straight on top of it.

ONLY MEASUREMENTS THAT HAVE ACTUALLY PRODUCED A ROW GET A CHART, and they are packed
one after another with no gaps.
Running a single measurement gives a dashboard with a
single chart at the top, not one chart several blank pages down.
The consequence worth
knowing: the first time a new measurement lands, every chart below it moves down one
page.
That happens once - a data sheet never loses its rows, so the layout only ever
settles further - and the alternative was a permanent blank page for every measurement
this tenant does not collect.

Series colours are NOT set: Excel's own theme palette applies, so the charts match
the workbook and follow it if you change the theme.

Sheets, each data sheet written as an Excel table:
  Dashboard              every chart, first in the workbook
  Scores                 Secure Score, exposure, device configuration score
  SecureScoreByCategory  one column per Secure Score category (Identity, Device, ...)
  AzureSecureScore       one column per Azure subscription
  PolicyCompliance       one column per Azure Policy initiative
  PrivilegedAccess       standing vs PIM-eligible admins, and who else holds a role
  MfaCoverage            MFA capability overall and for admins
  DeviceCompliance       Intune compliance mix, aggregated from Get-MsecIntuneDevice
  DevicePlatform         one column per OS family (Windows, macOS, iOS, Android, ...)
  DeviceOsVersion        one column per OS release (Windows 11, iOS 17, ...)
  Incidents              Defender XDR volume, severity mix and time-to-resolve
  Email                  inbound volume, delivery actions, threat types
  ConditionalAccess      sign-in outcomes, risk, report-only would-blocks
  TenantSettings         security defaults, admin counts, licensing posture
  RunLog                 what ran, what failed and why

PRIVILEGED ACCESS IS COUNTED IN PEOPLE, NOT ASSIGNMENTS.
Someone holding Global
Administrator, Security Administrator and Exchange Administrator is ONE administrator;
counting rows would say three, and would move whenever the same faces swapped roles.
Holders are counted, so a role reaching someone through a role-assignable group counts
the person, and StandingPrivileged against EligiblePrivileged is the PIM adoption story
over time.

GlobalAdminHolders there can exceed GlobalAdministratorCount on TenantSettings.
They
are not in conflict: this one counts effective holders including group-inherited and
PIM-eligible ones, the other counts the assignment side.

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

### -PolicyInitiative
Which Azure Policy initiatives the PolicyCompliance sheet covers, as wildcards matched
against the initiative's display name.
Omit for every initiative grading at least one
resource - which on a large estate is more lines than one chart can carry, hence the
warning past eight.

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

### -Target
Sheet name mapped to a target value, e.g.
@{ MfaCoverage = 95; PolicyCompliance = 80 }.
Each becomes a Target column on that sheet holding the same number on every row, which
Excel plots as a flat line across the chart - so the goal sits alongside the trend
instead of living in someone's head.

Only the sheets you name get one, so charts you have no target for are untouched.
The
value is in the chart's own units: a percentage on the percentage charts, a count on
Incidents or TenantSettings (@{ Incidents = 0 } draws a zero line under the severity
counts).
Raising a target later shows as a step in the line rather than rewriting
history, because it is stored per row.

```yaml
Type: Hashtable
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: @{}
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

### -ChartWidth
Chart width in pixels, default 600.
Sized so a chart pasted into Word fits an A4
PORTRAIT page at standard margins - Word pastes at true pixel size with no scaling,
so anything wider has to be resized by hand every time.
About 900 suits landscape
documents.
Printing from Excel is unaffected either way: the print area follows the
chart width and fit-to-one-page-wide scales it up to fill the sheet.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: 600
Accept pipeline input: False
Accept wildcard characters: False
```

### -ChartHeight
Chart height in pixels, default 370.
Also sets the row band each chart occupies, and
therefore where the page breaks fall.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: 370
Accept pipeline input: False
Accept wildcard characters: False
```

### -ResetDashboard
Rebuild the Dashboard sheet from scratch.
Charts are created once and afterwards only
range-refreshed, so a change to -ChartWidth or -ChartHeight does not reach charts that
already exist - this is how to apply one.
It discards manual edits on the Dashboard;
the data sheets and their accumulated history are untouched.

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
