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

    .PARAMETER Subscription
        Restrict to specific subscriptions, by NAME or id - 'PROD' rather than a GUID. Names are
        not unique (this estate has three called 'Cloud Subscription'), so an ambiguous name
        fails with the candidate ids rather than picking one. Omit to query every accessible
        subscription. Aliased to -SubscriptionId for anything already written against that name.

    .PARAMETER CurrentSubscription
        Scope the query to just the active Az context's subscription - shorthand for
        -Subscription (Get-AzContext).Subscription.Id. Mutually exclusive with
        -Subscription. Handy when you want results that line up with the single
        subscription Invoke-MsecAzureVMScript will act on.

    .PARAMETER First
        Page size (1-1000). Default 1000, which is ARG's maximum per page. This is not a
        result limit - pages are followed until the query is exhausted. Use -MaxRows for
        a limit.

    .PARAMETER MaxRows
        Safety ceiling on total rows returned across all pages. Default 50000. Hitting it
        emits a warning and stops; results are never truncated silently.

    .PARAMETER NoCache
        Query Azure instead of reusing a recent result. The result still refreshes the cache.

        Results are cached and reused BY DEFAULT, because Azure resource inventory changes on the
        timescale of deployments rather than seconds. A cached result is only reused when it was
        written under the SAME tenant, for the SAME subscription scope, and within the cache
        window (15 minutes) - a scoped result is never handed back to an unscoped call, which
        would report a fraction of the estate as all of it. A result truncated by -MaxRows is
        never cached.

        Use -NoCache when you have just changed something and are checking whether the change
        took: that is the one case where minutes-old data actively misleads.

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
        # You just closed a vault firewall and want to confirm it - do not trust a cached answer:
        Search-MsecAzureResourceGraph -ResourceType KeyVault -NoCache |
            Where-Object NetworkExposure -eq 'OpenToAllNetworks'

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

        # Names or ids, or a mix. 'PROD' beats a GUID at the call site and in a script anyone
        # has to read later; the id still works because subscription names are not unique.
        [Parameter()]
        [Alias('SubscriptionId')]
        [string[]] $Subscription,

        # Scope to just the active Az context's subscription - the easy alternative to
        # passing -Subscription (Get-AzContext).Subscription.Id by hand. Mutually
        # exclusive with -Subscription. Without either, every accessible subscription is
        # queried (the estate-wide default the bundled reports rely on).
        [Parameter()]
        [switch] $CurrentSubscription,

        [Parameter()]
        [ValidateRange(1, 1000)]
        [int] $First = 1000,

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $MaxRows = 50000,

        # Skip the cache and query Azure. The result still refreshes the cache.
        [Parameter()]
        [switch] $NoCache
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

    if ($CurrentSubscription -and $Subscription) {
        throw 'Specify either -CurrentSubscription or -Subscription, not both.'
    }

    # A LABEL for the scope, worked out before anything is resolved or enumerated. It is what
    # makes a cached result safe to reuse: a run scoped to one subscription must never be handed
    # back to an unscoped run, which would silently report a fraction of the estate as all of it.
    # Deriving it from the raw arguments also means a cache hit skips subscription enumeration
    # entirely - the slowest and least reliable part of an unscoped call.
    #
    # Two spellings of the same scope ('PROD' and its GUID) produce different labels and so miss
    # each other. That is the conservative direction: a needless refetch, never a wrong answer.
    $scopeLabel = if ($CurrentSubscription) { "current:$((Get-AzContext).Subscription.Id)" }
                  elseif ($Subscription)    { 'subs:' + (($Subscription | Sort-Object) -join ',') }
                  else                      { 'all' }

    if (-not $NoCache) {
        $cached = Read-MsecCache -Name $cacheName -Envelope
        if ($cached -and $cached.Scope -eq $scopeLabel -and $cached.UpdatedUtc) {
            $age = [DateTime]::UtcNow - [DateTime]::Parse($cached.UpdatedUtc, $null,
                        [System.Globalization.DateTimeStyles]::RoundtripKind)
            if ($age -le $script:MsecGraphCacheMaxAge) {
                Write-Verbose ("Serving $(@($cached.Items).Count) row(s) from cache " +
                    "($([int]$age.TotalMinutes) minute(s) old, scope '$scopeLabel'). Use -NoCache to force a live query.")
                return @($cached.Items)
            }
            Write-Verbose "Cache for '$cacheName' is $([int]$age.TotalMinutes) minute(s) old. Querying Azure."
        }
    }

    # Resolve the subscription scope:
    #   -Subscription        -> exactly those subs, by name or id
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
    elseif ($Subscription) {
        $SubscriptionId = @(Resolve-MsecSubscription -Subscription $Subscription)
        Write-Verbose "Scoped to $($SubscriptionId.Count) subscription(s): $($SubscriptionId -join ', ')"
    }
    else {
        # Get-MsecSubscriptionList rather than Get-AzSubscription: identical data, and it
        # refreshes the -Subscription completion cache on the way past. Every estate-wide call
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
                    'Results are INCOMPLETE - raise -MaxRows, or narrow with -Subscription.')
                # Deliberately NOT cached. A truncated result written to the cache would be
                # read back later as though it were the whole answer, turning a loud one-off
                # warning into a silently truncated completion list.
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

    # Refresh the cache on every call. It is read back only by tab completion and by
    # Search-MsecLogAnalytics resolving a workspace name - this cmdlet itself always queries
    # Azure, because a stale security answer is indistinguishable from a fresh one. Best effort:
    # Save-MsecCache never throws.
    Save-MsecCache -Name $cacheName -Item $collected.ToArray() -Metadata @{
        Scope        = $scopeLabel
        ScopeDetail  = if ($SubscriptionId) { ($SubscriptionId -join ', ') } else { 'all accessible subscriptions' }
    }

    Write-Verbose "Returned $emitted row(s) across $page page(s)."
}
