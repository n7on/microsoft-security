function Get-MsecDefenderScoreDeviceConfiguration {
    <#
    .SYNOPSIS
        Returns the current Microsoft Secure Score for Devices (raw configuration score).

    .DESCRIPTION
        Calls the Defender for Endpoint API (/api/configurationScore). The API returns a raw
        score in *points*, not a percentage - and exposes no maximum from which a percentage
        could be derived. The output field is therefore named 'Score' (not 'ScorePercent') to
        avoid implying a 0-100 scale.

        For an apples-to-apples device-control percentage in your posture report, prefer
        the 'Device' row from `Get-MsecSecureScore -Category Device` (a 0-100 percentage
        normalised against control maxima). Use this function only when you specifically
        need the raw Defender configuration points.

    .EXAMPLE
        Get-MsecDefenderScoreDeviceConfiguration

    .EXAMPLE
        # The normalised 0-100 device figure most reports want, for comparison. Score and
        # ScorePercent are different scales and must not be charted on one axis.
        Get-MsecSecureScore -Category Device

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
