# Example script - print basic OS / kernel-ish / uptime info.
# Read-only; safe to run anywhere.
$ErrorActionPreference = 'Stop'

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$uptime = (Get-Date) - $os.LastBootUpTime

"hostname:       $($cs.Name)"
"distribution:   $($os.Caption) ($($os.Version) build $($os.BuildNumber))"
"architecture:   $($os.OSArchitecture)"
"uptime:         $([int]$uptime.TotalDays)d $($uptime.Hours)h $($uptime.Minutes)m"
