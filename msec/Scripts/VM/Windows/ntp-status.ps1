# NTP / Windows Time service status as JSON.
# ISO 27001 evidence for A.8.17 (clock synchronisation).
#
# Read-only. Reads w32tm /query /status /verbose and parses the audit-relevant fields
# into a JSON object on stdout:
#
#   { NowUtc, TimeZone, Synchronized, NtpEnabled, Daemon, Source, Compliant }
#
# Synchronized = (W32Time running) AND (Stratum < 16) AND (Source != "Local CMOS Clock").
# Compliant    = the A.8.17 policy verdict — Synchronized AND a non-empty Source.

$ErrorActionPreference = 'Continue'

$result = [ordered]@{
    NowUtc       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    TimeZone     = (Get-TimeZone).Id
    Synchronized = $false
    NtpEnabled   = $false
    Daemon       = 'W32Time'
    Source       = ''
    Compliant    = $false
}

$svc = Get-Service -Name W32Time -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    $result.NtpEnabled = $true

    $verbose = (& w32tm /query /status /verbose 2>&1) -join "`n"

    # "Source: time.windows.com,0x9"
    if ($verbose -match '(?m)^\s*Source:\s*(.+?)\s*$') {
        $result.Source = $matches[1].Trim()
    }

    # "Stratum: 3 (...)" - lower = closer to authoritative; 16 means unsynchronized.
    $stratum = $null
    if ($verbose -match '(?m)^\s*Stratum:\s*(\d+)') {
        $stratum = [int]$matches[1]
    }

    if ($stratum -and $stratum -gt 0 -and $stratum -lt 16 -and
        $result.Source -notmatch 'Local\s+CMOS\s+Clock') {
        $result.Synchronized = $true
    }
}

# A.8.17 verdict — same rule as the Linux script so the CSV column is comparable.
$result.Compliant = ($result.Synchronized -and -not [string]::IsNullOrWhiteSpace($result.Source))

[pscustomobject]$result | ConvertTo-Json
