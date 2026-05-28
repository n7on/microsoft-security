function Get-MsecDeviceConfigurationScore {
    <#
    .SYNOPSIS
        Returns the current Microsoft Secure Score for Devices (raw configuration score).

    .DESCRIPTION
        Calls the Defender for Endpoint API (/api/configurationScore). The API returns a raw
        score in *points*, not a percentage - and exposes no maximum from which a percentage
        could be derived. The output field is therefore named 'Score' (not 'ScorePercent') to
        avoid implying a 0-100 scale.

        IMPORTANT: This function is deliberately NOT part of Get-MsecScoreSummary - mixing
        raw points with percentage scores in one table is misleading. Call this on its own
        when you want the raw value.

        For an apples-to-apples device-control percentage in your posture report, use the
        Microsoft Secure Score 'Device' category row from Get-MsecScoreSummary instead.

    .OUTPUTS
        PSCustomObject with ScoreType ('DeviceConfiguration'), Date (today), Score (raw points).
    #>
    [CmdletBinding()]
    param()

    $r = Invoke-MsecDefenderRequest -Path '/api/configurationScore'

    [PSCustomObject]@{
        ScoreType = 'DeviceConfiguration'
        Date      = (Get-Date).Date
        Score     = if ($null -ne $r.score) { [math]::Round([double]$r.score, 2) } else { $null }
    }
}
