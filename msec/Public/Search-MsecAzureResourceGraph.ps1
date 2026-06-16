function Search-MsecAzureResourceGraph {
    <#
    .SYNOPSIS
        Runs a bundled KQL query against Azure Resource Graph and returns the rows.

    .DESCRIPTION
        The query is loaded by convention from:

            msec/KQL/Graph/<ResourceType>/<Name>.kql

        For example, Search-MsecAzureResourceGraph -ResourceType VM loads KQL/Graph/VM/All.kql. Each
        resource-type folder has at least an All.kql; named variants (e.g. "Running.kql")
        live alongside it and are selected via -Name.

        Filtering is intentionally NOT done here - that's what PowerShell pipelines are
        for. Pipe the output into Where-Object / Sort-Object / Select-Object:

            Search-MsecAzureResourceGraph -ResourceType VM | Where-Object Os -eq 'Linux' | ...

        Required: Az.ResourceGraph, an Az context, and Reader RBAC at the resources'
        scope (ARG honours RBAC and just omits resources you cannot see).

        Pagination: single page only, up to 1000 rows (-First). Most tenants have well
        under 1000 of any one resource type. If you do hit the cap, narrow with
        -SubscriptionId.

    .PARAMETER ResourceType
        The resource-type folder under KQL/Graph/. Tab-completes from every folder that
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
        Page size (1-1000). Default 1000.

    .EXAMPLE
        Search-MsecAzureResourceGraph -ResourceType VM

    .EXAMPLE
        # Just the subscription you're currently working in - lines up with what
        # Invoke-MsecAzureVMScript will act on:
        Search-MsecAzureResourceGraph -ResourceType VM -CurrentSubscription

    .EXAMPLE
        Search-MsecAzureResourceGraph -ResourceType VM | Where-Object { $_.Os -eq 'Linux' -and $_.Running } |
            Invoke-MsecAzureVMScript -Os Linux -ScriptName os-info

    .OUTPUTS
        PSCustomObject rows shaped by the .kql file's project clause.
    #>
    [CmdletBinding()]
    param(
        # Tab-completes from every folder under KQL/Graph that contains at least one
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
            $graphFolder = Join-Path $base 'KQL/Graph'
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
            $folder = Join-Path $base "KQL/Graph/$rt"
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
        [int] $First = 1000
    )

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw 'No Azure context. Run Connect-AzAccount before Search-MsecAzureResourceGraph.'
    }

    $path = Join-Path $script:MsecModuleRoot "KQL/Graph/$ResourceType/$Name.kql"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "KQL query file not found: $path"
    }
    $query = Get-Content -LiteralPath $path -Raw

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
        $SubscriptionId = (Get-AzSubscription -ErrorAction Stop).Id
        Write-Verbose "Querying $($SubscriptionId.Count) accessible subscription(s): $($SubscriptionId -join ', ')"
    }

    Write-Verbose ("Search-AzGraph query (first $First rows):" + [Environment]::NewLine + $query)
    $azParams = @{ Query = $query; First = $First; ErrorAction = 'Stop' }
    if ($SubscriptionId) { $azParams['Subscription'] = $SubscriptionId }

    # Search-AzGraph's output shape varies by Az.ResourceGraph version:
    #   - Some versions emit the rows directly.
    #   - Others emit a single wrapper object with .SkipToken + .Data (array of rows).
    # Unwrap .Data when present.
    $response = Search-AzGraph @azParams
    $rows = if ($null -ne $response -and $response.PSObject.Properties['Data']) {
        $response.Data
    }
    else {
        $response
    }

    # Materialize each row as a flat PSCustomObject so downstream Where-Object /
    # Select-Object / tab completion see the projected columns as real note properties.
    foreach ($r in @($rows)) {
        if ($null -eq $r) { continue }
        $obj = [ordered]@{}
        foreach ($prop in $r.PSObject.Properties) {
            $obj[$prop.Name] = $prop.Value
        }
        [pscustomobject]$obj
    }
}
