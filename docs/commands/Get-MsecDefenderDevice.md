---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecDefenderDevice

## SYNOPSIS
Every device onboarded to Defender for Endpoint, with its exposure level and how many
vulnerabilities have been discovered on it.

## SYNTAX

```
Get-MsecDefenderDevice [[-HealthStatus] <String[]>] [[-ExposureLevel] <String[]>] [<CommonParameters>]
```

## DESCRIPTION
The Assets \> Devices view in the Defender portal, as flat rows: one per device, with
the exposure level and risk score the portal shows, plus the discovered-vulnerability
count broken down by severity.

TWO BULK CALLS, NOT ONE PER DEVICE.
The device list comes from /api/machines and the
counts from /api/vulnerabilities/machinesVulnerabilities - one row per device,
software and CVE,
which returns every (device, software, CVE) finding in the tenant in one paged
stream.
Asking /api/machines/{id}/vulnerabilities per device would be one request per
machine, which on a few thousand devices is a few thousand round trips and a
throttling wall.
Two streams cost the same whether you have ten devices or ten
thousand.

VULNERABILITIES ARE COUNTED AS DISTINCT CVEs, which is what the portal shows when you
open a device.
The export is one row per (software, CVE), so a single CVE affecting
three installed versions of the same product is three rows and one vulnerability.
Counting rows would inflate every device by a factor that varies with how much
software it has.
FindingCount carries the raw row count alongside, because the gap
between the two is the remediation workload - one CVE fixed in three places.

A FAILED VULNERABILITY READ GIVES $null COUNTS, NOT ZERO.
Defender Vulnerability
Management is a separate licence, and a tenant without it answers 403 on the
assessment export.
Reporting 0 there would read as "no device has any vulnerability",
which is the most dangerous wrong answer this command could give - so the device rows
still come back, every count is $null, and a warning says why.

A DEVICE WITH NO ROWS IN THE EXPORT REPORTS 0, AND THAT NEEDS READING WITH CARE.
The
export lists devices that have at least one finding; a device absent from it has none
recorded.
For an actively reporting device that means clean.
For one that stopped
talking to the service months ago it means nobody has looked - the same 0.
HealthStatus
and LastSeen are the columns that separate them, which is why they are on every row
rather than left to a second call.
Sort on them before reading a 0 as good news.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Get-MsecDefenderDevice | Sort-Object VulnerabilityCount -Descending | Select-Object -First 20
```

### EXAMPLE 2
```
# The list worth acting on: devices carrying critical CVEs, worst first.
Get-MsecDefenderDevice |
    Where-Object CriticalCount -gt 0 |
    Sort-Object CriticalCount, HighCount -Descending |
    Format-Table DeviceName, OsPlatform, ExposureLevel, CriticalCount, HighCount, LastSeen
```

### EXAMPLE 3
```
# A 0 that means "nobody has looked" rather than "clean".
Get-MsecDefenderDevice |
    Where-Object { $_.VulnerabilityCount -eq 0 -and $_.HealthStatus -ne 'Active' } |
    Sort-Object LastSeen
```

### EXAMPLE 4
```
# Remediation workload vs distinct CVEs - the gap is the same fix in several places.
Get-MsecDefenderDevice |
    Select-Object DeviceName, VulnerabilityCount, FindingCount |
    Sort-Object { $_.FindingCount - $_.VulnerabilityCount } -Descending
```

## PARAMETERS

### -HealthStatus
Only devices in these health states - 'Active', 'Inactive', 'ImpairedCommunication',
'NoSensorData', 'NoSensorDataImpairedCommunication', 'Unknown'.
Omit for all of them.
Filtering happens after the fetch, so it costs nothing extra and is exact.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ExposureLevel
Only devices at these exposure levels - 'None', 'Low', 'Medium', 'High'.
Omit for all.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per device, PSTypeName 'MsecDefenderDevice'. See .NOTES for the
### projection.
## NOTES
Needs Connect-Msec, and the WindowsDefenderATP application permissions
'Machine.Read.All' and 'Vulnerability.Read.All'.
New-MsecApp grants both; an app
created before they were added needs a re-run to pick them up.

Defender for Endpoint is COMMERCIAL-ONLY.
In a sovereign cloud with no securitycenter
endpoint - Azure China, for one - this throws with that explanation rather than
reaching for a dead host.

Projection (API field -\> output property):
  computerDnsName            -\> DeviceName
  id                         -\> Id
  exposureLevel              -\> ExposureLevel   ('None' / 'Low' / 'Medium' / 'High')
  riskScore                  -\> RiskScore       ('None' / 'Low' / 'Medium' / 'High')
  \<distinct cveId per device\> -\> VulnerabilityCount
  \<by severity, once per CVE\> -\> CriticalCount / HighCount / MediumCount / LowCount
  \<raw export rows\>           -\> FindingCount
  osPlatform / version / osBuild -\> OsPlatform / OsVersion / OsBuild
  healthStatus               -\> HealthStatus
  onboardingStatus           -\> OnboardingStatus
  lastSeen / firstSeen       -\> LastSeen / FirstSeen  (UTC)
  rbacGroupName              -\> RbacGroupName
  machineTags                -\> MachineTags
  aadDeviceId                -\> AadDeviceId
  lastIpAddress / lastExternalIpAddress -\> LastIpAddress / LastExternalIpAddress
  \<entire machine object\>    -\> Raw

Timestamps are normalised to UTC.
A plain \[datetime\] cast of the API's
'2026-09-01T08:00:00Z' yields Kind=Local, which then compares wrongly against a UTC
clock - an hour or two of skew, and a whole day either side of midnight on any
day-count derived from it.

## RELATED LINKS
