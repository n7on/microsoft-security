function Get-MsecCachePath {
    <#
    .SYNOPSIS
        Path of a named on-disk cache used to make tab completion instant.

    .DESCRIPTION
        The module's only on-disk state. It exists for one reason: some parameters can only be
        completed from a list that lives in Azure, and a completer that calls Azure blocks the
        prompt on every Tab - worse, when ARM is unhealthy it does not fail fast, it hangs. So
        completers read these files and nothing else.

        Each cache is refreshed as a side effect of a call that already fetched the data, so
        keeping them warm costs no extra API calls.

        WHAT DOES AND DOES NOT BELONG HERE. Cache a list only when there is no correct local
        source for it:
          * subscriptions           - Get-AzContext -ListAvailable looks like a free local
                                      answer and is not: it reflects what you have signed into,
                                      which drifts from what you can actually reach, in BOTH
                                      directions. Get-AzSubscription is authoritative, and it is
                                      a network call, so it gets cached.
          * graph-<type>-<name>     - the result of a bundled Resource Graph query, e.g.
                                      graph-loganalytics-all. Written by every real call, read
                                      back by -UseCache and by completers.
        Nothing else currently qualifies. The -ResourceType and -Name completers read .kql files
        from the module folder: already local, already instant, and caching them would add
        staleness for no gain.

        Nothing sensitive is stored - names, ids, resource groups, locations. No keys, no
        tokens, no data.

        MSEC_CACHE_DIR overrides the directory. That exists so the test suite can redirect the
        whole cache to a temp folder: completers resolve their path through this function and
        there is otherwise no seam, so tests would have to write the real per-user cache and put
        it back. Backup-and-restore around files that several tests overwrite is the kind of
        thing that works until it doesn't - and when it doesn't it silently costs a developer
        their warm cache. Also useful for CI.

        Tests that mock Az and forget to redirect are contained rather than dangerous: their
        fake context yields a fake tenant, so they write to a folder of their own and cannot
        touch a real tenant's cache. Worth knowing before adding machinery to police it - an
        earlier guard test tried to, could not see transitive writes through the call graph, and
        was deleted once partitioning made the damage cosmetic.

    .PARAMETER Name
        Cache name, used as the file's base name. 'subscriptions', 'graph-loganalytics-all'.

    .OUTPUTS
        String. The full path. The file itself may not exist yet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9-]+$')]
        [string] $Name
    )

    # Tenant-scoped, one subfolder per tenant. Flipping context with Select-MsecAzureContext is
    # routine, and a single shared file would mean each flip discards the other tenant's cache
    # and overwrites it - so ping-ponging between two tenants leaves the cache permanently cold
    # and completion dead after every switch. Separate folders let both stay warm, and make
    # cross-tenant bleed impossible by construction rather than by a check on read.
    $tenantId = (Get-AzContext -ErrorAction SilentlyContinue).Tenant.Id
    if (-not $tenantId) {
        # Callers all treat a failure here as "no cache": Read-MsecCache returns empty,
        # Save-MsecCache logs to verbose, completers offer nothing. Without a context there is
        # nothing to query anyway.
        throw 'No Azure context, so there is no tenant to scope the cache to.'
    }

    $dir = $env:MSEC_CACHE_DIR
    if (-not $dir) {
        $base = [Environment]::GetFolderPath('LocalApplicationData')
        if (-not $base) {
            # GetFolderPath returns empty rather than throwing on minimal Linux containers where
            # neither XDG_DATA_HOME nor HOME is set the way .NET expects.
            $base = Join-Path ($HOME ?? [System.IO.Path]::GetTempPath()) '.local/share'
        }
        $dir = Join-Path $base 'msec'
    }
    Join-Path (Join-Path $dir $tenantId) "$Name.json"
}
