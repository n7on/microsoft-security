function Resolve-MsecSubscription {
    <#
    .SYNOPSIS
        Turns subscription names (or ids) into subscription ids.

    .DESCRIPTION
        Lets -Subscription take 'PROD' instead of a GUID nobody remembers, while still accepting
        an id - because names are NOT unique. This estate has three subscriptions all called
        'Cloud Subscription', and a name-only parameter could not address any of them.

        An id is passed straight through without enumerating anything. That is not just a
        shortcut: enumeration is a network round trip that can fail, and a caller who already has
        the id should not be made to depend on it succeeding.

        A name that matches nothing, or matches more than one subscription, throws with the
        candidates rather than picking one - the same contract as -WorkspaceName.

    .PARAMETER Subscription
        Names, ids, or a mix.

    .OUTPUTS
        String ids, in the order given.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Subscription
    )

    $parsed = [guid]::Empty
    if (-not ($Subscription | Where-Object { -not [guid]::TryParse($_, [ref] $parsed) })) {
        return $Subscription   # all ids already; nothing to look up
    }

    $all = @(Get-MsecSubscriptionList)

    foreach ($item in $Subscription) {
        if ([guid]::TryParse($item, [ref] $parsed)) { $item; continue }

        $matched = @($all | Where-Object { $_.Name -eq $item })
        if ($matched.Count -eq 1) { $matched[0].Id; continue }

        if ($matched.Count -gt 1) {
            $ids = ($matched | ForEach-Object { $_.Id }) -join ', '
            throw ("Subscription name '$item' is ambiguous - $($matched.Count) subscriptions share it. " +
                   "Pass one of these ids instead: $ids")
        }

        # NAME THE TENANT. Get-MsecSubscriptionList only enumerates the ACTIVE tenant, so the
        # usual reason a subscription is "not found" is that the context moved to a different
        # tenant - not a typo. Listing what is available without saying where it was looked for
        # sends the reader to check a spelling that was already right.
        $available = (($all | ForEach-Object { $_.Name }) | Sort-Object -Unique) -join ', '
        $context = Get-AzContext -ErrorAction SilentlyContinue
        $where = if ($context) {
            " in tenant $($context.Tenant.Id) (signed in as $($context.Account.Id))"
        } else { '' }
        throw ("Subscription '$item' not found$where. Available there: $available. " +
               'Subscriptions are per-tenant, so one that exists in another tenant will not ' +
               'appear here - Select-MsecAzureContext switches tenant as well as subscription.')
    }
}
