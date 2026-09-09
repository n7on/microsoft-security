function Get-MsecDefenderScoreExposure {
    <#
    .SYNOPSIS
        Returns the current Defender Vulnerability Management Exposure Score.

    .DESCRIPTION
        Calls Defender for Endpoint /api/exposureScore. The API exposes only the current value
        (no history) so Date is today's date. Exposure Score is 0-100 where LOWER is better -
        keep that in mind when reading the trend against the posture scores.

    .EXAMPLE
        Get-MsecDefenderScoreExposure

    .EXAMPLE
        # Snapshot it yourself - the API keeps no history, so a trend only exists if you
        # store each reading.
        Get-MsecDefenderScoreExposure |
            Export-Csv ./exposure-history.csv -Append -NoTypeInformation

    .EXAMPLE
        # Read next to the posture scores, remembering this one runs the other way:
        # a rising Exposure Score is a worsening estate.
        Get-MsecSecureScore, (Get-MsecDefenderScoreExposure) | Format-Table ScoreType, ScorePercent

    .OUTPUTS
        PSCustomObject with ScoreType ('Exposure'), Date (today), ScorePercent (0-100,
        lower is better).
    #>
    [CmdletBinding()]
    param()

    $r = Invoke-MsecDefenderRequest -Path '/api/exposureScore'

    [PSCustomObject]@{
        ScoreType    = 'Exposure'
        Date         = (Get-Date).Date
        ScorePercent = if ($null -ne $r.score) { [math]::Round([double]$r.score, 2) } else { $null }
    }
}
