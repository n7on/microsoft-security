---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Export-MsecVMNtpReport

## SYNOPSIS
Evidence that every VM in the CURRENT subscription has its clock synchronised - one row
per machine, on a worksheet named after the subscription.

## SYNTAX

```
Export-MsecVMNtpReport [-Path] <String> [-ThrottleLimit <Int32>] [-TimeoutSeconds <Int32>] [-IncludeStopped]
 [-TableStyle <String>] [-ChartWidth <Int32>] [-ChartHeight <Int32>] [-PassThru] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Runs the bundled ntp-status script inside each VM through Azure Run-Command and records
what the machine itself reports: whether it is synchronised, which daemon is doing it,
and against which upstream source.

THE VERDICT IS THE SCRIPT'S, NOT THIS COMMAND'S.
Both the Windows and Linux versions
compute the same A.8.17 rule - synchronised AND naming a real upstream source - so the
Compliant column means the same thing on both platforms and the two can sit in one
table without a footnote.

BOTH HALVES OF THAT RULE MATTER, which is why 'No time source' is its own verdict
rather than being folded into 'Not synchronised'.
A Windows machine falling back to
Local CMOS Clock reports itself perfectly synchronised - to its own drifting hardware
clock.
It is not an unsynchronised machine that needs restarting; it is a machine
pointed at nothing, and the fix is different.

A DOCUMENT PER RUN, NOT A GROWING ONE.
This is a snapshot: nothing is appended, and a
sheet written twice is replaced.
Give each scan its own path - the date in the filename
is what makes it evidence of a particular day.

SEVERAL SUBSCRIPTIONS, ONE DOCUMENT.
The scope is whatever the Az context is on, which
is also what Run-Command acts on, so the two cannot disagree.
Re-run against the same
path after Select-MsecAzureContext and the next subscription gets its own sheet and its
own chart.

EVERY VM APPEARS, INCLUDING THE ONES THAT DID NOT ANSWER - a stopped machine, a wedged
agent or a timeout gets a row saying so.
Evidence that quietly omits what it could not
reach is not evidence.

## EXAMPLES

### EXAMPLE 1
```
Select-MsecAzureContext -Subscription 'Contoso Production'
Export-MsecVMNtpReport -Path "./vm-timesync-$(Get-Date -Format 'yyyy-MM-dd').xlsx"
```

### EXAMPLE 2
```
# One evidence document covering the estate, a subscription per sheet.
$file = "./vm-timesync-$(Get-Date -Format 'yyyy-MM-dd').xlsx"
foreach ($s in 'PROD', 'TEST', 'DEV') {
    Select-MsecAzureContext -Subscription $s
    Export-MsecVMNtpReport -Path $file
}
```

### EXAMPLE 3
```
# The machines a reviewer will ask about.
Export-MsecVMNtpReport -Path ./evidence.xlsx -PassThru |
    Where-Object Assessment -ne 'Compliant' |
    Format-Table VmName, Assessment, Synchronized, Source, Daemon
```

## PARAMETERS

### -Path
The .xlsx to write.
Created if absent; an existing file is added to rather than
replaced, so several subscriptions can share one document.

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

### -ThrottleLimit
VMs to query at once, passed to Invoke-MsecAzureVMScript.
Default 8.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: 8
Accept pipeline input: False
Accept wildcard characters: False
```

### -TimeoutSeconds
Per-VM budget, passed through.
Default 300.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: 300
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeStopped
Attempt stopped VMs too.
Off by default because Run-Command cannot reach them - they
still appear, with Assessment = 'Not running'.

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
Emit the per-VM rows as objects as well as writing them.

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

### With -PassThru, one PSCustomObject per VM, PSTypeName 'MsecVMEvidence'.
## NOTES
Needs an Az context - this is ARM, not Graph, so Connect-AzAccount rather than
Connect-Msec.
The caller needs Microsoft.Compute/virtualMachines/runCommand/action on
the VMs (Virtual Machine Contributor covers it).

SLOW BY NATURE.
One Run-Command per VM, a few seconds each at best.

VmClockUtc is the guest's own clock at the moment the script ran.
It is carried as
evidence, not compared against the collection time: Run-Command latency is seconds and
varies, so a small difference means nothing.
A difference of minutes or hours is worth
chasing, and is visible by eye.

## RELATED LINKS
