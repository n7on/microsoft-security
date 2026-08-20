function Get-MsecSubscriptionList {
    <#
    .SYNOPSIS
        Enumerates the accessible subscriptions in the current tenant and refreshes the
        completion cache as a side effect.

    .DESCRIPTION
        Shared by everything in this module that means "every subscription". Its second job is
        keeping the -Subscription completion cache warm: estate-wide calls already enumerate, so
        routing them through here makes completion free.

        PINNED TO ONE TENANT. Get-AzSubscription without -TenantId walks EVERY tenant the signed
        in account can see, acquiring a token per tenant. That is a wider blast radius than
        anything in this module wants: one unreachable or slow tenant delays or fails a query
        about subscriptions you were not asking about. The tenant comes from the active Az
        context, so switching tenant is Set-AzContext (or Select-MsecAzureContext) - explicit,
        and visible in -Verbose - rather than an implicit fan-out.

        WHY NOT Get-AzContext -ListAvailable, which is local and instant. It answers a different
        question: the contexts you have signed into, not the subscriptions you can reach. The two
        drift apart in both directions - on the estate this was written against the local store
        held 6 subscriptions while the live call returned 7, and the local store also listed
        subscriptions from other clouds and accounts that the live call does not. A completer
        built on it would silently offer an incomplete list.

    .OUTPUTS
        The Get-AzSubscription objects, unchanged.
    #>
    [CmdletBinding()]
    param()

    $tenantId = (Get-AzContext -ErrorAction SilentlyContinue).Tenant.Id
    if (-not $tenantId) {
        throw 'The active Az context has no tenant. Run Connect-AzAccount.'
    }

    Write-Verbose "Enumerating subscriptions in tenant $tenantId only."
    $subscriptions = @(Get-AzSubscription -TenantId $tenantId -ErrorAction Stop)

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
