function Get-MsecTenantProfile {
    <#
    .SYNOPSIS
        Reads a saved connection profile for a tenant, or returns $null. Never throws.

    .DESCRIPTION
        The read half of Save-MsecTenantProfile. Returns $null for every failure - no file,
        unreadable file, malformed JSON, a profile missing the fields Connect-Msec needs -
        because every caller treats "no profile" and "unusable profile" the same way: carry on
        without auto-reconnecting.

        A profile written by an older version, or hand-edited into a broken state, is therefore
        ignored rather than turned into a confusing failure in the middle of a context switch.

    .PARAMETER TenantId
        The tenant to look up.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $TenantId
    )

    try {
        $path = Get-MsecCachePath -Name 'profile' -TenantId $TenantId
        if (-not (Test-Path -LiteralPath $path)) { return $null }

        $profile = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

        # Both are mandatory on Connect-Msec, so a profile without them cannot be acted on.
        if (-not $profile.KeyVaultName -or -not $profile.ClientId) {
            Write-Verbose "The connection profile for tenant $TenantId is missing KeyVaultName or ClientId; ignoring it."
            return $null
        }

        return $profile
    }
    catch {
        Write-Verbose "Could not read the connection profile for tenant $TenantId : $($_.Exception.Message)"
        return $null
    }
}
