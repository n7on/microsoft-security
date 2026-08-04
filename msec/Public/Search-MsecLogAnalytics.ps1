function Search-MsecLogAnalytics {
    <#
    .SYNOPSIS
        Runs a bundled KQL query against a Log Analytics workspace and returns the rows.

    .DESCRIPTION
        The Log Analytics counterpart to Search-MsecAzureResourceGraph. Same idea, same
        file-on-disk convention, different engine - and the differences matter, so read the
        four NB sections below before writing a .kql for this.

        The query is loaded by convention from:

            msec/Kql/Law/<Subject>/<Name>.kql

        For example, Search-MsecLogAnalytics -Subject Waf loads Kql/Law/Waf/All.kql. Each
        subject folder has at least an All.kql; named variants (e.g. "TopRules.kql") live
        alongside it and are selected via -Name.

        SUBJECT, NOT RESOURCE TYPE. Resource Graph keys its folders on the ARM resource type
        because every row genuinely has one. Log Analytics rows do not: SigninLogs is about
        identities and AuditLogs about directory changes, neither of which is an ARM resource.
        So the first level here is the SUBJECT the rows are about. Where a subject also exists
        under Kql/Graph the folder name is deliberately the same, so the two trees line up -
        Graph/Waf tells you which managed rules are switched off, Law/Waf tells you which ones
        actually fired.

        Keying on the TABLE was the obvious alternative and it does not survive contact with
        reality: AzureDiagnostics is one table holding App Gateway, Key Vault and a dozen other
        resource types' logs, and the same App Gateway data lands either there or in
        AGWFirewallLogs depending on one per-resource diagnostic setting. A folder key that
        flips based on a diagnostic setting is not a key.

        Required: Az.OperationalInsights, Az.ResourceGraph, an Az context, and Log Analytics
        Reader on the workspace.

    .PARAMETER Subject
        The subject folder under Kql/Law/. Tab-completes from every folder that actually
        contains at least one .kql file.

    .PARAMETER Name
        KQL file base name (without extension). Defaults to 'All'. Tab-completes from the .kql
        files in the selected Subject folder.

    .PARAMETER WorkspaceName
        The workspace to query. MANDATORY and deliberately so - see the NB on workspace scope.
        Resolved by name through Resource Graph across every accessible subscription, so you do
        not need to know which subscription or resource group it lives in. A name that matches
        nothing, or matches more than one workspace, fails with the list of candidates rather
        than picking one.

        Tab-completes from a local cache, never from a live query - see the comment on the
        parameter. Any call refreshes it; on a fresh machine prime it with
        Search-MsecAzureResourceGraph -ResourceType LogAnalytics.

    .PARAMETER ResourceGroupName
        Disambiguates when the same workspace name exists in more than one resource group.

    .PARAMETER SubscriptionId
        Disambiguates when the same workspace name exists in more than one subscription.

    .PARAMETER Days
        Time window, passed to the API as a server-side timespan. Default 7. The .kql files do
        NOT carry their own time filter - see the NB below.

    .PARAMETER MaxRows
        Safety ceiling on rows returned. Default 50000. Hitting it emits a warning and stops;
        results are never truncated silently.

    .EXAMPLE
        Search-MsecLogAnalytics -Subject Waf -Name TopRules -WorkspaceName prod-sentinel-log

    .EXAMPLE
        # Which WAF rules actually fire, against which rules are switched off:
        $fired    = Search-MsecLogAnalytics -Subject Waf -Name TopRules -WorkspaceName prod-sentinel-log -Days 30
        $disabled = Search-MsecAzureResourceGraph -ResourceType Waf -Name ManagedRules |
                        Where-Object Disabled
        $fired | Where-Object { $_.RuleId -in $disabled.RuleId }   # firing despite being disabled

    .EXAMPLE
        # Discover workspace names to pass to -WorkspaceName, and prime tab completion:
        Search-MsecAzureResourceGraph -ResourceType LogAnalytics |
            Select-Object Name, SubscriptionName, Location, RetentionDays

    .OUTPUTS
        PSCustomObject rows shaped by the .kql file's project or summarize clause.

    .NOTES
        NB - WORKSPACE SCOPE. Search-MsecAzureResourceGraph defaults to every accessible
        subscription because Resource Graph is genuinely tenant-wide. Log Analytics is not:
        data lives in whichever workspace the diagnostic setting pointed at, and a mid-sized
        estate has dozens of workspaces sharded by region and purpose. Defaulting to a fan-out
        would mean most queries fail against most workspaces, because a table that does not
        exist in a workspace is a hard query error rather than an empty result. So the
        workspace is mandatory and explicit. Nothing is ever queried that you did not name.

        NB - TIME IS A PARAMETER, NOT PART OF THE QUERY. -Days is passed to the API as a
        timespan, which the service applies server-side against the TimeGenerated index. The
        .kql files therefore contain NO `where TimeGenerated > ago(...)` clause. This is the
        same separation as Search-MsecAzureResourceGraph doing no filtering in KQL: a window
        baked into the file is invisible at the call site and cannot be widened without
        editing the file.

        NB - NO PAGINATION. Resource Graph hands out a skip token and this module follows it
        until the result set is exhausted. The Log Analytics query API has no equivalent: it
        caps a response at 500,000 rows / 64 MB and there is no continuation token, so you
        page by narrowing -Days. That is why the bundled .kql files summarize server-side
        wherever the raw grain would be large - Application Gateway alone writes millions of
        access-log rows a day, and pulling those through PowerShell to filter them is not a
        plan. A response that comes back exactly at the cap is warned about, loudly, because a
        truncated security query looks exactly like a clean one.

        NB - VALUES ARRIVE AS STRINGS. The query API is untyped on the wire and
        Invoke-AzOperationalInsightsQuery surfaces every column as a string. A column that is
        a number in KQL sorts lexically in PowerShell unless you cast it - '9' sorts after
        '10'. Cast at the call site: Sort-Object { [int]$_.Hits } -Descending.
    #>
    [CmdletBinding()]
    param(
        # Tab-completes from every folder under Kql/Law that contains at least one .kql file.
        #
        # NB: the completer scriptblock runs in PowerShell's completion-engine context, NOT in
        # the module's session state, so $script:MsecModuleRoot does NOT resolve here even
        # though it does inside the function body. Look the base path up via Get-Module - a
        # cheap dictionary lookup, not a load. Same trap as Search-MsecAzureResourceGraph.
        [Parameter(Mandatory)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $base = (Get-Module msec).ModuleBase
            if (-not $base) { return }
            $lawFolder = Join-Path $base 'Kql/Law'
            if (-not (Test-Path -LiteralPath $lawFolder)) { return }
            Get-ChildItem -LiteralPath $lawFolder -Filter *.kql -File -Recurse |
                ForEach-Object { Split-Path $_.Directory.FullName -Leaf } |
                Sort-Object -Unique |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new(
                        $_, $_, 'ParameterValue', $_)
                }
        })]
        [string] $Subject,

        # Tab-completes from the .kql files inside the currently-selected Subject folder.
        [Parameter()]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $subject = $fakeBoundParameters['Subject']
            if (-not $subject) { return }
            $base = (Get-Module msec).ModuleBase
            if (-not $base) { return }
            $folder = Join-Path $base "Kql/Law/$subject"
            if (-not (Test-Path -LiteralPath $folder)) { return }
            Get-ChildItem -LiteralPath $folder -Filter *.kql -File |
                Where-Object { $_.BaseName -like "$wordToComplete*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new(
                        $_.BaseName, $_.BaseName, 'ParameterValue', $_.BaseName)
                }
        })]
        [string] $Name = 'All',

        # Tab-completes from the cached result of Kql/Graph/LogAnalytics/All.kql - NEVER from a
        # live query. Resolving workspace names means a Resource Graph round trip, and a
        # completer that calls Azure blocks the prompt on every Tab; worse, when ARM is
        # unhealthy it does not fail fast, it hangs. Reading a small JSON file cannot do that.
        #
        # Every Search-MsecLogAnalytics call refreshes that cache on its way to resolving the
        # workspace - including one that fails on an unknown name - so normal use keeps it warm.
        # On a fresh machine, prime it with:
        #   Search-MsecAzureResourceGraph -ResourceType LogAnalytics
        #
        # NB: same session-state trap as the completers above - this scriptblock runs in the
        # completion engine, NOT in the module, so Get-MsecWorkspaceCachePath is not directly
        # callable. Invoking the scriptblock against the module object (& $module { ... }) runs
        # it in module scope, where private functions do resolve.
        [Parameter(Mandatory)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            try {
                $module = Get-Module msec
                if (-not $module) { return }
                & $module { Read-MsecCache -Name (Get-MsecGraphCacheName -ResourceType 'LogAnalytics' -Name 'All') } |
                    Where-Object { $_.Name -like "$wordToComplete*" } |
                    # One entry per NAME. A name that exists in two subscriptions is offered
                    # once; picking it then fails with the ambiguity error, which is the honest
                    # outcome - the completer must not choose a subscription on your behalf.
                    Sort-Object Name -Unique |
                    ForEach-Object {
                        [System.Management.Automation.CompletionResult]::new(
                            $_.Name, $_.Name, 'ParameterValue',
                            "$($_.Name) - rg=$($_.ResourceGroupName), $($_.Location)")
                    }
            }
            catch {
                # A completer must never throw or the prompt breaks. A corrupt or half-written
                # cache file just means no suggestions.
            }
        })]
        [string] $WorkspaceName,

        [Parameter()]
        [string] $ResourceGroupName,

        [Parameter()]
        [string] $SubscriptionId,

        [Parameter()]
        [ValidateRange(1, 365)]
        [int] $Days = 7,

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $MaxRows = 50000
    )

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw 'No Azure context. Run Connect-AzAccount before Search-MsecLogAnalytics.'
    }

    $path = Join-Path $script:MsecModuleRoot "Kql/Law/$Subject/$Name.kql"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "KQL query file not found: $path"
    }
    $query = Get-Content -LiteralPath $path -Raw

    # Resolve the workspace through the bundled Kql/Graph/LogAnalytics/All.kql query, run by
    # Search-MsecAzureResourceGraph. Not Get-AzOperationalInsightsWorkspace, which needs the
    # resource group AND the right subscription context up front - Resource Graph searches every
    # accessible subscription at once, which is the difference between "prod-sentinel-log" and
    # "prod-sentinel-log, in this resource group, in that subscription, after Set-AzContext".
    #
    # Going through the ordinary cmdlet rather than a private helper means one way of asking
    # Azure a question, one cache, one set of tests. -UseCache is what makes repeated calls cheap
    # (workspaces change rarely, and the default hour is generous for a list of them), and the
    # same call keeps the -WorkspaceName completion cache warm.
    #
    # It happens BEFORE the name is matched on purpose: a first attempt with a name you
    # half-remembered still teaches the completer every workspace in the estate, so the retry can
    # be tab-completed.
    $listParams = @{ ResourceType = 'LogAnalytics'; UseCache = $true }
    if ($SubscriptionId) { $listParams['SubscriptionId'] = @($SubscriptionId) }
    $workspaces = @(Search-MsecAzureResourceGraph @listParams)

    $matched = @($workspaces | Where-Object { $_.Name -eq $WorkspaceName })
    if ($ResourceGroupName) { $matched = @($matched | Where-Object { $_.ResourceGroupName -eq $ResourceGroupName }) }

    if ($matched.Count -eq 0) {
        # Listing the candidates is the whole point - with dozens of workspaces, "not found" on
        # its own sends you to the portal.
        $available = ($workspaces | Sort-Object Name | ForEach-Object { $_.Name }) -join ', '
        throw "Log Analytics workspace '$WorkspaceName' not found in any accessible subscription. Available: $available"
    }
    if ($matched.Count -gt 1) {
        $where = ($matched | ForEach-Object { "$($_.Name) (rg=$($_.ResourceGroupName), sub=$($_.SubscriptionId))" }) -join '; '
        throw ("Workspace name '$WorkspaceName' is ambiguous - $($matched.Count) matches: $where. " +
               'Narrow it with -ResourceGroupName or -SubscriptionId.')
    }

    $workspace = $matched[0]
    if (-not $workspace.CustomerId) {
        throw "Workspace '$WorkspaceName' has no customerId - it may still be provisioning."
    }

    Write-Verbose ("Workspace $($workspace.Name) (rg=$($workspace.ResourceGroupName), " +
                   "id=$($workspace.CustomerId)), last $Days day(s):" + [Environment]::NewLine + $query)

    $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId `
                                                -Query $query `
                                                -Timespan (New-TimeSpan -Days $Days) `
                                                -ErrorAction Stop

    $rows = @($result.Results)

    # The API stops at 500,000 rows with no continuation token. Landing exactly on it means the
    # result is almost certainly cut short, and there is no way to ask for the rest - the fix is
    # a smaller -Days or a summarizing query, so say so rather than returning a plausible lie.
    if ($rows.Count -ge 500000) {
        Write-Warning ('Hit the Log Analytics 500,000-row response cap. Results are INCOMPLETE and ' +
            'the API offers no continuation token - narrow -Days, or use a -Name variant that ' +
            'summarizes server-side.')
    }

    $emitted = 0
    foreach ($r in $rows) {
        if ($null -eq $r) { continue }
        if ($emitted -ge $MaxRows) {
            Write-Warning ("Stopped at -MaxRows ($MaxRows) with more results available. " +
                'Results are INCOMPLETE - raise -MaxRows, or narrow -Days.')
            return
        }
        # Materialize as a flat PSCustomObject so downstream Where-Object / Select-Object and
        # tab completion see the projected columns as real note properties.
        $obj = [ordered]@{}
        foreach ($prop in $r.PSObject.Properties) {
            $obj[$prop.Name] = $prop.Value
        }
        # Which workspace a row came from is not in the row. With a sharded estate you will be
        # comparing results across workspaces within the hour, and by then it is too late to
        # remember which run produced what.
        $obj['Workspace'] = $workspace.Name
        [pscustomobject]$obj
        $emitted++
    }

    Write-Verbose "Returned $emitted row(s) from $($workspace.Name)."
}
