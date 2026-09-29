function Connect-MsecPurview {
    <#
    .SYNOPSIS
        Opens an app-only Security & Compliance PowerShell session for the Get-MsecPurview*
        commands.

    .DESCRIPTION
        CALLING THIS IS OPTIONAL. The Get-MsecPurview* commands open a session themselves on
        first use, so Connect-Msec is normally all you need. Use this directly when the tenant
        domain has to be given explicitly, or to choose when a few hundred compliance cmdlet
        names are imported into your runspace. Measured: 102 cmdlets, none of them clashing with
        the ExchangeOnlineManagement module's own exports - so the import is bulk rather than
        destructive, and a Get- command doing it unasked is still a side effect worth knowing about.

        Purview's configuration is not in Microsoft Graph. Retention labels have a v1.0 endpoint
        and eDiscovery cases have one, but DLP policies, DLP rules, sensitivity label actions and
        label policies do not - the only complete source is Security & Compliance PowerShell,
        which is why this exists rather than another Invoke-MsecGraphRequest caller.

        NO NEW CONSENT IS NEEDED. Connect-IPPSSession accepts -AccessToken and -AppId, the same
        shape Connect-MsecExchangeOnline uses, so the existing Key Vault certificate reaches the
        compliance endpoint as the app. The resource differs
        (ps.compliance.protection.outlook.com rather than outlook.office365.com) but the identity
        and the trust do not.

        The app still needs a directory role to be allowed in - Global Reader or Compliance
        Administrator. New-MsecApp assigns Global Reader when asked for -Workload Exchange, and a
        403 here almost always means that assignment is missing rather than that a permission is.

        -Organization is optional: left off, the tenant's default verified domain is read from
        Graph, which the app can already do.

    .PARAMETER Organization
        Tenant domain, e.g. contoso.onmicrosoft.com. Resolved from Graph when omitted.

    .PARAMETER ShowBanner
        Show the ExchangeOnlineManagement banner. Suppressed by default.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecPurviewDlpPolicy      # connects by itself

        # Explicit, when the domain must be given or the import timed deliberately:
        Connect-MsecPurview -Organization contoso.onmicrosoft.com

    .NOTES
        Needs the ExchangeOnlineManagement module, which is not a dependency of msec - only the
        Exchange and Purview commands require it.

        NB this shares cmdlet names with an Exchange Online session. Connecting both into one
        runspace lets the later connection win for overlapping names; connect Purview in its own
        session if you also need Get-Mailbox.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $Organization,

        [Parameter()]
        [switch] $ShowBanner
    )

    Assert-MsecSession

    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        throw 'ExchangeOnlineManagement is required for Connect-MsecPurview. Install with: Install-Module ExchangeOnlineManagement -Scope CurrentUser'
    }
    Import-Module ExchangeOnlineManagement -ErrorAction Stop

    $resource = 'https://ps.compliance.protection.outlook.com'
    $environment = $script:MsecSession.Endpoints.EnvironmentName
    if ($environment -and $environment -ne 'AzureCloud') {
        Write-Warning "The msec session is in '$environment'. Connect-MsecPurview assumes the commercial compliance endpoint ($resource), which is probably wrong for this cloud."
    }

    if (-not $Organization) {
        $Organization = Get-MsecTenantDomain
        Write-Verbose "Resolved organization from Graph: $Organization"
    }

    $token = Get-MsecAccessToken -Resource $resource

    $connectParams = @{
        AccessToken  = $token
        Organization = $Organization
        AppId        = $script:MsecSession.ClientId
        ErrorAction  = 'Stop'
    }
    if (-not $ShowBanner) { $connectParams['ShowBanner'] = $false }

    try {
        Connect-IPPSSession @connectParams
    }
    catch {
        $detail = $_.Exception.Message
        if ($detail -match '401|403|[Uu]nauthor|[Ff]orbidden|AADSTS') {
            throw ("Rejected by the compliance endpoint as app $($script:MsecSession.ClientId). This is usually a missing " +
                   'DIRECTORY ROLE rather than a missing API permission - the app needs Global Reader or Compliance ' +
                   "Administrator, assigned in Entra ID > Roles and administrators. Original error: $detail")
        }
        throw $detail
    }

    Write-Verbose "Purview connected to $Organization as app $($script:MsecSession.ClientId) (app-only)."
}
