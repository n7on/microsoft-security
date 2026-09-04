function Get-MsecDefenderDevice {
    <#
    .SYNOPSIS
        Every device onboarded to Defender for Endpoint, with its exposure level and how many
        vulnerabilities have been discovered on it.

    .DESCRIPTION
        The Assets > Devices view in the Defender portal, as flat rows: one per device, with
        the exposure level and risk score the portal shows, plus the discovered-vulnerability
        count broken down by severity.

        TWO BULK CALLS, NOT ONE PER DEVICE. The device list comes from /api/machines and the
        counts from /api/vulnerabilities/machinesVulnerabilities - one row per device,
        software and CVE,
        which returns every (device, software, CVE) finding in the tenant in one paged
        stream. Asking /api/machines/{id}/vulnerabilities per device would be one request per
        machine, which on a few thousand devices is a few thousand round trips and a
        throttling wall. Two streams cost the same whether you have ten devices or ten
        thousand.

        VULNERABILITIES ARE COUNTED AS DISTINCT CVEs, which is what the portal shows when you
        open a device. The export is one row per (software, CVE), so a single CVE affecting
        three installed versions of the same product is three rows and one vulnerability.
        Counting rows would inflate every device by a factor that varies with how much
        software it has. FindingCount carries the raw row count alongside, because the gap
        between the two is the remediation workload - one CVE fixed in three places.

        A FAILED VULNERABILITY READ GIVES $null COUNTS, NOT ZERO. Defender Vulnerability
        Management is a separate licence, and a tenant without it answers 403 on the
        assessment export. Reporting 0 there would read as "no device has any vulnerability",
        which is the most dangerous wrong answer this command could give - so the device rows
        still come back, every count is $null, and a warning says why.

        A DEVICE WITH NO ROWS IN THE EXPORT REPORTS 0, AND THAT NEEDS READING WITH CARE. The
        export lists devices that have at least one finding; a device absent from it has none
        recorded. For an actively reporting device that means clean. For one that stopped
        talking to the service months ago it means nobody has looked - the same 0. HealthStatus
        and LastSeen are the columns that separate them, which is why they are on every row
        rather than left to a second call. Sort on them before reading a 0 as good news.

    .PARAMETER HealthStatus
        Only devices in these health states - 'Active', 'Inactive', 'ImpairedCommunication',
        'NoSensorData', 'NoSensorDataImpairedCommunication', 'Unknown'. Omit for all of them.
        Filtering happens after the fetch, so it costs nothing extra and is exact.

    .PARAMETER ExposureLevel
        Only devices at these exposure levels - 'None', 'Low', 'Medium', 'High'. Omit for all.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Get-MsecDefenderDevice | Sort-Object VulnerabilityCount -Descending | Select-Object -First 20

    .EXAMPLE
        # The list worth acting on: devices carrying critical CVEs, worst first.
        Get-MsecDefenderDevice |
            Where-Object CriticalCount -gt 0 |
            Sort-Object CriticalCount, HighCount -Descending |
            Format-Table DeviceName, OsPlatform, ExposureLevel, CriticalCount, HighCount, LastSeen

    .EXAMPLE
        # A 0 that means "nobody has looked" rather than "clean".
        Get-MsecDefenderDevice |
            Where-Object { $_.VulnerabilityCount -eq 0 -and $_.HealthStatus -ne 'Active' } |
            Sort-Object LastSeen

    .EXAMPLE
        # Remediation workload vs distinct CVEs - the gap is the same fix in several places.
        Get-MsecDefenderDevice |
            Select-Object DeviceName, VulnerabilityCount, FindingCount |
            Sort-Object { $_.FindingCount - $_.VulnerabilityCount } -Descending

    .OUTPUTS
        PSCustomObject per device, PSTypeName 'MsecDefenderDevice'. See .NOTES for the
        projection.

    .NOTES
        Needs Connect-Msec, and the WindowsDefenderATP application permissions
        'Machine.Read.All' and 'Vulnerability.Read.All'. New-MsecApp grants both; an app
        created before they were added needs a re-run to pick them up.

        Defender for Endpoint is COMMERCIAL-ONLY. In a sovereign cloud with no securitycenter
        endpoint - Azure China, for one - this throws with that explanation rather than
        reaching for a dead host.

        Projection (API field -> output property):
          computerDnsName            -> DeviceName
          id                         -> Id
          exposureLevel              -> ExposureLevel   ('None' / 'Low' / 'Medium' / 'High')
          riskScore                  -> RiskScore       ('None' / 'Low' / 'Medium' / 'High')
          <distinct cveId per device> -> VulnerabilityCount
          <by severity, once per CVE> -> CriticalCount / HighCount / MediumCount / LowCount
          <raw export rows>           -> FindingCount
          osPlatform / version / osBuild -> OsPlatform / OsVersion / OsBuild
          healthStatus               -> HealthStatus
          onboardingStatus           -> OnboardingStatus
          lastSeen / firstSeen       -> LastSeen / FirstSeen  (UTC)
          rbacGroupName              -> RbacGroupName
          machineTags                -> MachineTags
          aadDeviceId                -> AadDeviceId
          lastIpAddress / lastExternalIpAddress -> LastIpAddress / LastExternalIpAddress
          <entire machine object>    -> Raw

        Timestamps are normalised to UTC. A plain [datetime] cast of the API's
        '2026-09-01T08:00:00Z' yields Kind=Local, which then compares wrongly against a UTC
        clock - an hour or two of skew, and a whole day either side of midnight on any
        day-count derived from it.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateSet('Active', 'Inactive', 'ImpairedCommunication', 'NoSensorData',
                     'NoSensorDataImpairedCommunication', 'Unknown')]
        [string[]] $HealthStatus,

        [ValidateSet('None', 'Low', 'Medium', 'High')]
        [string[]] $ExposureLevel
    )

    Assert-MsecSession

    # See the note in .NOTES: the API's 'Z' timestamps cast to Kind=Local, which is the right
    # instant expressed in local wall-clock and therefore wrong against a UTC clock.
    # AssumeUniversal covers a response that omits the trailing Z.
    $toUtc = {
        param($value)
        if (-not $value) { return $null }
        if ($value -is [datetime]) { return $value.ToUniversalTime() }
        [datetime]::Parse([string] $value, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
            [System.Globalization.DateTimeStyles]::AssumeUniversal)
    }

    # ---- devices --------------------------------------------------------------------------

    try {
        $machines = @(Invoke-MsecDefenderRequest -Path '/api/machines' -All)
    }
    catch {
        $detail = $_.Exception.Message
        if ($detail -match '403|Forbidden') {
            throw "Forbidden when calling /api/machines. The msec app needs the WindowsDefenderATP 'Machine.Read.All' application permission (admin consent required). Re-run New-MsecApp to add and consent it. Original error: $detail"
        }
        throw
    }

    if (-not $machines.Count) {
        Write-Warning 'No devices are onboarded to Defender for Endpoint in this tenant.'
        return
    }

    # ---- vulnerability assessment -----------------------------------------------------------
    #
    # One row per (device, software, CVE) across the whole tenant. Collected into per-device
    # tallies as it streams, so the full export is never held in memory at once - on a large
    # estate it is hundreds of thousands of rows and only the counts are wanted.
    #
    # THE ID AND SEVERITY FIELDS ARE READ UNDER BOTH NAMES DEFENDER USES FOR THEM. The two
    # bulk vulnerability endpoints return the same facts under different keys:
    #
    #   /api/vulnerabilities/machinesVulnerabilities  -> machineId, severity
    #   /api/machines/SoftwareVulnerabilitiesByMachine -> deviceId,  vulnerabilitySeverityLevel
    #
    # Reading only one pair is how this command first shipped, and against a live tenant it
    # produced a full device list with every count reading 0 - the call succeeded, every row
    # streamed in, and every row was discarded for having no id under the name being looked
    # for. Accepting both costs a coalesce and removes a whole class of silent-zero bug.
    $byDevice = @{}
    $vulnerabilitiesRead = $true

    # Rows that arrived, and rows that could actually be attributed to a device. A large gap
    # between them means the response is not the shape this code expects, which is the one
    # failure that must never be reported as "no vulnerabilities" - see the check below.
    $rowsSeen = 0
    $rowsAttributed = 0

    try {
        Invoke-MsecDefenderRequest -Path '/api/vulnerabilities/machinesVulnerabilities' -All |
            ForEach-Object {
                $rowsSeen++

                $deviceId = [string] (@($_.machineId, $_.deviceId | Where-Object { $_ })[0])
                if (-not $deviceId) { return }
                $rowsAttributed++

                if (-not $byDevice.ContainsKey($deviceId)) {
                    $byDevice[$deviceId] = [pscustomobject]@{
                        Cves     = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                        Severity = @{}
                        Findings = 0
                    }
                }
                $entry = $byDevice[$deviceId]
                $entry.Findings++

                $cve = [string] $_.cveId
                if (-not $cve) { return }

                # Severity is counted ONCE PER CVE, not once per finding - the same CVE across
                # three installed versions is one vulnerability at one severity. Only the first
                # sighting of a CVE on a device counts, which is what makes the severity
                # columns add up to VulnerabilityCount.
                if ($entry.Cves.Add($cve)) {
                    $level = [string] (@($_.severity, $_.vulnerabilitySeverityLevel | Where-Object { $_ })[0])
                    if (-not $level) { $level = 'Unknown' }
                    if (-not $entry.Severity.ContainsKey($level)) { $entry.Severity[$level] = 0 }
                    $entry.Severity[$level]++
                }
            }
    }
    catch {
        # Defender Vulnerability Management is a separate licence. Losing the counts must not
        # lose the device inventory with them, and it must never look like a clean result.
        $vulnerabilitiesRead = $false
        $detail = $_.Exception.Message
        if ($detail -match '403|Forbidden') {
            Write-Warning "Forbidden reading the vulnerability assessment export. The msec app needs the WindowsDefenderATP 'Vulnerability.Read.All' permission, and the tenant needs Defender Vulnerability Management. Every vulnerability count is reported as null rather than 0. Original error: $detail"
        }
        else {
            Write-Warning "Could not read the vulnerability assessment export, so every vulnerability count is null rather than 0: $detail"
        }
    }

    # ROWS CAME BACK AND NONE OF THEM COULD BE ATTRIBUTED TO A DEVICE. That is a response in a
    # shape this code does not understand, not an estate with no vulnerabilities - and the two
    # are indistinguishable in the output unless it is said here. Reported as unread, so every
    # count is null rather than a tenant-wide row of zeroes that looks like good news.
    if ($vulnerabilitiesRead -and $rowsSeen -gt 0 -and $rowsAttributed -eq 0) {
        $vulnerabilitiesRead = $false
        Write-Warning "The vulnerability export returned $rowsSeen row(s), none carrying a device id under 'machineId' or 'deviceId'. The response is not in the expected shape, so every vulnerability count is reported as null rather than 0. Run this to see what the API actually returned: Invoke-MsecDefenderRequest -Path '/api/vulnerabilities/machinesVulnerabilities' | Select-Object -ExpandProperty value | Select-Object -First 1 | Format-List"
    }

    if ($vulnerabilitiesRead) {
        Write-Verbose "Vulnerability export: $rowsSeen finding(s) across $($byDevice.Count) device(s)."
    }

    # ---- project ----------------------------------------------------------------------------

    foreach ($m in $machines) {
        if ($HealthStatus  -and [string] $m.healthStatus  -notin $HealthStatus)  { continue }
        if ($ExposureLevel -and [string] $m.exposureLevel -notin $ExposureLevel) { continue }

        $entry = $byDevice[[string] $m.id]

        # $null when the export could not be read at all; 0 when it was read and this device
        # had no findings. Those are different answers and must not collapse into each other.
        $severity = { param($name) if (-not $vulnerabilitiesRead) { $null }
                      elseif ($entry -and $entry.Severity.ContainsKey($name)) { $entry.Severity[$name] }
                      else { 0 } }

        [PSCustomObject]@{
            PSTypeName             = 'MsecDefenderDevice'

            DeviceName             = $m.computerDnsName
            ExposureLevel          = $m.exposureLevel
            RiskScore              = $m.riskScore

            VulnerabilityCount     = if (-not $vulnerabilitiesRead) { $null } elseif ($entry) { $entry.Cves.Count } else { 0 }
            CriticalCount          = & $severity 'Critical'
            HighCount              = & $severity 'High'
            MediumCount            = & $severity 'Medium'
            LowCount               = & $severity 'Low'
            # Rows in the export: the same CVE in three installed products is three of these
            # and one vulnerability. The gap is the remediation workload.
            FindingCount           = if (-not $vulnerabilitiesRead) { $null } elseif ($entry) { $entry.Findings } else { 0 }

            OsPlatform             = $m.osPlatform
            OsVersion              = $m.version
            OsBuild                = $m.osBuild
            HealthStatus           = $m.healthStatus
            OnboardingStatus       = $m.onboardingStatus
            LastSeen               = & $toUtc $m.lastSeen
            FirstSeen              = & $toUtc $m.firstSeen
            RbacGroupName          = $m.rbacGroupName
            MachineTags            = @($m.machineTags | Where-Object { $_ })
            AadDeviceId            = $m.aadDeviceId
            LastIpAddress          = $m.lastIpAddress
            LastExternalIpAddress  = $m.lastExternalIpAddress
            Id                     = $m.id

            Raw                    = $m
        }
    }
}
