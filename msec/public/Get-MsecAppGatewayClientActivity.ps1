function Get-MsecAppGatewayClientActivity {
    <#
    .SYNOPSIS
        Everything one or more client IP addresses did through an Application Gateway - the
        request timeline where it exists, the hourly summary where it does not, and whether the
        address ever completed an authentication.

    .DESCRIPTION
        The pivot for "this address appeared in a report - what did it actually do". Written
        because answering it by hand means knowing which of three tables holds the answer for
        which part of the window, and reading an OpenID Connect exchange off raw HTTP.

        REACHING A LOGIN PAGE IS NOT LOGGING IN. A gateway access log has no usernames and no
        authentication result, so a 200 on a login page says only that a page was rendered -
        crawlers and scanners produce those in volume. Authentication is inferred from the two
        points a client cannot reach unless the identity provider has already authenticated it:

            POST /signin-oidc                 the application accepts an identity token
            GET  /connect/authorize/callback  the authorization code is exchanged

        Authenticated is $true only on those. Treating a login-page 200 as a sign-in turns every
        search engine into an intruder, which is the mistake this command exists to prevent.

        THE PER-REQUEST LOG AND THE SUMMARY ARE NOT INTERCHANGEABLE, so Grain says which a row
        came from. AzureDiagnostics holds one row per request with method, URI and status. A
        gateway switched to resource-specific logging writes AGWAccessLogs instead - which on the
        Basic or Auxiliary plan cannot be read by KQL at all, so the only thing left for that
        period is the hourly summary, which has client IP and a status class but NO HTTP method
        and NO full URI. Authentication therefore cannot be determined from summary-only
        periods, and those rows carry Authenticated = $null rather than $false: unknown is not
        the same as "did not".

        THE WINDOW CAN CHANGE GRAIN PART-WAY THROUGH, which is why both are returned together
        rather than picking one. An address whose detail stops on a particular day was not
        necessarily quiet from then on - the logging mode changed underneath it.

    .PARAMETER ClientIp
        One or more client addresses. Validated as IPv4 or IPv6 before anything is sent: an
        address with a stray space or a CIDR suffix silently matches nothing, which is
        indistinguishable from a quiet address.

    .PARAMETER WorkspaceName
        Log Analytics workspace holding the gateway logs. Resolved by name across every
        accessible subscription.

    .PARAMETER ResourceGroupName
        Narrows the workspace lookup when a name is ambiguous.

    .PARAMETER Days
        How far back to look. Default 7.

    .PARAMETER SummaryOnly
        Return one row per address instead of the request timeline - totals, hosts, whether it
        authenticated and when.

    .EXAMPLE
        Get-MsecAppGatewayClientActivity -ClientIp 79.137.138.24 -WorkspaceName prod-sentinel-log -Days 14

        Every request from one address, oldest first.

    .EXAMPLE
        Get-MsecAppGatewayClientActivity -ClientIp 213.79.68.227, 91.78.130.139 `
            -WorkspaceName prod-sentinel-log -Days 14 -SummaryOnly

        Several addresses at a glance - did they authenticate, and how much did they do afterwards.

    .EXAMPLE
        Get-MsecAppGatewayClientActivity -ClientIp 1.2.3.4 -WorkspaceName prod-sentinel-log |
            Where-Object Authenticated

        The requests that prove a completed sign-in, if there are any.

    .OUTPUTS
        PSCustomObject per request (or per address with -SummaryOnly),
        PSTypeName 'MsecAppGatewayClientActivity'.

    .NOTES
        Runs as the signed-in user against Log Analytics, like Search-MsecLogAnalytics - not as
        the msec app.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $ClientIp,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceName,

        [string] $ResourceGroupName,

        [ValidateRange(1, 365)]
        [int] $Days = 7,

        [switch] $SummaryOnly
    )

    # Checked before the query, because a malformed address matches nothing and an empty result
    # reads as "this address did nothing" rather than "you typed it wrong".
    $ips = foreach ($ip in $ClientIp) {
        $trimmed = "$ip".Trim()
        $parsed = [System.Net.IPAddress]::Any
        if (-not [System.Net.IPAddress]::TryParse($trimmed, [ref] $parsed)) {
            throw "'$ip' is not a valid IP address. Pass a bare address - a CIDR suffix or a stray space matches nothing and would come back as an empty result rather than an error."
        }
        $trimmed
    }
    $ipList = "'" + (($ips | ForEach-Object { $_ -replace "'", "''" }) -join "','") + "'"

    $workspaces = @(Search-MsecAzureResourceGraph -ResourceType LogAnalytics)
    $matched = @($workspaces | Where-Object { $_.Name -eq $WorkspaceName })
    if ($ResourceGroupName) { $matched = @($matched | Where-Object { $_.ResourceGroupName -eq $ResourceGroupName }) }
    if (-not $matched.Count) {
        $available = ($workspaces | Sort-Object Name | ForEach-Object { $_.Name }) -join ', '
        throw "Log Analytics workspace '$WorkspaceName' not found in any accessible subscription. Available: $available"
    }
    if ($matched.Count -gt 1) {
        $where = ($matched | ForEach-Object { "$($_.Name) (rg=$($_.ResourceGroupName), sub=$($_.SubscriptionId))" }) -join '; '
        throw "Workspace name '$WorkspaceName' is ambiguous - $($matched.Count) matches: $where. Narrow it with -ResourceGroupName."
    }
    $workspace = $matched[0]

    # tolong on BOTH union legs. A bare integer literal in KQL is a long and toint() is an int;
    # mismatched legs make Kusto emit Requests_long and Requests_int as separate columns instead
    # of failing, and a later sum(Requests) then references a column that does not exist - which
    # surfaces only as 'BadRequest' naming nothing. Same trap as Law/AppGateway/ClientGeography.kql.
    $query = @"
let Ips = dynamic([$ipList]);
union isfuzzy=true
    (
        AzureDiagnostics
        | where Category == 'ApplicationGatewayAccessLog'
        | where column_ifexists('clientIP_s', '') in (Ips)
        | project TimeGenerated,
                  ClientIp = column_ifexists('clientIP_s', ''),
                  Method   = column_ifexists('httpMethod_s', ''),
                  Uri      = column_ifexists('requestUri_s', ''),
                  Status   = tolong(column_ifexists('httpStatus_d', 0)),
                  Host     = column_ifexists('host_s', ''),
                  Agent    = column_ifexists('userAgent_s', ''),
                  Sent     = tolong(column_ifexists('sentBytes_d', 0)),
                  Requests = tolong(1),
                  Grain    = 'per-request'
    ),
    (
        AGWAccessSummary_CL
        | where column_ifexists('ClientIp', '') in (Ips)
        | project TimeGenerated,
                  ClientIp = column_ifexists('ClientIp', ''),
                  Method   = '',
                  Uri      = tostring(column_ifexists('SamplePaths', '')),
                  Status   = tolong(0),
                  Host     = tostring(column_ifexists('Hosts', '')),
                  Agent    = tostring(column_ifexists('UserAgents', '')),
                  Sent     = tolong(column_ifexists('Bytes', 0)),
                  Requests = tolong(column_ifexists('Requests', 0)),
                  Grain    = 'hourly-summary'
    )
// Only the per-request leg can show this: the summary has no method and no full URI, so a
// failed POST to a login page is indistinguishable from a GET of it there.
| extend Authenticated = iff(Grain == 'per-request',
             (Method == 'POST' and Uri has '/signin-oidc' and Status in (200, 302))
          or (Uri has '/connect/authorize/callback' and Status == 200),
             bool(null))
| sort by TimeGenerated asc
"@

    Write-Verbose ("Workspace $($workspace.Name) (id=$($workspace.CustomerId)), last $Days day(s), " +
                   "$($ips.Count) address(es)")

    $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId `
                                                -Query $query `
                                                -Timespan ([timespan]::FromDays($Days)) `
                                                -ErrorAction Stop
    $rows = @($result.Results)

    if (-not $rows.Count) {
        Write-Warning ("No Application Gateway activity for $($ips -join ', ') in workspace '$WorkspaceName' over $Days day(s). " +
                       "This is NOT proof the address was never seen: the per-request log may have moved to a Basic-plan " +
                       "table that KQL cannot read, and the hourly summary only exists where a summary rule was created. " +
                       "Check which grains the workspace holds for this window with " +
                       "Search-MsecLogAnalytics -Subject AppGateway -Name ClientGeography.")
        return
    }

    $toRow = {
        param($r)
        [PSCustomObject]@{
            PSTypeName    = 'MsecAppGatewayClientActivity'
            TimeGenerated = if ($r.TimeGenerated) { [datetime]$r.TimeGenerated } else { $null }
            ClientIp      = [string] $r.ClientIp
            Method        = [string] $r.Method
            Uri           = [string] $r.Uri
            Status        = if ($null -ne $r.Status -and [int64]$r.Status -gt 0) { [int] $r.Status } else { $null }
            Host          = [string] $r.Host
            UserAgent     = [string] $r.Agent
            BytesSent     = if ($null -ne $r.Sent) { [int64] $r.Sent } else { $null }
            Requests      = if ($null -ne $r.Requests) { [int64] $r.Requests } else { $null }
            # 'per-request' or 'hourly-summary' - what this row can and cannot tell you.
            Grain         = [string] $r.Grain
            # $null on a summary row: the method and URI needed to decide are not there, and
            # reporting $false would assert something unmeasured.
            Authenticated = if ($null -eq $r.Authenticated -or "$($r.Authenticated)" -eq '') { $null } else { [bool]::Parse("$($r.Authenticated)") }
            Raw           = $r
        }
    }

    $projected = foreach ($r in $rows) { & $toRow $r }

    if (-not $SummaryOnly) { return $projected }

    foreach ($g in ($projected | Group-Object ClientIp)) {
        $items = @($g.Group)
        $auth  = @($items | Where-Object { $_.Authenticated -eq $true })
        $perRequest = @($items | Where-Object Grain -eq 'per-request')
        $firstAuth = if ($auth.Count) { ($auth | Sort-Object TimeGenerated | Select-Object -First 1).TimeGenerated } else { $null }

        [PSCustomObject]@{
            PSTypeName      = 'MsecAppGatewayClientActivity'
            ClientIp        = $g.Name
            Requests        = ($items | Measure-Object Requests -Sum).Sum
            FirstSeen       = ($items | Sort-Object TimeGenerated | Select-Object -First 1).TimeGenerated
            LastSeen        = ($items | Sort-Object TimeGenerated | Select-Object -Last 1).TimeGenerated
            # $true where proven, $false only where a per-request log existed and showed none,
            # $null where the window held nothing that could answer.
            Authenticated   = if ($auth.Count) { $true } elseif ($perRequest.Count) { $false } else { $null }
            FirstAuth       = $firstAuth
            RequestsAfterAuth = if ($firstAuth) { @($items | Where-Object { $_.TimeGenerated -ge $firstAuth }).Count } else { $null }
            Hosts           = @($items | ForEach-Object { $_.Host } | Where-Object { $_ } | Sort-Object -Unique)
            UserAgents      = @($items | ForEach-Object { $_.UserAgent } | Where-Object { $_ } | Sort-Object -Unique)
            Statuses        = @($items | ForEach-Object { $_.Status } | Where-Object { $_ } | Sort-Object -Unique)
            Grains          = @($items | ForEach-Object { $_.Grain } | Sort-Object -Unique)
            BytesSent       = ($items | Measure-Object BytesSent -Sum).Sum
            Raw             = $items
        }
    }
}
