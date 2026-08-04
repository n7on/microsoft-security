function Get-MsecSubscriptionList {
    <#
    .SYNOPSIS
        Enumerates accessible subscriptions and refreshes the completion cache as a side effect.

    .DESCRIPTION
        A thin wrapper over Get-AzSubscription whose real job is keeping the -SubscriptionId
        completion cache warm. Every estate-wide call in this module already enumerates
        subscriptions, so routing those calls through here makes completion free.

        WHY NOT Get-AzContext -ListAvailable, which is local and instant. Because it answers a
        different question: it lists the contexts you have signed into, not the subscriptions
        you can reach, and the two drift apart in BOTH directions. On the estate this was
        written against the local store held 6 subscriptions while Get-AzSubscription returned
        7, with three reachable subscriptions in a second tenant missing from the local store
        entirely - and the local store in turn listed subscriptions the live call did not.
        A completer built on it would silently offer an incomplete list, and "the subscription I
        needed was never suggested" is indistinguishable from "it isn't there".

    .OUTPUTS
        The Get-AzSubscription objects, unchanged.
    #>
    [CmdletBinding()]
    param()

    $subscriptions = @(Get-AzSubscription -ErrorAction Stop)

    Save-MsecCache -Name 'subscriptions' -Item @(
        $subscriptions | ForEach-Object {
            [pscustomobject]@{
                Id       = $_.Id
                Name     = $_.Name
                TenantId = $_.TenantId
                State    = [string]$_.State
            }
        }
    )

    $subscriptions
}
