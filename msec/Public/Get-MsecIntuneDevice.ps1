function Get-MsecIntuneDevice {
    <#
    .SYNOPSIS
        Lists every managed device known to Intune, projected to a flat PowerShell
        shape suitable for filtering / grouping / exporting.

    .DESCRIPTION
        Calls Microsoft Graph /v1.0/deviceManagement/managedDevices with a $select
        for the audit-relevant columns, paginates through @odata.nextLink, and
        emits one PSCustomObject per device.

        Aggregate stats are produced in PowerShell on the consumer side - msec only
        returns the raw device list. This matches Search-MsecAzureResourceGraph /
        Get-MsecIntuneCompliancePolicy: the module returns rows, the consumer
        decides what to do with them. See the examples.

        Requires the 'DeviceManagementManagedDevices.Read.All' application
        permission. Different from DeviceManagementConfiguration.Read.All (which
        msec already has) - configuration is about POLICIES, this is about
        DEVICES. A clearer error is raised on the typical 403.

    .EXAMPLE
        # Compliance counts.
        Get-MsecIntuneDevice | Group-Object ComplianceState | Sort-Object Count -Descending

    .EXAMPLE
        # Devices not seen in 30 days - stale management. A device that stopped checking
        # in keeps its last compliance verdict, so these read as compliant while being
        # entirely unverified.
        Get-MsecIntuneDevice |
            Where-Object { $_.LastSyncDateTime -lt (Get-Date).AddDays(-30) }

    .EXAMPLE
        # OS family breakdown.
        Get-MsecIntuneDevice | Group-Object Os | Select-Object Name, Count

    .EXAMPLE
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

    .OUTPUTS
        PSCustomObject per device, with the columns documented in the .NOTES.

    .NOTES
        Projected columns (Graph field -> output property):
          id                                       -> Id
          deviceName                               -> DeviceName
          userPrincipalName                        -> UserPrincipalName
          userDisplayName                          -> UserDisplayName
          operatingSystem                          -> Os
          osVersion                                -> OsVersion
          model                                    -> Model
          manufacturer                             -> Manufacturer
          complianceState                          -> ComplianceState
          complianceGracePeriodExpirationDateTime  -> ComplianceGraceUntil (null when no grace)
          managementState                          -> ManagementState
          managementAgent                          -> ManagementAgent
          managedDeviceOwnerType                   -> Ownership ('company' / 'personal' / 'unknown')
          isEncrypted                              -> IsEncrypted
          jailBroken                               -> Jailbroken
          azureADRegistered                        -> EntraRegistered
          enrolledDateTime                         -> EnrolledDateTime
          lastSyncDateTime                         -> LastSyncDateTime
          serialNumber                             -> SerialNumber
    #>
    [CmdletBinding()]
    param()

    Assert-MsecSession

    # $select trims the response to ~20% of the full managedDevice shape. Stops
    # us paging through 80+ noisy columns we don't need. Comma-joined so we don't
    # have to URL-encode anything ourselves; Graph accepts the bare list.
    $select = @(
        'id'
        'deviceName'
        'userPrincipalName'
        'userDisplayName'
        'operatingSystem'
        'osVersion'
        'model'
        'manufacturer'
        'complianceState'
        'complianceGracePeriodExpirationDateTime'
        'managementState'
        'managementAgent'
        'managedDeviceOwnerType'
        'isEncrypted'
        'jailBroken'
        'azureADRegistered'
        'enrolledDateTime'
        'lastSyncDateTime'
        'serialNumber'
    ) -join ','

    $path = "/v1.0/deviceManagement/managedDevices?`$select=$select"

    try {
        $devices = @(Invoke-MsecGraphRequest -Path $path -All)
    }
    catch {
        if ($_.Exception.Message -match '403|Forbidden') {
            throw "Forbidden when calling /deviceManagement/managedDevices. The msec app needs the 'DeviceManagementManagedDevices.Read.All' application permission (admin consent required). Re-run New-MsecApp to add and consent it. Original error: $($_.Exception.Message)"
        }
        throw
    }

    foreach ($d in $devices) {
        # Graph returns a sentinel '9999-12-31T...' when no grace period is set;
        # surface that as $null so the caller can filter / compare cleanly.
        $grace = $null
        if ($d.complianceGracePeriodExpirationDateTime -and
            $d.complianceGracePeriodExpirationDateTime -notmatch '^9999-') {
            $grace = [datetime]$d.complianceGracePeriodExpirationDateTime
        }

        [PSCustomObject]@{
            Id                   = $d.id
            DeviceName           = $d.deviceName
            UserPrincipalName    = $d.userPrincipalName
            UserDisplayName      = $d.userDisplayName
            Os                   = $d.operatingSystem
            OsVersion            = $d.osVersion
            Model                = $d.model
            Manufacturer         = $d.manufacturer
            ComplianceState      = $d.complianceState
            ManagementState      = $d.managementState
            ManagementAgent      = $d.managementAgent
            Ownership            = $d.managedDeviceOwnerType
            IsEncrypted          = $d.isEncrypted
            Jailbroken           = $d.jailBroken
            EntraRegistered      = $d.azureADRegistered
            EnrolledDateTime     = if ($d.enrolledDateTime) { [datetime]$d.enrolledDateTime } else { $null }
            LastSyncDateTime     = if ($d.lastSyncDateTime) { [datetime]$d.lastSyncDateTime } else { $null }
            ComplianceGraceUntil = $grace
            SerialNumber         = $d.serialNumber
        }
    }
}
