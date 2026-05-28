function Get-MsecScoreSummary {
    <#
    .SYNOPSIS
        Combined Microsoft Security posture summary - one row per score type with today,
        previous-month, and the diff in percentage points.

    .DESCRIPTION
        Designed for security-posture meetings / ISO 27001 reviews. Includes:
          - Overall Microsoft Secure Score + categories (Identity, Device, Apps, Data,
            Infrastructure - whichever your tenant exposes), sourced from Microsoft Graph
            (~90 days of history -> today, previous-month, and diff are populated).
          - Defender Exposure Score and Device Configuration Score, sourced from the
            Defender for Endpoint API (current value only -> previous-month/diff blank
            until you persist your own history).

        "Today" is the most recent snapshot; "previous month" is the snapshot closest to one
        month before it. Diff is in percentage points (today minus previous month).

    .EXAMPLE
        Connect-Msec ...
        Get-MsecScoreSummary | Format-Table -AutoSize

    .OUTPUTS
        PSCustomObject: ScoreType, TodayDate, TodayPercent, PreviousMonthDate, PreviousMonthPercent, DiffPercent.
    #>
    [CmdletBinding()]
    param()

    Assert-MsecSession

    # Reduce one score's time series to today / previous-month / diff.
    $reduce = {
        param($series)
        $sorted = @($series | Sort-Object Date -Descending)
        $today = $sorted[0]

        $previous = $null
        if ($sorted.Count -gt 1) {
            $target = $today.Date.AddMonths(-1)
            $previous = $sorted |
                Sort-Object { [math]::Abs(($_.Date - $target).TotalDays) } |
                Select-Object -First 1
        }

        $diff = $null
        if ($previous -and $null -ne $today.ScorePercent -and $null -ne $previous.ScorePercent) {
            $diff = [math]::Round($today.ScorePercent - $previous.ScorePercent, 2)
        }

        [PSCustomObject]@{
            ScoreType            = $today.ScoreType
            TodayDate            = $today.Date.ToString('yyyy-MM-dd')
            TodayPercent         = $today.ScorePercent
            PreviousMonthDate    = if ($previous) { $previous.Date.ToString('yyyy-MM-dd') } else { $null }
            PreviousMonthPercent = if ($previous) { $previous.ScorePercent } else { $null }
            DiffPercent          = $diff
        }
    }

    # Graph series (history): Overall + all present categories.
    $graphSeries = @()
    $graphSeries += Get-MsecSecureScore
    $graphSeries += Get-MsecSecureScoreCategoryData

    # Overall first (headline), then categories alphabetically.
    $groups = $graphSeries | Group-Object ScoreType |
        Sort-Object { if ($_.Name -eq 'Overall') { 0 } else { 1 } }, Name
    foreach ($group in $groups) {
        & $reduce $group.Group
    }

    # Defender (current value only): emit with blank prev-month/diff for column alignment.
    foreach ($score in @(Get-MsecExposureScore; Get-MsecDeviceConfigurationScore)) {
        [PSCustomObject]@{
            ScoreType            = $score.ScoreType
            TodayDate            = $score.Date.ToString('yyyy-MM-dd')
            TodayPercent         = $score.ScorePercent
            PreviousMonthDate    = $null
            PreviousMonthPercent = $null
            DiffPercent          = $null
        }
    }
}
