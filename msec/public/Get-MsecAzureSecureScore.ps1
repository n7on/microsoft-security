function Get-MsecAzureSecureScore {
    <#
    .SYNOPSIS
        Per-subscription Microsoft Defender for Cloud Secure Score, projected to
        flat rows: SubscriptionId / SubscriptionName / ScoreType / ScorePercent / Date.

    .DESCRIPTION
        Calls the Microsoft Defender for Cloud (formerly Azure Security Center) ARM
        API:

            GET https://management.azure.com/subscriptions/{id}
                /providers/Microsoft.Security/secureScores?api-version=2020-01-01

        Returns one row per (subscription, ScoreType). By default, only the
        'Overall' row per subscription is emitted. -IncludeControls also emits
        one row per Defender for Cloud control (e.g. 'Enable MFA', 'Encrypt data
        at rest', ...) - useful when an auditor asks "which categories are
        bringing the score down".

        Auth uses the CALLER's Az.Accounts identity, not the msec app - Defender
        for Cloud is ARM-rooted and access is granted via subscription RBAC, not
        Entra app permissions. You need at least Reader role on each subscription
        you want scored. Same auth boundary as Search-MsecAzureResourceGraph and
        Invoke-MsecAzureVMScript.

        No historical trend is available - the API only returns the current
        snapshot. Your bi-weekly archive script is the only source of history
        for this score. To match the row shape of Get-MsecSecureScore, a Date
        column is included with today's date.

    .PARAMETER SubscriptionId
        Restrict to specific subscriptions. Omit to score every accessible
        subscription in the current Az context's tenant.

    .PARAMETER IncludeControls
        Also emit one row per Defender for Cloud control (per subscription).
        Adds one extra ARM call per subscription, so noticeably slower on
        tenants with many subscriptions. Off by default.

    .EXAMPLE
        # Overall score per subscription (the headline number)
        Get-MsecAzureSecureScore | Format-Table SubscriptionName, ScorePercent

    .EXAMPLE
        # Control-level breakdown for a single sub
        Get-MsecAzureSecureScore -SubscriptionId '<guid>' -IncludeControls |
            Sort-Object ScorePercent | Select -First 10 ScoreType, ScorePercent

    .OUTPUTS
        PSCustomObject per (subscription, ScoreType) with SubscriptionId,
        SubscriptionName, ScoreType ('Overall' or a control name), ScorePercent
        (0-100, null if max=0), Date (today).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]] $SubscriptionId,

        [Parameter()]
        [switch] $IncludeControls
    )

    # Caller's Az.Accounts identity - NOT the msec app. Match the auth flow
    # used by Search-MsecAzureResourceGraph and Invoke-MsecAzureVMScript.
    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw 'No Azure context. Run Connect-AzAccount before Get-MsecAzureSecureScore.'
    }

    # Default to every accessible subscription in the current tenant (same convention as
    # Search-MsecAzureResourceGraph). Via Get-MsecSubscriptionList so the enumeration is pinned
    # to the active context's tenant rather than fanning out across every tenant the account can
    # see - which is what a bare Get-AzSubscription does, and what this comment always claimed
    # it did not.
    $subs = if ($SubscriptionId) {
        $SubscriptionId | ForEach-Object {
            Get-AzSubscription -SubscriptionId $_ -TenantId (Get-AzContext).Tenant.Id -ErrorAction Stop
        }
    }
    else {
        Get-MsecSubscriptionList
    }

    # ARM endpoint for the current cloud (management.chinacloudapi.cn in China). Derived
    # from the Az context so this works in every sovereign cloud, not just commercial.
    $arm = (Get-MsecEnvironment).ArmResource

    # ARM token. Get-AzAccessToken returns SecureString in Az.Accounts 5.x+ and
    # plain string in older versions - handle both transparently.
    $tokenResp = Get-AzAccessToken -ResourceUrl "$arm/" -ErrorAction Stop
    $token = if ($tokenResp.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $tokenResp.Token).Password
    }
    else {
        $tokenResp.Token
    }
    $headers = @{ Authorization = "Bearer $token" }

    $today = (Get-Date).Date

    foreach ($sub in $subs) {
        $subId   = $sub.Id
        $subName = $sub.Name

        # Per-subscription Overall score lives in the 'ascScore' item of the
        # secureScores collection. There's only ever one item per sub - this
        # endpoint returns a collection for forward compatibility, not because
        # multiple scores exist today.
        $overallUri = "$arm/subscriptions/$subId/providers/Microsoft.Security/secureScores?api-version=2020-01-01"
        try {
            $resp = Invoke-RestMethod -Method GET -Uri $overallUri -Headers $headers -ErrorAction Stop
        }
        catch {
            # 403 = no Reader role; 404 = Defender for Cloud never enabled on the sub.
            # Either way, surface a warning and move on - don't fail the whole batch.
            Write-Warning "Could not read secure score for subscription '$subName' ($subId): $($_.Exception.Message)"
            continue
        }

        $overall = $resp.value | Where-Object name -eq 'ascScore' | Select-Object -First 1
        if ($overall) {
            [PSCustomObject]@{
                SubscriptionId   = $subId
                SubscriptionName = $subName
                ScoreType        = 'Overall'
                ScorePercent     = & { param($s)
                    if ($s.max -gt 0) { [math]::Round(($s.current / $s.max) * 100, 2) } else { $null }
                } $overall.properties.score
                Date             = $today
            }
        }

        if ($IncludeControls) {
            $controlsUri = "$arm/subscriptions/$subId/providers/Microsoft.Security/secureScores/ascScore/secureScoreControls?api-version=2020-01-01"
            try {
                $cResp = Invoke-RestMethod -Method GET -Uri $controlsUri -Headers $headers -ErrorAction Stop
            }
            catch {
                Write-Warning "Could not read secure score controls for subscription '$subName' ($subId): $($_.Exception.Message)"
                continue
            }

            foreach ($c in $cResp.value) {
                [PSCustomObject]@{
                    SubscriptionId   = $subId
                    SubscriptionName = $subName
                    ScoreType        = $c.properties.displayName
                    ScorePercent     = & { param($s)
                        if ($s.max -gt 0) { [math]::Round(($s.current / $s.max) * 100, 2) } else { $null }
                    } $c.properties.score
                    Date             = $today
                }
            }
        }
    }
}
