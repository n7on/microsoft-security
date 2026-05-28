function Get-MsecSecureScoreCategoryData {
    <#
    .SYNOPSIS
        Returns per-category Microsoft Secure Score percentages (one row per snapshot per category).

    .DESCRIPTION
        For each snapshot in /v1.0/security/secureScores, groups its controlScores by
        controlCategory, sums the achieved 'score' per category, and divides by the sum of each
        control's maxScore from /v1.0/security/secureScoreControlProfiles. Profiles are fetched
        once and reused.

        Achieved scores come from the historical snapshot, but maxScore comes from the *current*
        control profile - Microsoft's per-control maxima are stable, so this is accurate for
        trend reporting.

    .PARAMETER Category
        Optional filter (e.g. 'Identity'). When omitted, all categories present are returned.

    .PARAMETER Top
        Only process the N most recent snapshots. When omitted, processes all.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string] $Category,
        [Parameter()][ValidateRange(1, [int]::MaxValue)][int] $Top
    )

    Assert-MsecSession

    # 1. Build control-id -> maxScore map from control profiles.
    Write-Verbose 'Loading secureScoreControlProfiles...'
    $maxByControl = @{}
    foreach ($p in (Invoke-MsecGraphRequest -Path '/v1.0/security/secureScoreControlProfiles' -All)) {
        if ($null -ne $p.maxScore -and $p.id) {
            $maxByControl[$p.id] = [double]$p.maxScore
        }
    }

    # 2. Pull score snapshots.
    $scorePath = '/v1.0/security/secureScores'
    $snapshots = if ($PSBoundParameters.ContainsKey('Top')) {
        (Invoke-MsecGraphRequest -Path ($scorePath + "?`$top=$Top")).value
    }
    else {
        Invoke-MsecGraphRequest -Path $scorePath -All
    }

    # 3. Per snapshot: group controlScores by category, compute achieved/max -> percent.
    foreach ($snapshot in $snapshots) {
        $byCategory = @{}
        foreach ($control in $snapshot.controlScores) {
            $cat = $control.controlCategory
            if (-not $cat) { continue }

            if (-not $byCategory.ContainsKey($cat)) {
                $byCategory[$cat] = [PSCustomObject]@{ Achieved = 0.0; Max = 0.0 }
            }

            $achieved = if ($null -ne $control.score) { [double]$control.score } else { 0.0 }
            $byCategory[$cat].Achieved += $achieved

            $controlId = $control.controlName
            if ($controlId -and $maxByControl.ContainsKey($controlId)) {
                $byCategory[$cat].Max += $maxByControl[$controlId]
            }
        }

        foreach ($cat in $byCategory.Keys) {
            if ($Category -and $cat -ne $Category) { continue }

            $totals = $byCategory[$cat]
            $percent = if ($totals.Max -gt 0) {
                [math]::Round(($totals.Achieved / $totals.Max) * 100, 2)
            }
            else { $null }

            [PSCustomObject]@{
                ScoreType    = $cat
                Date         = [datetime]$snapshot.createdDateTime
                ScorePercent = $percent
            }
        }
    }
}
