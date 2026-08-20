---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Invoke-MsecAzureVMScript

## SYNOPSIS
Runs a bundled script on one or more Azure VMs.
-Os selects the script flavour
(Linux .sh under Scripts/VM/Linux/ or Windows .ps1 under Scripts/VM/Windows/).

## SYNTAX

```
Invoke-MsecAzureVMScript [-Os] <String> [-ScriptName] <String> [-Name] <String> [-ResourceGroupName] <String>
 [[-Location] <String>] [[-SubscriptionId] <String>] [[-ThrottleLimit] <Int32>] [[-TimeoutSeconds] <Int32>] [<CommonParameters>]
```

## DESCRIPTION
Pipeline-friendly.
Consumes Name + ResourceGroupName (and optionally Os, Location)
from any VM source - Search-MsecAzureResourceGraph, Get-AzVM, hand-built objects.

-Os can be set on the command line (all piped rows use that OS) OR bound per-row
from the pipeline's Os property.
The latter is what Search-MsecAzureResourceGraph
produces, so the simple form Just Works:

    Search-MsecAzureResourceGraph -ResourceType VM | Where-Object Running |
        Invoke-MsecAzureVMScript -ScriptName ntp-status -ThrottleLimit 8

-ScriptName tab-completes from Scripts/\<Os\>/ when -Os is on the command line,
or falls back to scripts that exist for BOTH OSes when -Os is being supplied
via the pipeline.

Linux scripts run via CommandId='RunShellScript' (as root); Windows scripts via
CommandId='RunPowerShellScript' (as SYSTEM).
RBAC: caller needs
Microsoft.Compute/virtualMachines/runCommand/action on each VM (Virtual Machine
Contributor covers it).

-ThrottleLimit \> 1 fans the run-commands out across the pipeline in parallel via
ForEach-Object -Parallel, using the caller's Az context.
Order of output is the
order results complete in, not input order - sort downstream if you care.

## EXAMPLES

### EXAMPLE 1
```
# Mixed Linux + Windows, single call, parallel:
Search-MsecAzureResourceGraph -ResourceType VM | Where-Object Running |
    Invoke-MsecAzureVMScript -ScriptName ntp-status -ThrottleLimit 8
```

### EXAMPLE 2
```
# Explicit -Os (overrides any per-row Os; safe when you've filtered already):
Search-MsecAzureResourceGraph -ResourceType VM | Where-Object Os -eq 'Linux' |
    Invoke-MsecAzureVMScript -Os Linux -ScriptName ntp-status -ThrottleLimit 8
```

## PARAMETERS

### -Os
'Linux' or 'Windows'.
Either supply on the command line, or pipe rows that have
an Os property and the value is taken per-row.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: True (ByPropertyName)
Accept wildcard characters: False
```

### -ScriptName
Base name (no extension) of the script under Msec/Scripts/\<Os\>/.
Must exist for
every OS that comes down the pipeline - missing scripts produce a clear
"\<Os\> script not found" error at first encounter.

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

### -Name
VM name.
Bound from the pipeline.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 3
Default value: None
Accept pipeline input: True (ByPropertyName)
Accept wildcard characters: False
```

### -ResourceGroupName
VM's resource group.
Bound from the pipeline.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 4
Default value: None
Accept pipeline input: True (ByPropertyName)
Accept wildcard characters: False
```

### -Location
Optional pass-through column.
If the piped source has Location, it appears in
each output row.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: None
Accept pipeline input: True (ByPropertyName)
Accept wildcard characters: False
```

### -SubscriptionId
Optional.
When the piped row carries SubscriptionId (Search-MsecAzureResourceGraph
projects it), it GUARDS against acting on the wrong subscription: a VM whose
SubscriptionId differs from the active Az context is failed gracefully instead of
dispatched.
Scope the query with Search-MsecAzureResourceGraph -SubscriptionId, or
switch context, so targets match the active sub.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 6
Default value: None
Accept pipeline input: True (ByPropertyName)
Accept wildcard characters: False
```

### -ThrottleLimit
Maximum number of VMs to run the script against concurrently.
Default 1
(sequential, streams results as each VM finishes).
Values \>1 buffer pipeline
input and dispatch via ForEach-Object -Parallel.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 7
Default value: 1
Accept pipeline input: False
Accept wildcard characters: False
```

### -TimeoutSeconds
Max seconds to wait for any single VM's Run-Command to complete.
Default
300 (5 min) - generous enough for cold/slow VMs while still bounding the
worst case far below Az's own 45-minute internal timeout.
Each call runs
as the cmdlet's own background job (-AsJob) with Wait-Job -Timeout; on
timeout the job is abandoned rather than stopped synchronously (stopping can
block on a wedged VM whose call ignores cancellation), so a stuck agent
yields one Failed/Timeout row and the batch keeps moving instead of hanging
on it.
Raise to 600 for very slow fleets, lower (e.g.
120) for tight
aggressive runs.
Set to 0 to disable the timeout entirely (useful for tests
that mock Invoke-AzVMRunCommand - Pester mocks don't propagate into
background-job runspaces).

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 8
Default value: 300
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per VM: VmName, ResourceGroupName, Location, Os, ScriptName,
### Status, Output, Error, DurationSeconds.
## NOTES

## RELATED LINKS
