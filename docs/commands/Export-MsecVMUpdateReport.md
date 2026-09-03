---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Export-MsecVMUpdateReport

## SYNOPSIS
Evidence of when every VM in the CURRENT subscription was last patched - one row per
machine, on a worksheet named after the subscription.

## SYNTAX

```
Export-MsecVMUpdateReport [-Path] <String> [-StaleAfterDays <Int32>] [-ThrottleLimit <Int32>]
 [-TimeoutSeconds <Int32>] [-IncludeStopped] [-TableStyle <String>] [-ChartWidth <Int32>]
 [-ChartHeight <Int32>] [-PassThru] [-WhatIf] [-Confirm]
 [<CommonParameters>]
```

## DESCRIPTION
Runs the bundled update-status script inside each VM through Azure Run-Command, so the
answer is what the machine itself reports: Windows Update history on Windows, the
package manager's log on Linux.
One row per VM, showing what that VM said.

WHY IN-GUEST AND NOT RESOURCE GRAPH.
Kql/Graph/VM/LastUpdated.kql answers the same
question in one fast query, but sees ONLY what Azure Update Manager installed.
A VM
patching itself through Windows Automatic Updates or unattended-upgrades contributes
nothing there and reads as never updated - which is false, and on an evidence document
it is worse than useless.
This costs a Run-Command per VM and needs the machines
running, and buys an answer the guest itself vouches for.

A DOCUMENT PER RUN, NOT A GROWING ONE.
This is a snapshot: nothing is appended and no
history accumulates, so a sheet written twice is simply replaced.
Give each run its own
path - the date in the filename is what makes it evidence of a particular day.

SEVERAL SUBSCRIPTIONS, ONE DOCUMENT.
The scope is whatever the Az context is on, which
is also what Run-Command acts on, so the two cannot disagree.
Re-run against the same
path after Select-MsecAzureContext and the next subscription gets its own sheet in the
same file, with its own chart on the Dashboard.

EVERY VM APPEARS, INCLUDING THE ONES THAT DID NOT ANSWER.
A stopped machine, a wedged
agent or a timeout gets a row with Answered = False and the reason in Error, rather
than being left out.
Evidence that quietly omits the machines it could not reach is
not evidence - the gaps are exactly what a reviewer needs to see.

## EXAMPLES

### EXAMPLE 1
```
Select-MsecAzureContext -Subscription 'Contoso Production'
Export-MsecVMUpdateReport -Path "./vm-patching-$(Get-Date -Format 'yyyy-MM-dd').xlsx"
```

### EXAMPLE 2
```
# One evidence document covering the estate, a subscription per sheet.
$file = "./vm-patching-$(Get-Date -Format 'yyyy-MM-dd').xlsx"
foreach ($s in 'PROD', 'TEST', 'DEV') {
    Select-MsecAzureContext -Subscription $s
    Export-MsecVMUpdateReport -Path $file
}
```

### EXAMPLE 3
```
# The machines a reviewer will ask about, without opening the workbook.
Export-MsecVMUpdateReport -Path ./evidence.xlsx -PassThru |
    Where-Object Assessment -ne 'Up to date' |
    Format-Table VmName, Assessment, DaysSinceUpdate, SecurityPending
```

## PARAMETERS

### -Path
The .xlsx to write.
Created if absent; an existing file is added to rather than
replaced, so several subscriptions can share one document.
A sheet that already exists
for the same subscription is replaced, since this is a snapshot.

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

### -StaleAfterDays
Days since the last install past which a VM is marked Stale in the Assessment column.
Default 35 - a calendar month plus slack, so a monthly window that slips does not read
as a failure.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: 35
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
A VM that exceeds it gets a row saying so
rather than stalling the run.

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

### With -PassThru, one PSCustomObject per VM, PSTypeName 'MsecVMUpdateStatus'.
## NOTES
Needs an Az context - this is ARM, not Graph, so Connect-AzAccount rather than
Connect-Msec.
The caller needs Microsoft.Compute/virtualMachines/runCommand/action on
the VMs (Virtual Machine Contributor covers it).

SLOW BY NATURE.
One Run-Command per VM, a few seconds each at best; a hundred-VM
subscription at the default throttle is minutes, not seconds.

The chart plots DaysSinceUpdate per VM, worst first, which reads well up to a few dozen
machines.
On a larger fleet the table is the evidence and the chart is a shape - sort
or filter it in Excel if you need more from it.

## RELATED LINKS
