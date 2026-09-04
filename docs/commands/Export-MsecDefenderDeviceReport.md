---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Export-MsecDefenderDeviceReport

## SYNOPSIS
Evidence of every device onboarded to Defender for Endpoint - one row per device, what
it is exposed to, and how many vulnerabilities have been discovered on it.

## SYNTAX

```
Export-MsecDefenderDeviceReport [-Path] <String> [-HealthStatus <String[]>] [-ExposureLevel <String[]>]
 [-TableStyle <String>] [-ChartWidth <Int32>] [-ChartHeight <Int32>] [-PassThru] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
The same evidence shape as the VM and disabled-account reports: one row per subject, a
worksheet named after the tenant, a shared Summary counting devices by category, and a
chart per tenant.
A snapshot, not a trend - nothing is appended, and a sheet written
twice is replaced.

Rows come from Get-MsecDefenderDevice, so everything it knows about the limits of the
answer applies here and is carried into the table rather than smoothed over.

THE CHART IS A DISTRIBUTION, NOT A TOTAL.
A tenant-wide "4,812 vulnerabilities" tells
you nothing you can act on; how those land across the estate does.
The category is a
vulnerability-count band, so the chart shows how many devices sit in each - and whether
the shape is a long tail of mostly-clean machines with a handful of disasters, or a
broad middle where everything is equally behind.
Those two need completely different
responses and produce the same total.

IT COUNTS TWICE PER BAND: devices, and how many of those carry at least one CRITICAL
vulnerability.
Critical count is not plotted as its own band because it does not share
an axis with the total - a device with 200 vulnerabilities might have three criticals,
so one series would flatten the other into the floor.
Asked as a subset of each band it
stays readable, and answers the question that actually decides the work order: are the
criticals concentrated in the worst machines, or spread through ones that otherwise
look fine?

'Not assessed' IS A BAND IN ITS OWN RIGHT, and it sorts to the TOP of the table.
It
means Get-MsecDefenderDevice could not read the vulnerability export at all - no
Defender Vulnerability Management licence, or a missing permission - so the count is
genuinely unknown rather than zero.
Folding those into 'None' would report an
unmeasured estate as a clean one, which is the only reading here that is certainly
wrong.

A DEVICE IN THE 'None' BAND NEEDS READING ALONGSIDE HealthStatus.
Zero findings on an
actively reporting device means clean; zero on one that stopped talking to the service
months ago means nobody has looked.
The table carries HealthStatus and LastSeen on
every row precisely so the difference is visible, and the rows are ordered so that a
stale device does not hide at the bottom.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Export-MsecDefenderDeviceReport -Path "./devices-$(Get-Date -Format 'yyyy-MM-dd').xlsx"
```

### EXAMPLE 2
```
# The rows a reviewer will ask about: critical vulnerabilities on live machines.
Export-MsecDefenderDeviceReport -Path ./evidence.xlsx -PassThru |
    Where-Object { $_.CriticalCount -gt 0 -and $_.HealthStatus -eq 'Active' } |
    Sort-Object CriticalCount -Descending |
    Format-Table DeviceName, OsPlatform, CriticalCount, VulnerabilityCount, LastSeen
```

## PARAMETERS

### -Path
The .xlsx to write.
Created if absent; an existing file is added to rather than
replaced, so several tenants can share one document.

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

### -HealthStatus
Only devices in these health states, passed through to Get-MsecDefenderDevice.
Omit
for all of them - which is usually right for evidence, since an inactive device is
part of the estate whether or not anyone is looking after it.

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

### -ExposureLevel
Only devices at these exposure levels, passed through to Get-MsecDefenderDevice.

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
Excel table style.
One of Light1-21, Medium1-28 or Dark1-11.
Default Medium2.

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
Chart width in pixels, default 600 - sized to paste into an A4 portrait Word page.

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
Emit the per-device rows as objects as well as writing them.

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
Replace an existing worksheet without asking.
A snapshot report REPLACES rather than
appends, so writing to a path that already holds this subject's evidence discards it -
which is worth a question when the path was a typo, and worth suppressing when the run
is scheduled.
Unattended runs need this: there is no one to answer the prompt.

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

### With -PassThru, one PSCustomObject per device, PSTypeName
### 'MsecDefenderDeviceEvidence'.
## NOTES
Needs Connect-Msec and the WindowsDefenderATP permissions 'Machine.Read.All' and
'Vulnerability.Read.All'.
Defender for Endpoint is commercial-only, so this is not
available in a sovereign cloud without a securitycenter endpoint.

The tenant's display name is read from /organization to name the worksheet.
If that
call fails the tenant id is used instead, which is ugly but unambiguous.

## RELATED LINKS
