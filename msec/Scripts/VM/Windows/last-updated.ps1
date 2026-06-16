# last-updated: when did this machine last install updates, regardless of whether
# Azure Update Manager or in-guest Windows Update did it? Read-only.
#
# Emits a single JSON object on stdout (PascalCase keys), e.g.:
#   {"NowUtc":"2026-06-15T08:00:00Z","LastUpdate":"2026-05-12T03:14:00Z",
#    "LastUpdatePackage":"2026-05 Cumulative Update ...","DaysSinceUpdate":34,
#    "UpdateCount30d":7,"Source":"WindowsUpdateAgent"}
#
# Continue (not Stop) so an individual probe failure degrades to nulls rather than
# yielding no row.
$ErrorActionPreference = 'Continue'

$nowUtc    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$last      = $null      # DateTime of newest successful install
$lastTitle = $null
$count30d  = $null
$source    = $null

# Normalize any DateTime to UTC. The Windows Update Agent returns its Date as UTC
# wall-clock but with Kind=Unspecified; calling ToUniversalTime() on that would wrongly
# shift it by the local offset. So: treat Unspecified as already-UTC, convert only Local.
function ConvertTo-Utc($dt) {
    if ($null -eq $dt) { return $null }
    if ($dt.Kind -eq [DateTimeKind]::Local) { return $dt.ToUniversalTime() }
    return [DateTime]::SpecifyKind($dt, [DateTimeKind]::Utc)
}

# Primary source: the Windows Update Agent install history. This captures cumulative
# updates that Get-HotFix misses (Get-HotFix only lists QFE/MSU hotfixes).
try {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $total    = $searcher.GetTotalHistoryCount()
    if ($total -gt 0) {
        $source = 'WindowsUpdateAgent'
        # Operation 1 = Installation; ResultCode 2 = Succeeded.
        $hist = @($searcher.QueryHistory(0, $total) |
            Where-Object { $_.Operation -eq 1 -and $_.ResultCode -eq 2 })
        if ($hist.Count -gt 0) {
            $latest    = $hist | Sort-Object Date -Descending | Select-Object -First 1
            $last      = $latest.Date
            $lastTitle = $latest.Title
            $cut       = [DateTime]::UtcNow.AddDays(-30)
            $count30d  = @($hist | Where-Object { $_.Date -ge $cut }).Count
        }
    }
}
catch { }

# Fallback: QFE hotfixes. A subset of all updates, but better than nothing if the
# WUA history is unavailable (e.g. agent disabled).
if (-not $last) {
    $hf = Get-HotFix -ErrorAction SilentlyContinue |
        Where-Object InstalledOn |
        Sort-Object InstalledOn -Descending |
        Select-Object -First 1
    if ($hf) {
        $source    = 'Get-HotFix'
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
    Source            = $source
} | ConvertTo-Json -Compress
