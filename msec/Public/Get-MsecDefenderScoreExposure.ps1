function Get-MsecDefenderScoreExposure {
    <#
    .SYNOPSIS
        Returns the current Defender Vulnerability Management Exposure Score.

    .DESCRIPTION
        Calls Defender for Endpoint /api/exposureScore. The API exposes only the current value
        (no history) so Date is today's date. Exposure Score is 0-100 where LOWER is better -
        keep that in mind when reading the trend against the posture scores.
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
