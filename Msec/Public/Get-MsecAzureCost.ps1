function Get-MsecAzureCost {
    <#
    .SYNOPSIS
        Actual Azure spend for a subscription or a resource group over a window, from Cost
        Management.

    .DESCRIPTION
        Queries the Cost Management API for pre-tax cost, one row per scope asked about.

        THE CURRENCY IS RETURNED, NEVER DISCARDED. Cost Management answers with an amount AND
        the billing currency, and dropping the currency is how a report ends up adding SEK to
        EUR and printing a total that means nothing. It is a column here, and a run spanning
        two billing currencies warns rather than summing them.

        NOT ROUNDED. The API answers to full precision and this passes it through; round at
        the point of display, where you know how many places you want. Rounding in the
        collector loses the difference between "0.4" and "0" - the second reads as free.

        WHY Invoke-AzRestMethod AND NOT A HAND-BUILT REQUEST. Cost Management has no Az cmdlet
        for this query shape, so the obvious implementation acquires a token with
        Get-AzAccessToken and builds the call by hand. That breaks twice over: the ARM endpoint
        differs per cloud and has to be branched on, and since Az.Accounts 5 the token comes
        back as a SecureString, so interpolating it yields the literal string
        'Bearer System.Security.SecureString' and every call answers 401. Invoke-AzRestMethod
        handles both - it signs with the current context and resolves the endpoint for the
        cloud the context is in.

        COST DATA LAGS. Cost Management is not real time; the most recent day or two is
        usually incomplete, and a window ending today will under-report slightly. That is a
        property of the source, not of this command - but it means a day-over-day comparison
        of the last two days is measuring latency, not spending.

    .PARAMETER ResourceGroupName
        Scope to these resource groups. Accepts pipeline input. Omit for the whole
        subscription.

    .PARAMETER SubscriptionId
        The subscription to query. Defaults to the current Az context.

    .PARAMETER DaysBack
        How far back the window runs from today. Default 30.

    .PARAMETER MonthToDate
        Query the current billing month instead of a rolling window - which is what an invoice
        is reconciled against. Overrides -DaysBack.

    .EXAMPLE
        Connect-AzAccount
        Get-MsecAzureCost

    .EXAMPLE
        # Per resource group, dearest first.
        Get-AzResourceGroup | Get-MsecAzureCost -DaysBack 30 |
            Sort-Object Cost -Descending |
            Format-Table Scope, Cost, Currency, From, To

    .EXAMPLE
        # What the invoice will say.
        Get-MsecAzureCost -MonthToDate

    .OUTPUTS
        PSCustomObject per scope, PSTypeName 'MsecAzureCost'.

    .NOTES
        Uses your Az context, not the msec app session. Needs Cost Management Reader, or a
        role that includes it - Reader on the subscription is NOT enough for this API, which
        is the usual reason for a 401 here.

        Costs are PRE-TAX and exclude credits, reservations amortisation and marketplace
        charges billed separately - the same figure the portal's Cost Analysis shows for
        'Actual cost'.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string[]] $ResourceGroupName,

        [string] $SubscriptionId,

        [ValidateRange(1, 730)]
        [int] $DaysBack = 30,

        [switch] $MonthToDate
    )

    begin {
        $context = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $context) {
            throw 'No Azure context. Run Connect-AzAccount, then Select-MsecAzureContext to pick the subscription to report on.'
        }

        $subscription = if ($SubscriptionId) { $SubscriptionId } else { [string] $context.Subscription.Id }
        if (-not $subscription) {
            throw 'The Az context has no subscription. Run Select-MsecAzureContext to pick one.'
        }

        $to   = [DateTime]::UtcNow.Date
        $from = $to.AddDays(-$DaysBack)

        $dataset = @{
            granularity = 'None'
            aggregation = @{ totalCost = @{ name = 'PreTaxCost'; function = 'Sum' } }
        }

        $payload = if ($MonthToDate) {
            @{ type = 'ActualCost'; timeframe = 'MonthToDate'; dataset = $dataset }
        }
        else {
            @{
                type = 'ActualCost'; timeframe = 'Custom'
                timePeriod = @{ from = $from.ToString('yyyy-MM-dd'); to = $to.ToString('yyyy-MM-dd') }
                dataset = $dataset
            }
        }
        $body = $payload | ConvertTo-Json -Depth 20

        $currencies = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

        $query = {
            param($Scope, $ScopeName)

            $path = "$Scope/providers/Microsoft.CostManagement/query?api-version=2023-03-01"

            # COST MANAGEMENT THROTTLES HARD, and this is the command most likely to feel it:
            # the natural use is a loop over every resource group, which is exactly the shape
            # that trips the limit. Without retrying, a 30-group report silently loses the
            # groups that happened to land after the quota ran out - the total comes back
            # plausible and too low, which is the worst way for a cost report to be wrong.
            #
            # The API answers 429 with a Retry-After header saying how long to wait, which is
            # authoritative when present; the fallback is capped exponential backoff so one
            # throttled scope cannot stall a run for minutes.
            $response = $null
            $maxAttempts = 5

            for ($attempt = 1; ; $attempt++) {
                try {
                    $response = Invoke-AzRestMethod -Method POST -Path $path -Payload $body -ErrorAction Stop
                }
                catch {
                    Write-Warning "Cost query failed for '$ScopeName': $($_.Exception.Message)"
                    return
                }

                if ($response.StatusCode -ne 429 -or $attempt -ge $maxAttempts) { break }

                $wait = 0
                try {
                    $retryAfter = @($response.Headers | Where-Object { $_.Key -eq 'Retry-After' })
                    if ($retryAfter.Count) { $wait = [int] (@($retryAfter[0].Value)[0]) }
                }
                catch {
                    # Header shapes vary by platform and Az version; backoff covers it.
                }
                if ($wait -le 0) { $wait = [Math]::Min(60, [Math]::Pow(2, $attempt + 1)) }

                Write-Verbose "Cost Management throttled '$ScopeName'. Waiting $wait s, then retry $attempt of $($maxAttempts - 1)."
                Start-Sleep -Seconds $wait
            }

            if ($response.StatusCode -eq 429) {
                # Said loudly rather than returning nothing: a missing scope makes the total
                # too low, and a total that is quietly too low is worse than no total.
                Write-Warning "Cost Management kept throttling '$ScopeName' after $maxAttempts attempts, so it contributes NO row and any total below is short by its cost. Re-run, or narrow the scope."
                return
            }

            if ($response.StatusCode -ne 200) {
                $detail = if ($response.Content) { $response.Content } else { '(no body)' }
                if ($response.StatusCode -in 401, 403) {
                    # Reader is not enough for this API and the message should say so, or the
                    # reader goes looking at subscription access that is already correct.
                    Write-Warning "Cost query for '$ScopeName' was denied (HTTP $($response.StatusCode)). This API needs Cost Management Reader - Reader on the subscription is not sufficient. $detail"
                }
                else {
                    Write-Warning "Cost query for '$ScopeName' returned HTTP $($response.StatusCode): $detail"
                }
                return
            }

            $content = $response.Content | ConvertFrom-Json
            $columns = @($content.properties.columns.name)
            $rows    = @($content.properties.rows)

            # Column ORDER is not guaranteed, so the indices are looked up by name. Reading
            # rows[0][0] as the cost happens to work today and would silently return a currency
            # code as a number the day the API reorders them.
            $costIndex     = [array]::IndexOf($columns, 'PreTaxCost')
            $currencyIndex = [array]::IndexOf($columns, 'Currency')

            # No rows means no CHARGES, which is a real answer - an empty resource group costs
            # nothing. Distinct from a failed query, which returned above.
            $cost = 0.0
            $currency = $null
            if ($rows.Count -and $costIndex -ge 0) {
                $cost = [double] $rows[0][$costIndex]
                if ($currencyIndex -ge 0) { $currency = [string] $rows[0][$currencyIndex] }
            }
            if ($currency) { [void] $currencies.Add($currency) }

            [PSCustomObject]@{
                PSTypeName        = 'MsecAzureCost'
                Scope             = $ScopeName
                Cost              = $cost
                Currency          = $currency
                From              = $(if ($MonthToDate) { [DateTime]::new($to.Year, $to.Month, 1) } else { $from })
                To                = $to
                Timeframe         = $(if ($MonthToDate) { 'MonthToDate' } else { "Last $DaysBack days" })
                ResourceGroupName = $(if ($ScopeName -ne $subscription) { $ScopeName } else { $null })
                SubscriptionId    = $subscription
            }
        }
    }

    process {
        if ($ResourceGroupName) {
            foreach ($name in $ResourceGroupName) {
                & $query "/subscriptions/$subscription/resourceGroups/$name" $name
            }
        }
        else {
            & $query "/subscriptions/$subscription" $subscription
        }
    }

    end {
        if ($currencies.Count -gt 1) {
            # Adding SEK to EUR produces a number that means nothing, and nothing downstream
            # can tell it happened unless this says so.
            Write-Warning "This run spans $($currencies.Count) billing currencies ($(($currencies | Sort-Object) -join ', ')). Do NOT sum the Cost column across them."
        }
    }
}
