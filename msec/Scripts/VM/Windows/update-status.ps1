# update-status: the full patch picture for this machine in one shot -
#   * when it last installed updates (history, from the Windows Update Agent)
#   * how many SECURITY vs OTHER updates are pending NOW
#   * whether a reboot is pending
#
# The pending search ($searcher.Search) queries Windows Update / WSUS online, so it can
# take a while on a cold agent - that's the same assessment Update Manager performs, so
# the counts line up. Emits a single JSON object on stdout. Continue (not Stop) so an
# individual probe failure degrades to nulls rather than yielding no row.
$ErrorActionPreference = 'Continue'

$nowUtc       = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$last         = $null      # DateTime of newest successful install
$lastTitle    = $null
$count30d     = $null
$secPending   = $null
$otherPending = $null
$reboot       = $false
$assessed     = $false
$source       = $null

# The Windows Update Agent returns its Date as UTC wall-clock but Kind=Unspecified;
# calling ToUniversalTime() on that would wrongly shift it. Treat Unspecified as UTC.
function ConvertTo-Utc($dt) {
    if ($null -eq $dt) { return $null }
    if ($dt.Kind -eq [DateTimeKind]::Local) { return $dt.ToUniversalTime() }
    return [DateTime]::SpecifyKind($dt, [DateTimeKind]::Utc)
}

try {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $source   = 'WindowsUpdateAgent'

    # ---- history: last successful install (captures cumulative updates Get-HotFix misses) ----
    $total = $searcher.GetTotalHistoryCount()
    if ($total -gt 0) {
        $hist = @($searcher.QueryHistory(0, $total) |
            Where-Object { $_.Operation -eq 1 -and $_.ResultCode -eq 2 })   # installed & succeeded
        if ($hist.Count -gt 0) {
            $latest    = $hist | Sort-Object Date -Descending | Select-Object -First 1
            $last      = $latest.Date
            $lastTitle = $latest.Title
            $cut       = [DateTime]::UtcNow.AddDays(-30)
            $count30d  = @($hist | Where-Object { $_.Date -ge $cut }).Count
        }
    }

    # ---- pending: ask WU/WSUS what's not installed, split security vs other ----
    $result   = $searcher.Search("IsInstalled=0 and Type='Software'")
    $pending  = @($result.Updates)
    $assessed = $true
    $isSecurity = {
        param($u)
        if ($u.MsrcSeverity) { return $true }                              # security updates carry a severity
        foreach ($c in $u.Categories) { if ($c.Name -eq 'Security Updates') { return $true } }
        return $false
    }
    $sec          = @($pending | Where-Object { & $isSecurity $_ })
    $secPending   = $sec.Count
    $otherPending = $pending.Count - $sec.Count
}
catch { }

# Reboot pending (from the WUA system info).
try { $reboot = [bool](New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired } catch { }

# Fallback for last install if WUA history was unavailable.
if (-not $last) {
    $hf = Get-HotFix -ErrorAction SilentlyContinue |
        Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($hf) {
        if (-not $source) { $source = 'Get-HotFix' }
        $last      = $hf.InstalledOn
        $lastTitle = $hf.HotFixID
    }
}

$lastUtc = ConvertTo-Utc $last
$lastIso = if ($lastUtc) { $lastUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
$days    = if ($lastUtc) { [int]([DateTime]::UtcNow - $lastUtc).TotalDays } else { $null }

[pscustomobject]@{
    NowUtc            = $nowUtc
    LastUpdate        = $lastIso
    LastUpdatePackage = $lastTitle
    DaysSinceUpdate   = $days
    UpdateCount30d    = $count30d
    SecurityPending   = $secPending
    OtherPending      = $otherPending
    RebootRequired    = $reboot
    AssessedFresh     = $assessed
    Source            = $source
} | ConvertTo-Json -Compress
