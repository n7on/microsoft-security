---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecIntuneScriptResult

## SYNOPSIS
Per-device results from every kind of Intune script - remediations, platform
scripts, macOS custom attributes and custom compliance scripts - as flat rows, one
per (script, device).

## SYNTAX

```
Get-MsecIntuneScriptResult [-Source] <String> [-Name <String[]>]
 [<CommonParameters>]
```

## DESCRIPTION
This is the data behind the Excel export on a script's "Device status" blade in the
Intune portal, in PowerShell objects instead of a download.

FIVE features, one row shape, because the question is the same one throughout: what
did my script return, on which device, and when?
These five are the complete set of
script collections Intune exposes under /deviceManagement - taken from Graph's own
$metadata rather than from the portal's navigation, which groups them differently.

  -Source Remediation       deviceHealthScripts
                            Windows.
The portal calls these Remediations, formerly
                            Proactive Remediations.
A detection script plus an
                            optional remediation script, so TWO outputs per device -
                            before and after the fix ran.
The only source with two.

  -Source PlatformScript    deviceManagementScripts     (Windows, PowerShell)
                            deviceShellScripts          (macOS, shell)
                            One blade in the portal, two collections in Graph, one
                            -Source here: the Platform column tells them apart, and
                            their run states are the same Graph type.

  -Source CustomAttribute   deviceCustomAttributeShellScripts
                            macOS.
A shell script whose stdout becomes the
                            attribute's value.

  -Source ComplianceScript  deviceComplianceScripts
                            Windows.
The discovery script behind a custom compliance
                            policy: its stdout is the JSON the policy's rules are
                            evaluated against, so a custom compliance policy is only
                            ever as trustworthy as this output.
Pairs with
                            Get-MsecIntuneCompliancePolicy.

-Source is mandatory and has no default.
The features overlap in shape but not in
meaning, and a command that silently swept all of them would make "no results"
ambiguous between "that platform has no scripts" and "I did not ask about it".
Pass
'All' explicitly to get every source in one stream - and note that 'All' means all
five, so it costs one request per script across the whole tenant.

WHAT 'Output' HOLDS, per source, because this is the column you came for:

  PlatformScript    resultMessage - whatever the script wrote to stdout.
  CustomAttribute   resultMessage - the same field, and here it IS the attribute
                    value, which is the reason the attribute exists.
  ComplianceScript  scriptOutput - the JSON the compliance rules parse.
  Remediation       postRemediationDetectionScriptOutput if the remediation ran,
                    otherwise preRemediationDetectionScriptOutput.
That is "the most
                    recent thing the detection script said", which is what the
                    portal's status column reflects.
Both are also kept verbatim in
                    PreRemediationOutput and PostRemediationOutput, so a row where
                    the remediation changed the answer is still legible.

NOT COVERED: userRunStates.
Every one of the five also reports per-USER results, and
a Windows platform script set to run in the user's context produces them.
This
command reads deviceRunStates only, so a user-context script's results are absent
rather than empty - worth knowing before reading a thin result as "it has not run".

A SCRIPT WITH NO RESULTS YIELDS NO ROWS, which is correct - nothing has run - but it
is reported when you asked for that script by name, because silence in response to a
specific request reads as "nothing found" rather than "nothing ran yet".

Device names come from $expand=managedDevice in the same request, so there is no
second lookup per device.
If Graph rejects the expand, the query is retried without
it and the device columns fall back to ids - one warning, and the script output
itself is unaffected.

Requires 'DeviceManagementScripts.Read.All' for the scripts and their run states, and
'DeviceManagementManagedDevices.Read.All' to name the devices.

The scripts scope is easy to get wrong: deviceHealthScripts and
deviceCustomAttributeShellScripts sit under /deviceManagement alongside the
configuration policies, but 'DeviceManagementConfiguration.Read.All' - which every
other Intune command in msec uses - does not cover them, and they answer 403 without
the scripts scope.
If you set the app up before this command existed, re-run
New-MsecApp to add it, then Disconnect-Msec / Connect-Msec: consent does not apply to
a token that was already issued.

BETA ENDPOINTS.
Neither feature has a /v1.0 surface, the same situation as
Settings Catalog policies in Get-MsecIntuneConfigurationProfile.

## EXAMPLES

### EXAMPLE 1
```
# Every Windows remediation result.
Get-MsecIntuneScriptResult -Source Remediation
```

### EXAMPLE 2
```
# Platform scripts across both operating systems - the Platform column separates
# the Windows PowerShell ones from the macOS shell ones.
Get-MsecIntuneScriptResult -Source PlatformScript |
    Format-Table ScriptName, Platform, DeviceName, State, Output
```

