function Read-MsecCache {
    <#
    .SYNOPSIS
        Reads a named completion cache. Never throws, returns an empty array when there is
        nothing usable.

    .DESCRIPTION
        Called from argument completers, which is the whole reason for the swallowed errors: a
        completer that throws breaks the prompt itself. A missing, half-written or hand-edited
        cache file has to degrade to "no suggestions", never to an error.

        Deliberately does no staleness check. A stale name completes to a workspace or
        subscription that no longer exists, and the command then fails with a clear message
        listing the real candidates - which is a better outcome than a completer that silently
        offers nothing because the file is a week old.

        Nor does it check the tenant, because it cannot need to: Get-MsecCachePath puts each
        tenant's caches in their own folder, so reading the wrong tenant's data is not something
        this function could do. That also means both tenants stay warm across a
        Select-MsecAzureContext flip, which an on-read check could not manage - it would discard
        the other tenant's cache and the next query would overwrite it.

    .PARAMETER Name
        Cache name. See Get-MsecCachePath.

    .PARAMETER Envelope
        Return the whole cache object - UpdatedUtc, TenantId, any metadata, and Items - instead
        of just the rows. Callers that need to decide whether a cache is fresh enough need the
        timestamp; completers, which do not care, take the default.

    .OUTPUTS
        The cached rows, or the envelope with -Envelope. Empty array / $null when there is
        nothing usable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter()]
        [switch] $Envelope
    )

    try {
        $path = Get-MsecCachePath -Name $Name
        if (-not (Test-Path -LiteralPath $path)) { return $(if ($Envelope) { $null } else { @() }) }
        $cache = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($Envelope) { return $cache }
        return @($cache.Items)
    }
    catch {
        return $(if ($Envelope) { $null } else { @() })
    }
}
