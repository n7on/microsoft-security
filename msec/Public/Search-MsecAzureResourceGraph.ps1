function Search-MsecAzureResourceGraph {
    <#
    .SYNOPSIS
        Runs a bundled KQL query against Azure Resource Graph and returns the rows.

    .DESCRIPTION
        The query is loaded by convention from:

            msec/Kql/Graph/<ResourceType>/<Name>.kql

        For example, Search-MsecAzureResourceGraph -ResourceType VM loads Kql/Graph/VM/All.kql. Each
        resource-type folder has at least an All.kql; named variants (e.g. "Running.kql")
        live alongside it and are selected via -Name.

        Filtering is intentionally NOT done here - that's what PowerShell pipelines are
        for. Pipe the output into Where-Object / Sort-Object / Select-Object:

            Search-MsecAzureResourceGraph -ResourceType VM | Where-Object Os -eq 'Linux' | ...

        Required: Az.ResourceGraph, an Az context, and Reader RBAC at the resources'
        scope (ARG honours RBAC and just omits resources you cannot see).

        Pagination is automatic: pages of -First rows (max 1000, ARG's own per-page
        ceiling) are followed via the response skip token until the result set is
        exhausted, so row counts above 1000 come back whole. Rule-per-row queries
        blow past 1000 easily - KeyVault/NetworkRules alone is over 1100 on a
        mid-sized tenant.

        -MaxRows is a runaway guard, not a page size. If a query somehow exceeds it,
        output STOPS there and a warning says so. It never truncates silently: an
        under-reported security query looks exactly like a clean one.

    .PARAMETER ResourceType
        The resource-type folder under Kql/Graph/. Tab-completes from every folder that
        actually contains at least one .kql file. A typo isn't caught at parameter binding
        - it's caught a moment later when the file lookup fails with a clear path-not-found
        error.

    .PARAMETER Name
        KQL file base name (without extension). Defaults to 'All'. Tab-completes from the
        .kql files in the selected ResourceType folder.

    .PARAMETER SubscriptionId
        Restrict to specific subscriptions. Omit to query every accessible subscription.

    .PARAMETER CurrentSubscription
        Scope the query to just the active Az context's subscription - shorthand for
        -SubscriptionId (Get-AzContext).Subscription.Id. Mutually exclusive with
        -SubscriptionId. Handy when you want results that line up with the single
        subscription Invoke-MsecAzureVMScript will act on.

    .PARAMETER First
        Page size (1-1000). Default 1000, which is ARG's maximum per page. This is not a
        result limit - pages are followed until the query is exhausted. Use -MaxRows for
        a limit.

    .PARAMETER MaxRows
        Safety ceiling on total rows returned across all pages. Default 50000. Hitting it
        emits a warning and stops; results are never truncated silently.

    .PARAMETER UseCache
        Serve the previous result for this query from disk when it is younger than -MaxCacheAge,
        instead of calling Azure. Opt-in, and it stays opt-in: a stale security answer is
        indistinguishable from a fresh one at the point you read it.

        Every real call refreshes the cache regardless of this switch, so it is always warm. A
        result truncated by -MaxRows is never cached.

        The cache lives under %LOCALAPPDATA%\msec (~/.local/share/msec elsewhere), one file per
        query - 'graph-loganalytics-all.json' and so on - and MSEC_CACHE_DIR moves it. The
        subscription scope is not part of the cache key, so a scoped call overwrites the cached
        estate-wide result for the same query; the scope that produced a cached result is
        recorded in it and reported by -Verbose.

    .PARAMETER MaxCacheAge
        How old a cached result may be before -UseCache ignores it and queries Azure anyway.
        Default one hour. Ignored without -UseCache.

    .EXAMPLE
        Search-MsecAzureResourceGraph -ResourceType VM

    .EXAMPLE
        # Just the subscription you're currently working in - lines up with what
        # Invoke-MsecAzureVMScript will act on:
        Search-MsecAzureResourceGraph -ResourceType VM -CurrentSubscription

    .EXAMPLE
        Search-MsecAzureResourceGraph -ResourceType VM | Where-Object { $_.Os -eq 'Linux' -and $_.Running } |
            Invoke-MsecAzureVMScript -Os Linux -ScriptName os-info

    .EXAMPLE
        # Slow-moving reference data - reuse the last result for an hour rather than paying for
        # a round trip each time. This is how Search-MsecLogAnalytics resolves a workspace name.
        Search-MsecAzureResourceGraph -ResourceType LogAnalytics -UseCache

    .OUTPUTS
        PSCustomObject rows shaped by the .kql file's project clause.
    #>
    [CmdletBinding()]
    param(
        # Tab-completes from every folder under Kql/Graph that contains at least one
        # .kql file. File-driven, like the Name completer below.
        #
        # NB: the completer scriptblock runs in PowerShell's completion-engine context, NOT
        # in the module's session state. That means $script:MsecModuleRoot does NOT resolve
        # here even though it does inside the function body. We look up the module's base
        # path via Get-Module instead - it's a cheap dictionary lookup, not a load.
        [Parameter(Mandatory)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $base = (Get-Module msec).ModuleBase
            if (-not $base) { return }
            $graphFolder = Join-Path $base 'Kql/Graph'
            if (-not (Test-Path -LiteralPath $graphFolder)) { return }
            Get-ChildItem -LiteralPath $graphFolder -Filter *.kql -File -Recurse |
                ForEach-Object { Split-Path $_.Directory.FullName -Leaf } |
                Sort-Object -Unique |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new(
                        $_, $_, 'ParameterValue', $_)
                }
        })]
        [string] $ResourceType,

        # Tab-completes from the .kql files inside the currently-selected ResourceType folder.
        [Parameter()]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $rt = $fakeBoundParameters['ResourceType']
            if (-not $rt) { return }
            $base = (Get-Module msec).ModuleBase
            if (-not $base) { return }
            $folder = Join-Path $base "Kql/Graph/$rt"
            if (-not (Test-Path -LiteralPath $folder)) { return }
            Get-ChildItem -LiteralPath $folder -Filter *.kql -File |
                Where-Object { $_.BaseName -like "$wordToComplete*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new(
                        $_.BaseName, $_.BaseName, 'ParameterValue', $_.BaseName)
                }
        })]
        [string] $Name = 'All',

        [Parameter()]
        [string[]] $SubscriptionId,

        # Scope to just the active Az context's subscription - the easy alternative to
        # passing -SubscriptionId (Get-AzContext).Subscription.Id by hand. Mutually
        # exclusive with -SubscriptionId. Without either, every accessible subscription is
        # queried (the estate-wide default the bundled reports rely on).
        [Parameter()]
        [switch] $CurrentSubscription,

        [Parameter()]
        [ValidateRange(1, 1000)]
        [int] $First = 1000,

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $MaxRows = 50000,

        # Serve the previous result for this query from disk when it is younger than
        # -MaxCacheAge, instead of calling Azure.
        #
        # OPT-IN, AND IT STAYS OPT-IN. Every bundled query here answers a security question, and
        # a stale answer is indistinguishable from a fresh one at the point you read it - the
        # subscription that was added yesterday is simply absent, the vault that was opened to
        # the internet this morning still looks sealed. That is the failure mode this whole
        # module is written against, so the default is always a real call.
        #
        # A real call ALWAYS refreshes the cache, whether or not this switch was passed. That is
        # what keeps tab completion warm without anybody having to think about it.
        [Parameter()]
        [switch] $UseCache,

        # How old a cached result may be before -UseCache ignores it and calls Azure anyway.
        # Default one hour. Ignored without -UseCache.
        [Parameter()]
        [timespan] $MaxCacheAge = [timespan]::FromHours(1)
    )

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw 'No Azure context. Run Connect-AzAccount before Search-MsecAzureResourceGraph.'
    }

    $path = Join-Path $script:MsecModuleRoot "Kql/Graph/$ResourceType/$Name.kql"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "KQL query file not found: $path"
    }
    $query = Get-Content -LiteralPath $path -Raw

    $cacheName = Get-MsecGraphCacheName -ResourceType $ResourceType -Name $Name

    if ($UseCache) {
        $cached = Read-MsecCache -Name $cacheName -Envelope
        if ($cached -and $cached.UpdatedUtc) {
            $age = [DateTime]::UtcNow - [DateTime]::Parse($cached.UpdatedUtc, $null,
                        [System.Globalization.DateTimeStyles]::RoundtripKind)
            if ($age -le $MaxCacheAge) {
                Write-Verbose ("Serving $(@($cached.Items).Count) row(s) from cache " +
                    "($([int]$age.TotalMinutes) minute(s) old, scope: $($cached.Scope)). " +
                    'Pass -MaxCacheAge 0 or drop -UseCache to force a live query.')
                return @($cached.Items)
            }
            Write-Verbose "Cache for '$cacheName' is $([int]$age.TotalMinutes) minute(s) old, past -MaxCacheAge. Querying Azure."
        }
        else {
            Write-Verbose "No usable cache for '$cacheName'. Querying Azure."
        }
    }

    if ($CurrentSubscription -and $SubscriptionId) {
        throw 'Specify either -CurrentSubscription or -SubscriptionId, not both.'
    }

    # Resolve the subscription scope:
    #   -SubscriptionId      -> exactly those subs
    #   -CurrentSubscription -> just the active Az context's sub
    #   (neither)            -> EVERY accessible sub. Search-AzGraph's own default is only
    #                           the current context's sub, which is wrong for estate-wide
    #                           audits, so we enumerate up front and pass the explicit list.
    if ($CurrentSubscription) {
        $currentSub = (Get-AzContext).Subscription.Id
        if (-not $currentSub) {
            throw 'The active Az context has no subscription. Run Connect-AzAccount or Set-AzContext -SubscriptionId <id>.'
        }
        $SubscriptionId = @($currentSub)
        Write-Verbose "Scoping to current subscription: $currentSub"
    }
    elseif (-not $SubscriptionId) {
        # Get-MsecSubscriptionList rather than Get-AzSubscription: identical data, and it
        # refreshes the -SubscriptionId completion cache on the way past. Every estate-wide call
        # already pays for this enumeration, so completion costs nothing extra.
        $SubscriptionId = (Get-MsecSubscriptionList).Id
        Write-Verbose "Querying $($SubscriptionId.Count) accessible subscription(s): $($SubscriptionId -join ', ')"
    }

    Write-Verbose ("Search-AzGraph query (pages of $First rows, max $MaxRows):" + [Environment]::NewLine + $query)
    $azParams = @{ Query = $query; First = $First; ErrorAction = 'Stop' }
    if ($SubscriptionId) { $azParams['Subscription'] = $SubscriptionId }

    $emitted   = 0
    $page      = 0
    $skipToken = $null
    # Rows are still emitted one at a time so the pipeline stays streaming; this second
    # reference exists only so the completed result can be cached. It costs memory, not latency.
    $collected = [System.Collections.Generic.List[object]]::new()

    do {
        if ($skipToken) { $azParams['SkipToken'] = $skipToken }
        $response = Search-AzGraph @azParams
        $page++

        # Search-AzGraph's output shape varies by Az.ResourceGraph version:
        #   - Some versions emit the rows directly.
        #   - Others emit a single wrapper object with .SkipToken + .Data (array of rows).
        # Unwrap .Data when present.
        $rows = if ($null -ne $response -and $response.PSObject.Properties['Data']) {
            $response.Data
        }
        else {
            $response
        }

        # Only the wrapper shape can paginate. When rows come back bare there is no token to
        # follow, so this stays a single pass - which is also what test mocks returning a
        # plain array produce, keeping them one-shot.
        $skipToken = if ($null -ne $response -and $response.PSObject.Properties['SkipToken']) {
            $response.SkipToken
        }
        else {
            $null
        }

        # Materialize each row as a flat PSCustomObject so downstream Where-Object /
        # Select-Object / tab completion see the projected columns as real note properties.
        foreach ($r in @($rows)) {
            if ($null -eq $r) { continue }
            if ($emitted -ge $MaxRows) {
                Write-Warning ("Stopped at -MaxRows ($MaxRows) with more results available. " +
                    'Results are INCOMPLETE - raise -MaxRows, or narrow with -SubscriptionId.')
                # Deliberately NOT cached. A truncated result written to the cache would be
                # served later by -UseCache as though it were the whole answer, turning a loud
                # one-off warning into a silent permanent undercount.
                return
            }
            $obj = [pscustomobject]$(
                $ordered = [ordered]@{}
                foreach ($prop in $r.PSObject.Properties) { $ordered[$prop.Name] = $prop.Value }
                $ordered
            )
            $collected.Add($obj)
            $obj
            $emitted++
        }
    } while ($skipToken)

    # Refresh the cache on every real call, whether or not -UseCache was passed: that is what
    # keeps tab completion warm without a priming step. Best effort - Save-MsecCache never throws.
    Save-MsecCache -Name $cacheName -Item $collected.ToArray() -Metadata @{
        Scope = if ($SubscriptionId) { ($SubscriptionId -join ', ') } else { 'all accessible subscriptions' }
    }

    Write-Verbose "Returned $emitted row(s) across $page page(s)."
}
