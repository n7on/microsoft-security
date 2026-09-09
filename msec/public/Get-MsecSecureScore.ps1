function Get-MsecSecureScore {
    <#
    .SYNOPSIS
        Returns Microsoft Secure Score snapshots as flat rows: ScoreType / Date /
        ScorePercent. Covers both the overall score and every category surfaced by
        Microsoft Graph (Identity, Device, Apps, Data, Infrastructure, plus anything
        Microsoft adds later).

    .DESCRIPTION
        Calls Microsoft Graph /v1.0/security/secureScores. For each snapshot, emits
        one 'Overall' row (currentScore / maxScore) plus one row per category in the
        snapshot's controlScores collection. Per-category percentages are computed by
        summing achieved 'score' values and dividing by the matching sum of maxScore
        values from /v1.0/security/secureScoreControlProfiles. Profiles are stable
        across snapshots, so they're fetched once per call.

        Use this as the single source for Secure Score history. Trend math (diff vs
        previous snapshot, month-over-month, etc.) lives in the consumer - msec's
        job is to expose the raw shape.

    .PARAMETER Category
        Restrict the output to one ScoreType: 'Overall' for the overall row, or a
        category name (Identity, Device, Apps, Data, Infrastructure). When omitted,
        every category present in the snapshot is emitted alongside Overall. Tab
        completes against the known categories but accepts any string in case
        Microsoft adds a new one.

    .PARAMETER Top
        Only process the N most recent snapshots. When omitted, every snapshot in
        the API's window (~90 days) is returned. Pass -Top 1 for today's snapshot.

    .EXAMPLE
        # Today's overall + categories, one row each.
        Get-MsecSecureScore -Top 1

    .EXAMPLE
        # Just Identity, full history (~90 days). Suitable for trend charts.
        Get-MsecSecureScore -Category Identity

    .EXAMPLE
        # Bootstrap an archive with the full 90-day window across every category.
        Get-MsecSecureScore | ConvertTo-Json -Depth 4 | Set-Content ./archive/seed.json

    .OUTPUTS
        PSCustomObject per (snapshot, ScoreType) combination, with:
          - ScoreType    : 'Overall' or a category name.
          - Date         : DateTime of the snapshot.
          - ScorePercent : 0-100 percentage (null if maxScore was 0/missing).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            'Overall', 'Identity', 'Device', 'Apps', 'Data', 'Infrastructure' |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new(
                        $_, $_, 'ParameterValue', $_)
                }
        })]
        [string] $Category,

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $Top
    )

    Assert-MsecSession

    # Skip the (expensive) profile fetch when the caller only wants Overall - the
    # control-id -> maxScore map is only needed for per-category math.
    $needCategories = (-not $Category) -or ($Category -ne 'Overall')

    $maxByControl = @{}
    if ($needCategories) {
        Write-Verbose 'Loading secureScoreControlProfiles for per-category maxima...'
        foreach ($p in (Invoke-MsecGraphRequest -Path '/v1.0/security/secureScoreControlProfiles' -All)) {
            if ($null -ne $p.maxScore -and $p.id) {
                $maxByControl[$p.id] = [double]$p.maxScore
            }
        }
    }

    # Pull score snapshots. The Graph API returns up to ~90 days; with -Top we trim.
    $scorePath = '/v1.0/security/secureScores'
    $snapshots = if ($PSBoundParameters.ContainsKey('Top')) {
        (Invoke-MsecGraphRequest -Path ($scorePath + "?`$top=$Top")).value
    }
    else {
        Invoke-MsecGraphRequest -Path $scorePath -All
    }

    foreach ($snapshot in $snapshots) {
        $date = [datetime]$snapshot.createdDateTime

        # Overall row for this snapshot.
        if (-not $Category -or $Category -eq 'Overall') {
            $overallPct = if ($snapshot.maxScore) {
                [math]::Round(($snapshot.currentScore / $snapshot.maxScore) * 100, 2)
            }
            else { $null }

            [PSCustomObject]@{
                ScoreType    = 'Overall'
                Date         = $date
                ScorePercent = $overallPct
            }
        }

        if ($needCategories) {
            # Group this snapshot's controls by category and accumulate (achieved, max).
            $byCategory = @{}
            foreach ($control in $snapshot.controlScores) {
                $cat = $control.controlCategory
                if (-not $cat) { continue }

                if (-not $byCategory.ContainsKey($cat)) {
                    $byCategory[$cat] = [PSCustomObject]@{ Achieved = 0.0; Max = 0.0 }
                }

                $byCategory[$cat].Achieved +=
                    if ($null -ne $control.score) { [double]$control.score } else { 0.0 }

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
                    Date         = $date
                    ScorePercent = $percent
                }
            }
        }
    }
}
