function Get-MsecSecureScore {
    <#
    .SYNOPSIS
        Returns the overall Microsoft Secure Score history as ScoreType / Date / ScorePercent.

    .DESCRIPTION
        Calls Microsoft Graph /v1.0/security/secureScores and projects each snapshot to a row with
        ScoreType='Overall', Date=createdDateTime, ScorePercent=currentScore/maxScore*100.

    .PARAMETER Top
        Only the N most recent snapshots. When omitted, returns all (pages through @odata.nextLink).

    .EXAMPLE
        Get-MsecSecureScore -Top 1
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $Top
    )

    Assert-MsecSession

    $path = '/v1.0/security/secureScores'
    if ($PSBoundParameters.ContainsKey('Top')) {
        $response = Invoke-MsecGraphRequest -Path ($path + "?`$top=$Top")
        $items = $response.value
    }
    else {
        $items = Invoke-MsecGraphRequest -Path $path -All
    }

    foreach ($s in $items) {
        $percent = if ($s.maxScore) {
            [math]::Round(($s.currentScore / $s.maxScore) * 100, 2)
        }
        else { $null }

        [PSCustomObject]@{
            ScoreType    = 'Overall'
            Date         = [datetime]$s.createdDateTime
            ScorePercent = $percent
        }
    }
}
