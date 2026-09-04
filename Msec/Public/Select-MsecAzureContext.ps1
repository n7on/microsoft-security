function Select-MsecAzureContext {
    <#
    .SYNOPSIS
        Switches to one of your already-signed-in Azure contexts. Pick the subscription by
        name (or id), then the user account if more than one is signed in to it - the
        account implies the tenant, so you never deal with tenant ids. Warns if the switch
        leaves your msec app session (Connect-Msec) on a different tenant or cloud.

    .DESCRIPTION
        msec uses two identities: your Az context (for ARM / Key Vault / VM run-commands)
        and the app-only session from Connect-Msec (for Graph / Defender). This is the one
        deliberate place to move the Az context, choosing among the contexts Az has ALREADY
        saved for you (Get-AzContext -ListAvailable) - one per (account, tenant,
        subscription, cloud) you've signed in to.

          1. -Subscription matches a saved context by subscription name or id (tab-completes
             the distinct subscription names).
          2. -User disambiguates when the same subscription is signed in under more than one
             account (tab-completes the accounts available for the chosen -Subscription).
             Because an account belongs to a tenant, picking the user settles the tenant -
             no tenant id needed.
          3. The matching context is activated (Select-AzContext).
          4. If a Connect-Msec session exists and the new context is in a different tenant or
             cloud, Graph/Defender calls would still use the OLD session, so it tells you to
             re-run Connect-Msec.

        If the subscription has no saved context yet, sign in first: Connect-AzAccount
        [-Tenant <id>] [-Environment <cloud>]. Cross-CLOUD moves always need that - a single
        Az session is one cloud at a time.

        RECONNECTS THE MSEC APP SESSION TO MATCH, when the tenant being switched to has been
        connected before. msec runs on TWO identities - the Az context is you, the msec session
        is the app registration - and switching one used to leave the other pointing at the
        tenant you just left, so Graph and Defender calls kept answering for the wrong tenant.
        Connect-Msec remembers the vault, client id and certificate name per tenant; this
        replays them.

        No secret is stored and none is needed: signing happens inside Key Vault and the
        private key never leaves it. A tenant with no saved profile behaves as before - the
        context switches and a warning says the session is now misaligned. -NoConnect skips
        the reconnect entirely.

        A failed reconnect does NOT fail the switch. The context change is what was asked for
        and it stands; the reconnect is a convenience, and losing it warns rather than throws.
    .PARAMETER Subscription
        Subscription name or id of the saved context to switch to. Tab-completes the
        distinct subscription names of your signed-in contexts.

    .PARAMETER User
        Account (sign-in name) owning the context, used when the same subscription is signed
        in under more than one account. Tab-completes the accounts available for the chosen
        -Subscription.

    .EXAMPLE
        Select-MsecAzureContext -Subscription 'we-prod-sub'

    .EXAMPLE
        # Same subscription name signed in under two accounts - pick the user:
        Select-MsecAzureContext -Subscription PROD -User admin@partner.onmschina.cn

    .OUTPUTS
        PSCustomObject: SubscriptionName, SubscriptionId, TenantId, Environment, Account.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
                # Distinct subscription names across your saved contexts; tooltip lists the
                # accounts signed in to each, so you know whether -User will be needed next.
                try { $ctxs = Get-AzContext -ListAvailable -ErrorAction Stop } catch { return }
                $word = ([string]$wordToComplete).Trim("'`"")
                $ctxs |
                    Where-Object { $_.Subscription.Name -like "$word*" } |
                    Group-Object { $_.Subscription.Name } |
                    Sort-Object Name |
                    ForEach-Object {
                        $name = $_.Name
                        $accts = (($_.Group | ForEach-Object { $_.Account.Id }) | Sort-Object -Unique) -join ', '
                        $text = if ($name -match "[\s']") { "'" + ($name -replace "'", "''") + "'" } else { $name }
                        [System.Management.Automation.CompletionResult]::new(
                            $text, $name, 'ParameterValue', "$name  [accounts: $accts]")
                    }
            })]
        [string] $Subscription,

        [Parameter(Position = 1)]
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
                # Accounts available for the already-chosen -Subscription (dependent completion).
                try { $ctxs = Get-AzContext -ListAvailable -ErrorAction Stop } catch { return }
                $sub = ([string]$fakeBoundParameters['Subscription']).Trim("'`"")
                $word = ([string]$wordToComplete).Trim("'`"")
                $ctxs |
                    Where-Object {
                        (-not $sub -or $_.Subscription.Name -eq $sub -or $_.Subscription.Id -eq $sub) -and
                        $_.Account.Id -like "$word*"
                    } |
                    ForEach-Object { $_.Account.Id } |
                    Sort-Object -Unique |
                    ForEach-Object {
                        $text = if ($_ -match "[\s']") { "'" + ($_ -replace "'", "''") + "'" } else { $_ }
                        [System.Management.Automation.CompletionResult]::new($text, $_, 'ParameterValue', $_)
                    }
            })]
        [string] $User,

        # Switch the Azure context only - do not reconnect the msec app session even if this
        # tenant has a saved profile.
        [Parameter()]
        [switch] $NoConnect
    )

    $available = @(Get-AzContext -ListAvailable -ErrorAction SilentlyContinue)
    if (-not $available) {
        throw 'No saved Azure contexts found. Run Connect-AzAccount first - contexts are saved per subscription/tenant you sign in to (with context autosave enabled).'
    }

    # Match a saved context by subscription name or id, optionally narrowed to one account.
    $candidates = @($available | Where-Object {
            ($_.Subscription.Name -eq $Subscription -or $_.Subscription.Id -eq $Subscription) -and
            (-not $User -or $_.Account.Id -eq $User)
        })

    if ($candidates.Count -eq 0) {
        $who = if ($User) { " for user '$User'" } else { '' }
        throw "No signed-in context matches subscription '$Subscription'$who. Sign in to it first with Connect-AzAccount [-Tenant <id>] [-Environment <cloud>] (cross-cloud always needs -Environment), then retry."
    }
    if ($candidates.Count -gt 1) {
        $list = ($candidates | ForEach-Object { "$($_.Account.Id) (tenant $($_.Tenant.Id), $($_.Subscription.Id))" }) -join '; '
        throw "Subscription '$Subscription' is signed in under more than one account: $list. Add -User <account>, or pass the subscription id to be exact."
    }

    $target = $candidates[0]
    Write-Verbose "Selecting context '$($target.Name)' - $($target.Account.Id), tenant $($target.Tenant.Id), $($target.Environment)"
    # Select by the context object, not its -Name: Select-AzContext -Name carries a dynamic
    # ValidateSet of the machine's context names; selecting the exact object we matched is
    # cleaner and avoids a redundant name lookup.
    $null = Select-AzContext -InputObject $target -ErrorAction Stop

    # On a real saved context, .Environment is a PSAzureEnvironment OBJECT (and .Tenant.Id can
    # be a guid), so compare/emit their STRING forms - otherwise object-vs-string is always
    # "not equal" and the drift warning fires even when tenant and cloud actually match.
    $ctxTenant = [string]$target.Tenant.Id
    $ctxCloud = [string]$target.Environment

    # RECONNECT THE APP SESSION TO MATCH, if this tenant has been connected before. The two
    # identities are separate - the Az context is you, the msec session is the app - and
    # switching one used to leave the other pointing at the previous tenant, so every Graph
    # call kept answering for the tenant you just left. That was a warning; now it is fixed
    # where it can be.
    #
    # Only when the session is not already this tenant's, so a switch between two subscriptions
    # in the same tenant costs nothing.
    if (-not $NoConnect -and (-not $script:MsecSession -or [string]$script:MsecSession.TenantId -ne $ctxTenant)) {
        $profile = Get-MsecTenantProfile -TenantId $ctxTenant
        if ($profile) {
            try {
                # -NoSave: this is replaying a profile, not creating one.
                Connect-Msec -KeyVaultName $profile.KeyVaultName -ClientId $profile.ClientId `
                             -TenantId $ctxTenant -CertificateName $profile.CertificateName -NoSave
                Write-Verbose "Reconnected the msec app session to tenant $ctxTenant using the saved profile (vault $($profile.KeyVaultName))."
            }
            catch {
                # The context switch itself succeeded and must stand. Losing the convenience
                # of auto-reconnect is not a reason to fail the thing that was asked for.
                Write-Warning "Switched the Azure context, but could not reconnect the msec app session for tenant $ctxTenant using the saved profile (vault $($profile.KeyVaultName)): $($_.Exception.Message)"
            }
        }
    }

    # Coherence check against the msec app session (if connected). The session is bound to a
    # tenant + cloud at Connect-Msec time; a switch into a different tenant or cloud leaves
    # Graph/Defender calls using the OLD session. Reached only when the reconnect above did
    # not happen or did not help - there is no profile for this tenant, it failed, or
    # -NoConnect was given.
    if ($script:MsecSession) {
        $sessTenant = [string]$script:MsecSession.TenantId
        $sessCloud = [string]$script:MsecSession.Endpoints.EnvironmentName
        if ($ctxTenant -ne $sessTenant -or $ctxCloud -ne $sessCloud) {
            Write-Warning ("msec app session is bound to tenant $sessTenant / cloud $sessCloud, but the Az context is now " +
                "tenant $ctxTenant / cloud $ctxCloud. Graph/Defender functions still use the old session - " +
                'run Connect-Msec again to realign - which also saves a profile, so later ' +
                'switches into this tenant reconnect on their own.')
        }
    }

    [pscustomobject]@{
        SubscriptionName = $target.Subscription.Name
        SubscriptionId   = $target.Subscription.Id
        TenantId         = $ctxTenant
        Environment      = $ctxCloud
        Account          = $target.Account.Id
    }
}
