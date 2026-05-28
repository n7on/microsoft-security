function Get-MsecDeviceConfigurationScore {
    <#
    .SYNOPSIS
        Returns the current Microsoft Secure Score for Devices (configuration score).

    .DESCRIPTION
        Calls Defender for Endpoint /api/configurationScore. The API exposes only the current
        value (no history) and returns a raw score; it is surfaced as-is in ScorePercent (the
        endpoint does not return a maximum, so it is not normalized to a true percentage).
    #>
    [CmdletBinding()]
    param()

    $r = Invoke-MsecDefenderRequest -Path '/api/configurationScore'

    [PSCustomObject]@{
        ScoreType    = 'DeviceConfiguration'
        Date         = (Get-Date).Date
        ScorePercent = if ($null -ne $r.score) { [math]::Round([double]$r.score, 2) } else { $null }
    }
}
