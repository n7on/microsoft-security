function Save-MsecCache {
    <#
    .SYNOPSIS
        Writes a named completion cache. Never throws.

    .DESCRIPTION
        Best effort by design. A read-only home directory, a locked file or a full disk is a
        degraded tab-completion experience - it is not a reason to fail the query the caller
        actually asked for. Failures go to the verbose stream and nowhere else.

    .PARAMETER Name
        Cache name. See Get-MsecCachePath.

    .PARAMETER Item
        The rows to cache.

    .PARAMETER Metadata
        Extra fields to record alongside the rows - the subscription scope a Resource Graph
        result came from, for instance. Written into the envelope, never into the rows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Item,

        [Parameter()]
        [hashtable] $Metadata
    )

    try {
        $path = Get-MsecCachePath -Name $Name
        $dir  = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        $envelope = [ordered]@{
            UpdatedUtc = [DateTime]::UtcNow.ToString('o')
            TenantId   = (Get-AzContext -ErrorAction SilentlyContinue).Tenant.Id
        }
        if ($Metadata) {
            foreach ($key in $Metadata.Keys) { $envelope[$key] = $Metadata[$key] }
        }
        $envelope['Items'] = @($Item)

        [pscustomobject]$envelope | ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath $path -Encoding utf8 -ErrorAction Stop

        Write-Verbose "Cache '$Name' refreshed: $path ($(@($Item).Count) item(s))."
    }
    catch {
        Write-Verbose "Could not write cache '$Name': $($_.Exception.Message)"
    }
}
