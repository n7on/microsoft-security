function Connect-MsecExchangeOnline {
    <#
    .SYNOPSIS
        Signs the ExchangeOnlineManagement module in using the msec session's token, so
        Get-EXO* commands run as the msec app without its private key leaving Key Vault.

    .DESCRIPTION
        Exchange Online is NOT Graph, and cannot be reached through it. Mailbox permissions -
        Full Access, Send As - are an Exchange concept with no Graph equivalent: there is no
        /users/{id}/mailboxPermissions endpoint, and no plan to add one. So the
        ExchangeOnlineManagement module is the only way to answer "who can read this shared
        mailbox", and this command exists to authenticate it the way msec authenticates
        everything else.

        THE TOKEN IS FOR outlook.office365.com, NOT GRAPH. Exchange issues its own audience, so
        a Graph token is rejected here and vice versa. Both are acquired the same way - a JWT
        client assertion signed inside Key Vault - which is what keeps the private key off this
        machine.

        EXCHANGE NEEDS A DIRECTORY ROLE, NOT JUST AN APP ROLE, and this is the step people
        miss. Exchange.ManageAsApp on the application is necessary but NOT sufficient: the
        service principal must also hold a directory role - Exchange Administrator, Exchange
        Recipient Administrator, or Global Reader for read-only work. Without it every cmdlet
        fails with an authorisation error that names no missing permission, because from
        Exchange's point of view the app is authenticated and simply has no rights.

        THE MODULE IS NOT AN msec DEPENDENCY. It is imported only when this command is called,
        so msec installs and runs normally on a machine that has never heard of Exchange.

    .PARAMETER Organization
        Optional. Resolved from Graph (the tenant's default verified domain) when omitted.
        The tenant's primary domain, e.g. contoso.onmicrosoft.com or contoso.com. Exchange
        identifies the tenant by domain rather than by id, and app-only connections require it.

    .PARAMETER MinimumMinutes
        Fail unless the token has at least this long left. Default 5. A long mailbox
        enumeration should ask for the time it needs: the module is handed a static token and
        cannot renew it, so a short one starts working and then fails partway through.

    .PARAMETER ShowBanner
        Show the module's own connection banner, which is suppressed by default because it is
        noise in a pipeline log.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Connect-MsecExchangeOnline -Organization contoso.onmicrosoft.com
        Get-EXOMailbox -RecipientTypeDetails SharedMailbox

    .EXAMPLE
        # A long run, refusing to start without headroom.
        Connect-MsecExchangeOnline -Organization contoso.com -MinimumMinutes 30

    .NOTES
        Needs Connect-Msec first, and the ExchangeOnlineManagement module - which is NOT a
        dependency of msec.

        Disconnect with Disconnect-ExchangeOnline. The module holds a session; leaving it open
        across a long script is fine, but leaving it open across tenants is not.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $Organization,

        [ValidateRange(0, 60)]
        [int] $MinimumMinutes = 5,

        [switch] $ShowBanner
    )

    Assert-MsecSession

    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        throw 'ExchangeOnlineManagement is required for Connect-MsecExchangeOnline. Install with: Install-Module ExchangeOnlineManagement -Scope CurrentUser'
    }
    Import-Module ExchangeOnlineManagement -ErrorAction Stop

    # Exchange Online's own audience. Commercial only - the sovereign clouds use different
    # hosts, and guessing one would produce a token Exchange rejects with an error that looks
    # like a permission problem.
    if (-not $Organization) {
        $Organization = Get-MsecTenantDomain
        Write-Verbose "Resolved organization from Graph: $Organization"
    }

    $resource = 'https://outlook.office365.com'
    $environment = $script:MsecSession.Endpoints.EnvironmentName
    if ($environment -and $environment -ne 'AzureCloud') {
        Write-Warning "The msec session is in '$environment'. Connect-MsecExchangeOnline assumes the commercial Exchange endpoint ($resource), which is probably wrong for this cloud - pass the right one by connecting with ExchangeOnlineManagement directly if this fails."
    }

    $token = Get-MsecAccessToken -Resource $resource

    # Checked AFTER acquisition: acquiring is what refreshes a stale token, so testing the
    # cache first would refuse over one the next line would have replaced.
    $expiry = $script:MsecSession.Tokens[$resource].ExpiresOn
    if ($expiry) {
        $left = [int] ($expiry - [DateTimeOffset]::UtcNow).TotalMinutes
        if ($left -lt $MinimumMinutes) {
            throw "The Exchange token has $left minute(s) left, which is under the $MinimumMinutes requested. The module is handed a static token and cannot renew it, so a longer run would start working and then fail partway through. Run Connect-Msec again for a fresh token."
        }
        Write-Verbose "Exchange token valid for about $left more minute(s)."
    }

    # -AccessToken is a plain String here, unlike Connect-MgGraph which takes a SecureString.
    $connectParams = @{
        AccessToken  = $token
        Organization = $Organization
        AppId        = $script:MsecSession.ClientId
        ErrorAction  = 'Stop'
    }
    if (-not $ShowBanner) { $connectParams['ShowBanner'] = $false }

    Connect-ExchangeOnline @connectParams

    Write-Verbose "Exchange Online connected to $Organization as app $($script:MsecSession.ClientId) (app-only)."
}
