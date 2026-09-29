function Search-MsecDefenderHunting {
    <#
    .SYNOPSIS
        Runs a bundled advanced hunting KQL query against the Defender XDR event store.

    .DESCRIPTION
        The third of the three search commands, and the one people reach for by mistake. Each
        searches a DIFFERENT store, and no amount of KQL moves a question from one to another:

            Search-MsecDefenderHunting     what a device, user or mailbox DID     ~30 days
            Search-MsecAzureResourceGraph  how an Azure resource is CONFIGURED    current state
            Search-MsecLogAnalytics        what a service LOGGED to a workspace   your retention

        Advanced hunting reads Defender XDR's own event lake, holding roughly thirty days of
        raw telemetry written directly by the onboarded Defender workloads. It is NOT a Log
        Analytics workspace: nothing you route with a diagnostic setting appears here, and
        nothing here reaches a workspace unless the Sentinel connector is wired up. Entra
        Domain Services audit logs, for one, will never show up - those are Search-MsecLogAnalytics.

        WHICH TABLES EXIST DEPENDS ENTIRELY ON WHAT IS ONBOARDED. A table belonging to a product
        you do not run is not empty, it fails to resolve, and the error says so rather than
        returning nothing - a query that answers "0 rows" for "this product is not installed"
        is the worst outcome here. Measured on one tenant: Device* and Email* tables full,
        AADSignInEventsBeta carrying 2.4M sign-ins, and every Identity* table at zero because
        Defender for Identity has no sensors on a managed domain.

        THE .kql FILES CARRY NO TIME FILTER. The window goes to the API as its own timespan
        parameter, the same split Search-MsecLogAnalytics uses, so one file serves every window
        and there is no `ago()` to forget to update. Verified against a live tenant: the same
        query returns 12 / 57 / 2245 / 6544 rows at PT1H / P1D / P7D / P30D.

        SOME TABLES IGNORE THE WINDOW, AND CANNOT DO OTHERWISE. DeviceTvmSoftwareVulnerabilities
        and the other DeviceTvm* tables are current-state snapshots with no Timestamp column at
        all, so -Days on Vulnerability changes nothing. That is a property of the table, not a
        bug here, and the .kql says so at the top.

    .PARAMETER Subject
        The folder under kql/Hunting/. Tab-completes from the folders that actually hold a .kql.

    .PARAMETER Name
        KQL file base name. Defaults to 'All'. Tab-completes from the chosen -Subject.

    .PARAMETER Days
        Window, 1-30. Defaults to 7. Advanced hunting keeps about thirty days, so 30 is the
        ceiling rather than an arbitrary cap.

    .PARAMETER Timespan
        Sub-day windows, e.g. -Timespan 04:00:00. A BARE INTEGER IS READ AS TICKS - -Timespan 7
        means 700 nanoseconds, not seven days - so anything under a minute is refused with a
        message pointing at -Days.

    .PARAMETER Query
        Run literal KQL instead of a bundled file, for one-off hunting. Mutually exclusive with
        -Subject.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Search-MsecDefenderHunting -Subject SignIn -Name Failed -Days 1 |
            Sort-Object { [int]$_.Failures } -Descending | Select-Object -First 20

        Failed Entra sign-ins in the last day, worst first. Note the cast - Failures arrives as
        a string, and '9' sorts after '10' without it.

    .EXAMPLE
        Search-MsecDefenderHunting -Query 'DeviceLogonEvents | where IsLocalAdmin == true | take 50' -Days 7

    .OUTPUTS
        PSCustomObject rows shaped by the query's own project or summarize clause.

    .NOTES
        Needs the 'ThreatHunting.Read.All' application permission, which New-MsecApp consents.
        Runs as the app, read-only.

        EVERY VALUE COMES BACK AS A STRING. The hunting API returns JSON without types, so a
        count is '1234' and a boolean is 'false' - and 'false' is TRUTHY in PowerShell. Cast
        before comparing or sorting; see the example.
    #>
    [CmdletBinding(DefaultParameterSetName = 'File')]
    [OutputType([PSCustomObject])]
    param(
        # Tab-completes from every folder under kql/Hunting holding at least one .kql.
        #
        # NB the completer runs in the completion engine's session state, NOT the module's, so
        # $script:MsecModuleRoot does not resolve here. Look the base up via Get-Module - the
        # same trap documented in Search-MsecLogAnalytics.
        [Parameter(Mandatory, ParameterSetName = 'File')]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $base = (Get-Module msec).ModuleBase
            if (-not $base) { return }
            $folder = Join-Path $base 'kql/Hunting'
            if (-not (Test-Path -LiteralPath $folder)) { return }
            Get-ChildItem -LiteralPath $folder -Filter *.kql -File -Recurse |
                ForEach-Object { Split-Path $_.Directory.FullName -Leaf } |
                Sort-Object -Unique |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
                }
        })]
        [string] $Subject,

        [Parameter(ParameterSetName = 'File')]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $subject = $fakeBoundParameters['Subject']
            if (-not $subject) { return }
            $base = (Get-Module msec).ModuleBase
            if (-not $base) { return }
            $folder = Join-Path $base "kql/Hunting/$subject"
            if (-not (Test-Path -LiteralPath $folder)) { return }
            Get-ChildItem -LiteralPath $folder -Filter *.kql -File |
                Where-Object { $_.BaseName -like "$wordToComplete*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new(
                        $_.BaseName, $_.BaseName, 'ParameterValue', $_.BaseName)
                }
        })]
        [string] $Name = 'All',

        [Parameter(Mandatory, ParameterSetName = 'Query')]
        [ValidateNotNullOrEmpty()]
        [string] $Query,

        # 30 is the store's retention, not an arbitrary limit.
        [Parameter()]
        [ValidateRange(1, 30)]
        [int] $Days = 7,

        [Parameter()]
        [ValidateScript({
            if ($_ -lt [timespan]::FromMinutes(1)) {
                throw ("-Timespan $_ is under a minute. A bare integer is read as TICKS - " +
                       '-Timespan 7 means 700ns, not 7 days. Use -Days 7, or -Timespan 04:00:00.')
            }
            if ($_ -gt [timespan]::FromDays(30)) {
                throw "-Timespan $_ exceeds the 30 day advanced hunting retention."
            }
            $true
        })]
        [timespan] $Timespan
    )

    Assert-MsecSession

    if ($PSCmdlet.ParameterSetName -eq 'File') {
        $path = Join-Path $script:MsecModuleRoot "kql/Hunting/$Subject/$Name.kql"
        if (-not (Test-Path -LiteralPath $path)) {
            throw "KQL query file not found: $path"
        }
        $kql = Get-Content -LiteralPath $path -Raw
    }
    else {
        $kql = $Query
    }

    $window = if ($PSBoundParameters.ContainsKey('Timespan')) { $Timespan } else { [timespan]::FromDays($Days) }

    # ISO 8601 duration, which is what the API takes. Whole days stay as P<n>D so the common
    # case reads back as it was asked for; anything else goes as hours/minutes.
    $iso = if ($window.TotalDays -ge 1 -and $window.TotalDays -eq [Math]::Floor($window.TotalDays)) {
        "P$([int]$window.TotalDays)D"
    }
    else {
        'PT{0}H{1}M' -f [int]$window.TotalHours, $window.Minutes
    }

    Write-Verbose "Running advanced hunting query over $iso."

    try {
        $response = Invoke-MsecGraphRequest -Path '/v1.0/security/runHuntingQuery' -Method POST `
                        -Body @{ Query = $kql; Timespan = $iso }
    }
    catch {
        $detail = Get-MsecGraphErrorMessage $_

        # A table that belongs to a product the tenant does not run fails to resolve. Saying so
        # is the whole point - returning nothing would read as "checked, found none".
        if ($detail -match "[Ff]ailed to resolve table or column expression named '([^']+)'") {
            throw ("Advanced hunting has no table '$($Matches[1])' in this tenant. That usually means the " +
                   'product writing it is not onboarded or not licensed, rather than that the name is wrong - ' +
                   "the Identity* tables are absent without Defender for Identity sensors, CloudAppEvents " +
                   "without Defender for Cloud Apps. Original error: $detail")
        }
        if ($detail -match 'Forbidden|403') {
            throw ("Forbidden when calling /security/runHuntingQuery. The msec app needs the " +
                   "'ThreatHunting.Read.All' application permission with admin consent. Original error: $detail")
        }
        throw $detail
    }

    foreach ($row in @($response.results)) {
        # Hashtable from the API; surfaced as an object so the rows behave like every other
        # msec command's output. Values stay strings - see the note in the help.
        [PSCustomObject] $row
    }
}
