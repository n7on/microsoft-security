---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecIntuneDevice

## SYNOPSIS
Lists every managed device known to Intune, projected to a flat PowerShell
shape suitable for filtering / grouping / exporting.

## SYNTAX

```
Get-MsecIntuneDevice [<CommonParameters>]
```

## DESCRIPTION
Calls Microsoft Graph /v1.0/deviceManagement/managedDevices with a $select
for the audit-relevant columns, paginates through @odata.nextLink, and
emits one PSCustomObject per device.

Aggregate stats are produced in PowerShell on the consumer side - msec only
returns the raw device list.
This matches Search-MsecAzureResourceGraph /
Get-MsecIntuneCompliancePolicy: the module returns rows, the consumer
decides what to do with them.
See the examples.

Requires the 'DeviceManagementManagedDevices.Read.All' application
permission.
Different from DeviceManagementConfiguration.Read.All (which
msec also has) - configuration is about POLICIES, this is about
DEVICES.
A clearer error is raised on the typical 403.

## EXAMPLES

### EXAMPLE 1
```
# Compliance counts.
Get-MsecIntuneDevice | Group-Object ComplianceState | Sort-Object Count -Descending
```

### EXAMPLE 2
```
# Devices not seen in 30 days - stale management. A device that stopped checking
# in keeps its last compliance verdict, so these read as compliant while being
# entirely unverified.
Get-MsecIntuneDevice |
    Where-Object { $_.LastSyncDateTime -lt (Get-Date).AddDays(-30) }
```

### EXAMPLE 3
```
# OS family breakdown.
Get-MsecIntuneDevice | Group-Object Os | Select-Object Name, Count
```

### EXAMPLE 4
```
# Snapshot-style headline percentages for an archive or a posture report.
$d = Get-MsecIntuneDevice
[pscustomobject]@{
    Total            = $d.Count
    Compliant        = ($d | Where-Object ComplianceState -eq 'compliant').Count
    Noncompliant     = ($d | Where-Object ComplianceState -eq 'noncompliant').Count
    InGracePeriod    = ($d | Where-Object ComplianceState -eq 'inGracePeriod').Count
    CompliantPercent = if ($d.Count) {
        [math]::Round(($d | Where-Object ComplianceState -eq 'compliant').Count / $d.Count * 100, 2)
    } else { 0 }
}
```

## PARAMETERS

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per device, with the columns documented in the .NOTES.
## NOTES
Projected columns (Graph field -\> output property):
  id                                       -\> Id
  deviceName                               -\> DeviceName
  userPrincipalName                        -\> UserPrincipalName
  userDisplayName                          -\> UserDisplayName
  operatingSystem                          -\> Os
  osVersion                                -\> OsVersion
  model                                    -\> Model
  manufacturer                             -\> Manufacturer
  complianceState                          -\> ComplianceState
  complianceGracePeriodExpirationDateTime  -\> ComplianceGraceUntil (null when no grace)
  managementState                          -\> ManagementState
  managementAgent                          -\> ManagementAgent
  managedDeviceOwnerType                   -\> Ownership ('company' / 'personal' / 'unknown')
  isEncrypted                              -\> IsEncrypted
  jailBroken                               -\> Jailbroken
  azureADRegistered                        -\> EntraRegistered
  enrolledDateTime                         -\> EnrolledDateTime
  lastSyncDateTime                         -\> LastSyncDateTime
  serialNumber                             -\> SerialNumber

## RELATED LINKS
