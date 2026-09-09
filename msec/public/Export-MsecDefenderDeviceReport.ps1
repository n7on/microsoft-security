function Export-MsecDefenderDeviceReport {
    <#
    .SYNOPSIS
        Evidence of every device onboarded to Defender for Endpoint - one row per device, what
        it is exposed to, and how many vulnerabilities have been discovered on it.

    .DESCRIPTION
        The same evidence shape as the VM and disabled-account reports: one row per subject, a
        worksheet named after the tenant, a shared Summary counting devices by category, and a
        chart per tenant. A snapshot, not a trend - nothing is appended, and a sheet written
        twice is replaced.

        Rows come from Get-MsecDefenderDevice, so everything it knows about the limits of the
        answer applies here and is carried into the table rather than smoothed over.

        THE CHART IS A DISTRIBUTION, NOT A TOTAL. A tenant-wide "4,812 vulnerabilities" tells
        you nothing you can act on; how those land across the estate does. The category is a
        vulnerability-count band, so the chart shows how many devices sit in each - and whether
        the shape is a long tail of mostly-clean machines with a handful of disasters, or a
        broad middle where everything is equally behind. Those two need completely different
        responses and produce the same total.

        IT COUNTS TWICE PER BAND: devices, and how many of those carry at least one CRITICAL
        vulnerability. Critical count is not plotted as its own band because it does not share
        an axis with the total - a device with 200 vulnerabilities might have three criticals,
        so one series would flatten the other into the floor. Asked as a subset of each band it
        stays readable, and answers the question that actually decides the work order: are the
        criticals concentrated in the worst machines, or spread through ones that otherwise
        look fine?

        'Not assessed' IS A BAND IN ITS OWN RIGHT, and it sorts to the TOP of the table. It
        means Get-MsecDefenderDevice could not read the vulnerability export at all - no
        Defender Vulnerability Management licence, or a missing permission - so the count is
        genuinely unknown rather than zero. Folding those into 'None' would report an
        unmeasured estate as a clean one, which is the only reading here that is certainly
        wrong.

        A DEVICE IN THE 'None' BAND NEEDS READING ALONGSIDE HealthStatus. Zero findings on an
        actively reporting device means clean; zero on one that stopped talking to the service
        months ago means nobody has looked. The table carries HealthStatus and LastSeen on
        every row precisely so the difference is visible, and the rows are ordered so that a
        stale device does not hide at the bottom.

    .PARAMETER Path
        The .xlsx to write. Created if absent; an existing file is added to rather than
        replaced, so several tenants can share one document.

    .PARAMETER HealthStatus
        Only devices in these health states, passed through to Get-MsecDefenderDevice. Omit
        for all of them - which is usually right for evidence, since an inactive device is
        part of the estate whether or not anyone is looking after it.

    .PARAMETER ExposureLevel
        Only devices at these exposure levels, passed through to Get-MsecDefenderDevice.

    .PARAMETER TableStyle
        Excel table style. One of Light1-21, Medium1-28 or Dark1-11. Default Medium2.

    .PARAMETER ChartWidth
        Chart width in pixels, default 600 - sized to paste into an A4 portrait Word page.

    .PARAMETER ChartHeight
        Chart height in pixels, default 370.

    .PARAMETER Force
        Replace an existing worksheet without asking. A snapshot report REPLACES rather than
        appends, so writing to a path that already holds this subject's evidence discards it -
        which is worth a question when the path was a typo, and worth suppressing when the run
        is scheduled. Unattended runs need this: there is no one to answer the prompt.
    .PARAMETER PassThru
        Emit the per-device rows as objects as well as writing them.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Export-MsecDefenderDeviceReport -Path "./devices-$(Get-Date -Format 'yyyy-MM-dd').xlsx"

    .EXAMPLE
        # The rows a reviewer will ask about: critical vulnerabilities on live machines.
        Export-MsecDefenderDeviceReport -Path ./evidence.xlsx -PassThru |
            Where-Object { $_.CriticalCount -gt 0 -and $_.HealthStatus -eq 'Active' } |
            Sort-Object CriticalCount -Descending |
            Format-Table DeviceName, OsPlatform, CriticalCount, VulnerabilityCount, LastSeen

    .OUTPUTS
        With -PassThru, one PSCustomObject per device, PSTypeName
        'MsecDefenderDeviceEvidence'.

    .NOTES
        Needs Connect-Msec and the WindowsDefenderATP permissions 'Machine.Read.All' and
        'Vulnerability.Read.All'. Defender for Endpoint is commercial-only, so this is not
        available in a sovereign cloud without a securitycenter endpoint.

        The tenant's display name is read from /organization to name the worksheet. If that
        call fails the tenant id is used instead, which is ugly but unambiguous.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Path,

        [ValidateSet('Active', 'Inactive', 'ImpairedCommunication', 'NoSensorData',
                     'NoSensorDataImpairedCommunication', 'Unknown')]
        [string[]] $HealthStatus,

        [ValidateSet('None', 'Low', 'Medium', 'High')]
        [string[]] $ExposureLevel,

        [string] $TableStyle = 'Medium2',

        [ValidateRange(200, 2000)]
        [int] $ChartWidth = 600,

        [ValidateRange(150, 1200)]
        [int] $ChartHeight = 370,

        [switch] $PassThru,

        [switch] $Force
    )

    Assert-MsecSession

    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        throw 'ImportExcel is required for Export-MsecDefenderDeviceReport. Install with: Install-Module ImportExcel -Scope CurrentUser'
    }
    Import-Module ImportExcel -ErrorAction Stop

    if (-not ($TableStyle -as [OfficeOpenXml.Table.TableStyles])) {
        throw "'$TableStyle' is not an Excel table style. Use one of Light1-21, Medium1-28 or Dark1-11 (for example Medium2, the default)."
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Collect Defender devices and write the evidence sheet')) {
        return
    }

    $tenantId = $script:MsecSession.TenantId
    $collectedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')

    # A GUID makes a legal worksheet name and a useless one, so the display name is preferred.
    # Best effort: a failure here costs readability, not the report.
    $tenantName = $tenantId
    try {
        $organisation = Invoke-MsecGraphRequest -Path '/v1.0/organization?$select=id,displayName'
        $name = @($organisation.value)[0].displayName
        if ($name) { $tenantName = $name }
    }
    catch {
        Write-Verbose "Could not read the tenant display name, using the id: $($_.Exception.Message)"
    }

    # BEFORE ANYTHING IS COLLECTED, so declining costs nothing rather than throwing away a
    # full directory enumeration.
    if (-not (Confirm-MsecEvidenceOverwrite -Path $Path -OwnerName $tenantName -OwnerId $tenantId `
                  -OwnerColumn 'TenantId' -Cmdlet $PSCmdlet -Force:$Force)) {
        return
    }

    # ---- collect ------------------------------------------------------------------------------

    $forward = @{}
    if ($HealthStatus)  { $forward['HealthStatus']  = $HealthStatus }
    if ($ExposureLevel) { $forward['ExposureLevel'] = $ExposureLevel }

    $devices = @(Get-MsecDefenderDevice @forward)

    if (-not $devices.Count) {
        Write-Warning "No Defender devices found in '$tenantName'. Nothing to report."
        return
    }

    # Left to right the chart reads as a distribution curve, so the bands run from clean to
    # worst with the unmeasured one last - it is not a point on that curve. The TABLE is
    # ordered the other way round; see the sort below.
    $bandOrder = @('None', '1 to 10', '11 to 25', '26 to 50', '51 to 100', 'Over 100', 'Not assessed')

    $rows = foreach ($device in $devices) {
        $count = $device.VulnerabilityCount

        # $null means the vulnerability export could not be read - genuinely unknown, and NOT
        # the same as zero. Get-MsecDefenderDevice is careful to keep those apart and this
        # would be the place it got thrown away.
        $band =
            if ($null -eq $count)  { 'Not assessed' }
            elseif ($count -eq 0)  { 'None' }
            elseif ($count -le 10) { '1 to 10' }
            elseif ($count -le 25) { '11 to 25' }
            elseif ($count -le 50) { '26 to 50' }
            elseif ($count -le 100) { '51 to 100' }
            else                   { 'Over 100' }

        [pscustomobject]@{
            PSTypeName            = 'MsecDefenderDeviceEvidence'
            DeviceName            = $device.DeviceName
            VulnerabilityBand     = $band
            VulnerabilityCount    = $count
            CriticalCount         = $device.CriticalCount
            HighCount             = $device.HighCount
            MediumCount           = $device.MediumCount
            LowCount              = $device.LowCount
            # Rows in the assessment export: the same CVE in three installed products is three
            # of these and one vulnerability. The gap is the remediation workload.
            FindingCount          = $device.FindingCount
            ExposureLevel         = $device.ExposureLevel
            RiskScore             = $device.RiskScore
            OsPlatform            = $device.OsPlatform
            OsVersion             = $device.OsVersion
            OsBuild               = $device.OsBuild
            # Carried next to the counts on purpose: a 0 on an Inactive device means nobody
            # has looked, not that it is clean.
            HealthStatus          = $device.HealthStatus
            LastSeen              = $device.LastSeen
            FirstSeen             = $device.FirstSeen
            OnboardingStatus      = $device.OnboardingStatus
            RbacGroupName         = $device.RbacGroupName
            MachineTags           = $device.MachineTags
            LastIpAddress         = $device.LastIpAddress
            LastExternalIpAddress = $device.LastExternalIpAddress
            Id                    = $device.Id
            TenantName            = $tenantName
            TenantId              = $tenantId
            CollectedUtc          = $collectedUtc
        }
    }
    $rows = @($rows)

    # Unmeasured first, then worst to best, then criticals ahead of the rest inside a band: a
    # reviewer scanning the table should meet what nobody has assessed, then what is on fire.
    $rows = @($rows | Sort-Object `
        @{ Expression = { [array]::IndexOf($bandOrder, $_.VulnerabilityBand) }; Descending = $true },
        @{ Expression = { [int] $_.CriticalCount }; Descending = $true },
        @{ Expression = { [int] $_.VulnerabilityCount }; Descending = $true },
        DeviceName)

    # ---- write ---------------------------------------------------------------------------------

    $written = Write-MsecEvidenceWorkbook -Path $Path `
        -OwnerName $tenantName -OwnerId $tenantId -OwnerColumn 'TenantId' `
        -Row $rows `
        -CategoryProperty 'VulnerabilityBand' -CategoryOrder $bandOrder `
        -OwnerLabel 'Tenant' -CategoryLabel 'VulnerabilityBand' `
        -Count ([ordered]@{
            Devices      = { $true }
            WithCritical = { $_.CriticalCount -gt 0 }
        }) `
        -Heading 'Defender device vulnerability evidence' `
        -ChartTitlePrefix 'Devices by discovered vulnerabilities' `
        -CollectedUtc $collectedUtc `
        -TableStyle $TableStyle -ChartWidth $ChartWidth -ChartHeight $ChartHeight

    $unassessed = @($rows | Where-Object VulnerabilityBand -eq 'Not assessed')
    if ($unassessed.Count) {
        Write-Warning "$($unassessed.Count) of $written device(s) have no vulnerability data - reported as 'Not assessed' rather than zero. Check the Defender Vulnerability Management licence and the app's Vulnerability.Read.All permission."
    }

    $critical = @($rows | Where-Object { $_.CriticalCount -gt 0 })
    if ($critical.Count) {
        $total = (($critical | Measure-Object -Property CriticalCount -Sum).Sum)
        Write-Warning "$($critical.Count) of $written device(s) carry at least one critical vulnerability, $total in total."
    }

    if ($PassThru) { $rows }
}
