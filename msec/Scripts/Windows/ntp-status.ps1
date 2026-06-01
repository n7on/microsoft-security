# NTP / Windows Time service status. ISO 27001 evidence for A.8.17 (clock synchronisation).
#
# Read-only. Captures W32Time service state, current source, peer list, configuration,
# and verbose status (which includes Stratum + LastTimeOffset). Output is plain text
# grouped by section so an auditor can read it as-is.

$ErrorActionPreference = 'Continue'

'=== System time ==='
"now (UTC):   $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC"
"now (local): $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))"
"timezone:    $((Get-TimeZone).Id)"

''
'=== W32Time service ==='
$svc = Get-Service -Name W32Time -ErrorAction SilentlyContinue
if ($svc) {
    "Status:    $($svc.Status)"
    "StartType: $($svc.StartType)"
}
else {
    'WARNING: Windows Time service (W32Time) not found on this host.'
}

''
'=== w32tm /query /status /verbose ==='
& w32tm /query /status /verbose 2>&1

''
'=== w32tm /query /source ==='
& w32tm /query /source 2>&1

''
'=== w32tm /query /peers ==='
& w32tm /query /peers 2>&1

''
'=== w32tm /query /configuration ==='
& w32tm /query /configuration 2>&1