### EXAMPLE 3
```
# Custom compliance discovery output. A device can be reported compliant on the
# strength of whatever this returned, so it is worth reading directly.
Get-MsecIntuneScriptResult -Source ComplianceScript |
    Where-Object State -ne 'success'
```

### EXAMPLE 4
```
# Everything, one sheet. Source and Platform keep the five features distinguishable
# once they are in the same table.
Get-MsecIntuneScriptResult -Source All |
    Export-Excel ./intune-scripts.xlsx -AutoSize -TableName Results -WorksheetName Results
```

### EXAMPLE 5
```
# Scripts failing anywhere, across every feature at once - the shared row shape is
# what makes one Where-Object enough.
Get-MsecIntuneScriptResult -Source All |
    Where-Object State -in 'fail', 'scriptError' |
    Group-Object ScriptName, State -NoElement | Sort-Object Count -Descending
```

### EXAMPLE 6
```
# The macOS custom attribute values, which is what the attribute exists to collect.
Get-MsecIntuneScriptResult -Source CustomAttribute |
    Format-Table ScriptName, DeviceName, Output
```

### EXAMPLE 7
```
# One script, straight to a spreadsheet. msec returns rows; ImportExcel writes the
# workbook - the module deliberately does not depend on it.
Get-MsecIntuneScriptResult -Source Remediation -Name 'Check-BitLocker' |
    Export-Excel ./bitlocker.xlsx -AutoSize -TableName Results
```

### EXAMPLE 8
```
# Devices where the detection script found a problem and the remediation did not fix
# it. The pair of columns is the point: same script, two different answers.
Get-MsecIntuneScriptResult -Source Remediation |
    Where-Object { $_.RemediationState -eq 'remediationFailed' } |
    Format-Table ScriptName, DeviceName, PreRemediationOutput, Error
```

### EXAMPLE 9
```
# Group macOS devices by what the attribute actually returned - the fastest way to
# see the spread of a value across the estate.
Get-MsecIntuneScriptResult -Source CustomAttribute -Name 'FileVault-Status' |
    Group-Object Output | Sort-Object Count -Descending
```

### EXAMPLE 10
```
# Results that have gone stale: the script has not reported in a fortnight, so its
# State describes a device that may have changed since.
Get-MsecIntuneScriptResult -Source All |
    Where-Object { $_.LastStateUpdateDateTime -lt (Get-Date).AddDays(-14) }
```

## PARAMETERS

### -Source
Which script feature to read: 'Remediation', 'PlatformScript', 'CustomAttribute',
'ComplianceScript', or 'All' for every one of them.
Mandatory - see .DESCRIPTION for
why there is no default, and for what each one maps to in Graph.

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

### -Name
Limit to named scripts, by display name or id, case-insensitively.
An unrecognised
name is a terminating error listing what the tenant has, rather than an empty
result - a typo that returned nothing would read as "this script has never run".

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per (script, device), PSTypeName 'MsecIntuneScriptResult'. See .NOTES.
## NOTES
Default table view (registered in Msec.psm1): ScriptName, Source, DeviceName, State,
Output.
Output is last so a long script result truncates gracefully rather than
pushing other columns off the terminal.

Projection:
  script.id / displayName          -\> ScriptId, ScriptName
  (which endpoint it came from)    -\> Source    'Remediation' / 'CustomAttribute'
  (derived from Source)            -\> Platform  'Windows' / 'macOS'
  managedDevice.id                 -\> DeviceId
  managedDevice.deviceName         -\> DeviceName
  managedDevice.userPrincipalName  -\> UserPrincipalName
  detectionState | runState        -\> State
  remediationState                 -\> RemediationState  (Remediation only)
  (see .DESCRIPTION)               -\> Output
  pre/postRemediationDetectionScriptOutput
                                   -\> PreRemediationOutput, PostRemediationOutput
                                      (Remediation only)
  errorDescription | errorCode | scriptError | remediationScriptError |
  pre/post detection errors        -\> Error
  lastStateUpdateDateTime          -\> LastStateUpdateDateTime
  \<the run-state object verbatim\>  -\> Raw

Platform is derived from the collection, not read from Graph: each of the five is a
single-OS feature, so the endpoint the row came from determines it.
For
-Source PlatformScript it is the only thing separating the Windows PowerShell
scripts from the macOS shell ones, since both share a -Source value and a run-state
type.

State keeps Graph's own vocabulary ('success', 'fail', 'scriptError', 'pending',
'notApplicable', 'unknown') rather than being prettified.
The portal renders these
as phrases like "With issues"; the raw value is what you can filter on exactly, and
the mapping to a phrase is a presentation choice this command leaves to the caller.

## RELATED LINKS
