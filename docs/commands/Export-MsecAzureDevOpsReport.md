---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Export-MsecAzureDevOpsReport

## SYNOPSIS
Collects an Azure DevOps organization's security posture into one Excel workbook - a
sheet of rows per area, a Summary counting each area by category, and a chart per
area on a Dashboard built to print one chart per page.

## SYNTAX

```
Export-MsecAzureDevOpsReport [-Path] <String> [-Organization] <String> [-Area <String[]>]
 [-AlertState <String>] [-IncludeAgentPoolExposure] [-TableStyle <String>] [-ChartWidth <Int32>]
 [-ChartHeight <Int32>] [-PassThru] [-Force] [-WhatIf] [-Confirm]
 [<CommonParameters>]
```

## DESCRIPTION
A SNAPSHOT, NOT A TREND.
Every sheet is replaced on each run; nothing is appended and
nothing accumulates.
This is the evidence half of the module - "here is the state of
the organization on the day it was collected" - as opposed to Export-MsecPostureReport,
which appends one row per run to build a time series.

It runs the Get-MsecAzureDevOps* commands and writes what each returned, unmodified.
Everything those commands know about the limits of their answers travels with the
rows, so a column that is $null on a sheet here is $null for the reason that command
documents, not because this one dropped it.

DEGRADES RATHER THAN FAILS.
Each area is collected independently and a failure is
recorded on RunLog with the message that caused it, so one area that needs a permission
this identity does not hold costs that area and nothing else.

A FAILED AREA GETS NO CHART, deliberately.
A chart of zeros and no chart at all say
different things - "measured, found none" against "could not measure" - and a report
that drew zeros for a 403 would turn a permission gap into a clean bill of health.
An area that WAS collected and found nothing does get its chart, with zeros in it.

CATEGORIES ARE FIXED AND ALWAYS PRESENT, at zero if nothing is in them, so two runs'
charts line up.
A value no category was written for is added as its own bar rather
than folded into 'Other' - Azure DevOps adds severities, auth schemes and pool types,
and the one outcome worth avoiding is a bar quietly absorbing something new.

TWO CHARTS ARE NOT PARTITIONS AND MUST NOT BE SUMMED.
On 'Pipeline settings' and
'Organization policies' each bar is an independent measurement - how many projects
have that one protection off, and whether that one policy is on - so a project appears
under every risk it carries and the bars overlap by design.
Every other chart divides
its subject into mutually exclusive categories, where the bars do add up to the total.
The two are drawn as horizontal bars, partly because their labels are sentences and
partly so they read differently from the charts that do partition.

Sheets:
  Dashboard          every chart, first in the workbook, one per printed page
  Summary            Area, Category, Count - what the charts read
  Repositories       branch protection on each default branch
  Alerts             Advanced Security findings (active by default), charted by type
                     as well as severity - see below
  ServiceConnections auth scheme and which pipelines may use each connection
  VariableGroups     how many secrets each holds and who may use it
  SecureFiles        certificates and keys in the pipeline library
  Environments       deployment targets and the checks guarding them
  AgentPools         hosted and self-hosted pools and their agents
  Extensions         marketplace extensions and the access each holds
  PipelineSettings   per-project pipeline security settings
  OrgPolicies        organization policies
  Users              organization members and the groups they are in
  RunLog             what ran, what failed, and why

A ZERO BAR ON THE ALERT TYPE CHART IS A SCANNER THAT IS OFF, not a clean codebase.
Azure DevOps rates every secret alert critical, so an organization running secret
scanning alone fills the critical bar and leaves the other four severities empty -
which is why alerts are charted by type as well.
Which scanners are enabled per
repository is on the Repositories sheet.

WHAT IT DOES NOT COLLECT: the contents of secure files or the values of secret
variables.
Neither command reads them and this one does not either - an evidence
document that gathered private keys into a spreadsheet would be the largest new risk
in the room.

Agent pool exposure (which projects can queue work on a pool) is one call per project
and is off unless -IncludeAgentPoolExposure is given; without it those columns are
$null, meaning not collected rather than none.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Export-MsecAzureDevOpsReport -Path ./ado-2026-09.xlsx -Organization contoso
```

### EXAMPLE 2
```
# Skip the two slow areas for a quick look at the pipeline library.
Export-MsecAzureDevOpsReport -Path ./ado.xlsx -Organization contoso `
    -Area VariableGroups, SecureFiles, ServiceConnections, Environments
```

### EXAMPLE 3
```
# Scheduled, with no prompt, into a synced SharePoint library.
$lib = "$HOME/Library/CloudStorage/OneDrive-SharedLibraries-Contoso/Security - Documents"
Export-MsecAzureDevOpsReport -Path "$lib/ado-posture.xlsx" -Organization contoso -Force
```

## PARAMETERS

### -Path
The .xlsx to write.
Created if absent.
One organization per workbook - the sheets are
named for areas, not organizations, so a second organization written to the same path
replaces the first.
Give each its own file.

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

### -Organization
The Azure DevOps organization name, as in dev.azure.com/\<organization\>.

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

### -Area
Collect only these areas.
Default is all of them.
Useful for a quick top-up, or to
skip Alerts and Repositories, which walk every repository and are much the slowest.

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

### -AlertState
Which Advanced Security alerts to collect: 'active' (default), 'fixed', 'dismissed'
or 'all'.
The default is the working list - what is outstanding now.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: Active
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeAgentPoolExposure
Also collect which projects can queue work on each pool.
One extra call per project.

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

### -TableStyle
Excel table style for every sheet.
One of Light1-21, Medium1-28 or Dark1-11.
Default
Medium2.

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
Chart width in pixels, default 600 - sized so a chart pasted into Word fits an A4
portrait page at standard margins, which is the tighter of the two orientations.

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
Also sets where the page breaks fall.

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

### -PassThru
Emit one object per area describing what was collected and where it was written.

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

### -Force
Replace existing sheets without asking.
Needed for scheduled runs, which have nobody
to answer the prompt.

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

### With -PassThru, one PSCustomObject per area: Area, Sheet, Status, RowCount and the
### rows themselves. Always writes the workbook.
## NOTES
Needs Connect-Msec, plus whatever each area needs in Azure DevOps itself - see the
permission table in README.md.
Azure DevOps permissions are not Entra permissions, and
an identity that can read one area may be refused another; that is what RunLog is for.

Needs the ImportExcel module: Install-Module ImportExcel -Scope CurrentUser.

The workbook must not be open in Excel while this runs - the file is locked and the
write fails.

## RELATED LINKS
