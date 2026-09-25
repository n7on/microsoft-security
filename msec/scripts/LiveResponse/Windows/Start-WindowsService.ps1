<#
.SYNOPSIS
    Live Response library script - start a Windows service, optionally changing its startup type.

.DESCRIPTION
    Uploaded to the Defender XDR Live Response library and run against ONE device, by an
    analyst, during an investigation. It is not an Intune Remediation and must not be uploaded
    as one: a remediation runs on every device in its assignment, which turns an investigative
    action into a fleet-wide configuration change.

    Prints the service state BEFORE and AFTER rather than reporting the call succeeded - a
    Set-Service that policy or a dependency quietly undoes otherwise reads as success.

.PARAMETER Name
    Service SHORT name, e.g. DiagTrack - not the display name. The Live Response 'services'
    command lists both.

.PARAMETER StartupType
    Automatic, Manual, or Unchanged (default). Required if the service is Disabled: starting a
    disabled service fails, and the script says so rather than reporting a generic error.

.PARAMETER Restart
    Restart the service if it is already running. Without it, an already-running service is
    left alone and reported as such.

.EXAMPLE
    run Start-WindowsService.ps1 -parameters "-Name DiagTrack"

.EXAMPLE
    run Start-WindowsService.ps1 -parameters "-Name DiagTrack -StartupType Automatic"

.EXAMPLE
    run Start-WindowsService.ps1 -parameters "-Name wuauserv -Restart"

.NOTES
    Runs as SYSTEM via Live Response. Requires "Live response unsigned script execution" in
    the Defender portal's advanced features unless the script is signed.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [ValidateSet('Automatic', 'Manual', 'Unchanged')]
    [string]$StartupType = 'Unchanged',

    [switch]$Restart
)

try {
    $svc = Get-Service -Name $Name -ErrorAction Stop
} catch {
    Write-Output "ERROR: Service '$Name' not found. Use the short service name (see 'services' output)."
    return
}

Write-Output "BEFORE: $($svc.Name) ($($svc.DisplayName)) - Status=$($svc.Status), StartType=$($svc.StartType)"

try {
    # Startup type
    if ($StartupType -ne 'Unchanged' -and $svc.StartType -ne $StartupType) {
        Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        Write-Output "CHANGED: StartType $($svc.StartType) -> $StartupType"
    } elseif ($svc.StartType -eq 'Disabled') {
        Write-Output "ERROR: Service is Disabled. Re-run with -StartupType Automatic or Manual."
        return
    }

    # Start / restart
    $svc.Refresh()
    if ($svc.Status -eq 'Running') {
        if ($Restart) {
            Restart-Service -Name $Name -Force -ErrorAction Stop
            Write-Output "ACTION: Restarted"
        } else {
            Write-Output "ACTION: Already running - nothing to do (use -Restart to restart)"
        }
    } else {
        Start-Service -Name $Name -ErrorAction Stop
        $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
        Write-Output "ACTION: Started"
    }
} catch {
    Write-Output "ERROR: $($_.Exception.Message)"
}

$svc.Refresh()
Write-Output "AFTER:  $($svc.Name) - Status=$($svc.Status), StartType=$($svc.StartType)"