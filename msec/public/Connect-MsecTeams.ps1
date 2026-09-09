function Connect-MsecTeams {
    <#
    .SYNOPSIS
        Signs the MicrosoftTeams module in using the msec session's tokens, so Get-Cs* commands
        run as the msec app without its private key leaving Key Vault. With -AsCurrentUser,
        signs in as you instead, reusing the Azure session you already have.

    .DESCRIPTION
        Teams admin policies are NOT in Microsoft Graph. Meeting policies, federation
        configuration, app permission policies - the settings that decide whether anonymous
        users can join a meeting or staff can chat with anyone outside the tenant - live behind
        the Teams admin API and are reachable only through the MicrosoftTeams module. That is
        why this exists rather than another Invoke-MsecGraphRequest.

        TWO TOKENS, NOT ONE. Connect-MicrosoftTeams -AccessTokens takes an ARRAY: one for
        Microsoft Graph and one for the 'Skype and Teams Tenant Admin API'. They are separate
        audiences with separate app roles, and passing only the Graph token fails in a way that
        looks like a permission problem rather than a missing token. In app mode both are
        minted the same way - a JWT client assertion signed inside Key Vault.

        TEAMS NEEDS A DIRECTORY ROLE, like Exchange does. App roles alone are not enough for
        app-only Teams administration: the service principal must also hold Teams
        Administrator, Teams Communications Administrator, or Global Reader for read-only work.
        Without one the connection succeeds and every Get-Cs* call then fails.

        -AsCurrentUser EXISTS BECAUSE INTERACTIVE SIGN-IN IS BROKEN ON MACOS AND LINUX.
        Connect-MicrosoftTeams's browser flow calls into kernel32.dll, which is Windows-only,
        so it dies with a dlopen error that says nothing about authentication. Device code flow
        is the documented workaround and Conditional Access usually refuses it - a policy
        requiring a compliant device cannot be satisfied by a flow where the device entering
        the code is not the device being authenticated. Reusing the Az session sidesteps both:
        that session already cleared Conditional Access, and no new interactive auth happens.

        THIS IS THE ONE PLACE msec HANDS OVER AN IDENTITY THAT CAN WRITE. msec has no Set-*
        commands and never will, but -AsCurrentUser connects with your rights - so whatever you
        can change in the Teams admin centre, you can change from this shell afterwards. App
        mode holds Global Reader and cannot.

        THE MODULE IS NOT AN msec DEPENDENCY. It is imported only when this command is called.

    .PARAMETER AsCurrentUser
        Connect as the signed-in Azure user rather than as the msec app, taking both tokens
        from the current Az context. Needs Connect-AzAccount, not Connect-Msec.

        Writing needs Teams Administrator on YOUR account. Global Reader authenticates fine and
        then refuses every Set-Cs*, with an error that names no permission.

    .PARAMETER MinimumMinutes
        Fail unless both tokens have at least this long left. Default 5.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Get-MsecTeamsPolicy

    .EXAMPLE
        # Read as the app, then change something as yourself.
        Connect-AzAccount
        Connect-MsecTeams -AsCurrentUser
        Get-CsTeamsFilesPolicy -Identity Global
        Set-CsTeamsFilesPolicy -Identity Global -FileSharingInChatswithExternalUsers Disabled

    .NOTES
        Needs Connect-Msec (or -AsCurrentUser and an Az context), and the MicrosoftTeams module
        - which is NOT a dependency of msec. Verified against MicrosoftTeams 7.9.0.

        Disconnect with Disconnect-MicrosoftTeams.
    #>
    [CmdletBinding()]
    param(
        [switch] $AsCurrentUser,

        [ValidateRange(0, 60)]
        [int] $MinimumMinutes = 5
    )

    if (-not (Get-Module -ListAvailable -Name MicrosoftTeams)) {
        throw 'MicrosoftTeams is required for Connect-MsecTeams. Install with: Install-Module MicrosoftTeams -Scope CurrentUser'
    }
    Import-Module MicrosoftTeams -ErrorAction Stop

    # The well-known appId of 'Skype and Teams Tenant Admin API'. Addressed by appId rather than
    # by a URL because this resource has no stable https identifier to request a token for.
    $teamsResource = '48ac35b8-9aa8-4d74-927d-1f4a14a0b239'

    # Each mode fills these: the two token strings in Graph-then-Teams order, and when they
    # expire, so the staleness check below is written once.
    $ordered = [ordered]@{}

    if ($AsCurrentUser) {
        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $ctx) {
            throw 'No Azure context, so there is no user session to borrow. Run Connect-AzAccount first, or drop -AsCurrentUser to connect as the msec app.'
        }

        $graphResource = 'https://graph.microsoft.com'
        $extended = $ctx.Environment.ExtendedProperties
        if ($extended -and $extended.ContainsKey('MicrosoftGraphUrl') -and $extended['MicrosoftGraphUrl']) {
            $graphResource = ([string] $extended['MicrosoftGraphUrl']).TrimEnd('/')
        }

        if ($ctx.Environment.Name -and $ctx.Environment.Name -ne 'AzureCloud') {
            Write-Warning "The Az context is in '$($ctx.Environment.Name)'. Teams administration is configured differently in sovereign clouds and this command assumes the commercial endpoints - expect it to fail here."
        }

        foreach ($resource in $graphResource, $teamsResource) {
            try { $raw = Get-AzAccessToken -ResourceUrl $resource -ErrorAction Stop }
            catch {
                $which = if ($resource -eq $teamsResource) { "the Teams admin API ($resource)" } else { 'Microsoft Graph' }
                # AADSTS65001 is the one worth naming: it means the Azure PowerShell client is
                # not consented for this audience, which no amount of retrying fixes.
                $hint = if ($_.Exception.Message -match 'AADSTS65001|not consented|consent') {
                    " The Azure PowerShell client is not consented for this resource in your tenant, and only a tenant admin can change that - use the Teams admin centre instead."
                }
                else { '' }
                throw "Could not get a user token for $which.$hint Original error: $($_.Exception.Message)"
            }

            # Az.Accounts 5 returns a SecureString; earlier versions a plain string. The Teams
            # module takes String[], so handing it the SecureString gives an authentication
            # failure with 'System.Security.SecureString' where the token should be.
            $value = if ($raw.Token -is [securestring]) { ConvertFrom-SecureString $raw.Token -AsPlainText } else { [string] $raw.Token }
            $ordered[$resource] = [pscustomobject]@{ Token = $value; ExpiresOn = $raw.ExpiresOn }
        }
    }
    else {
        Assert-MsecSession

        $graphResource = if ($script:MsecSession.Endpoints -and $script:MsecSession.Endpoints.GraphResource) {
            $script:MsecSession.Endpoints.GraphResource
        }
        else { 'https://graph.microsoft.com' }

        $environment = $script:MsecSession.Endpoints.EnvironmentName
        if ($environment -and $environment -ne 'AzureCloud') {
            Write-Warning "The msec session is in '$environment'. Teams administration is configured differently in sovereign clouds and this command assumes the commercial endpoints - expect it to fail here."
        }

        foreach ($resource in $graphResource, $teamsResource) {
            try { $value = Get-MsecAccessToken -Resource $resource }
            catch {
                $which = if ($resource -eq $teamsResource) { "the Teams admin API ($resource)" } else { 'Microsoft Graph' }
                throw "Could not get a token for $which. Teams needs BOTH, and the app must be granted permissions on the 'Skype and Teams Tenant Admin API' resource as well as on Graph - run New-MsecApp -Workload Teams. Original error: $($_.Exception.Message)"
            }

            # Read after acquisition, since acquiring is what refreshes a stale token.
            $ordered[$resource] = [pscustomobject]@{
                Token     = $value
                ExpiresOn = $script:MsecSession.Tokens[$resource].ExpiresOn
            }
        }
    }

    foreach ($resource in $ordered.Keys) {
        $expiry = $ordered[$resource].ExpiresOn
        if (-not $expiry) { continue }
        $left = [int] ($expiry - [DateTimeOffset]::UtcNow).TotalMinutes
        if ($left -lt $MinimumMinutes) {
            $fix = if ($AsCurrentUser) { 'Run Connect-AzAccount again.' } else { 'Run Connect-Msec again.' }
            throw "The token for $resource has $left minute(s) left, under the $MinimumMinutes requested. The module is handed static tokens and cannot renew them. $fix"
        }
    }

    # Order matters: Graph first, then the Teams admin API - that is the order the module
    # expects and it does not identify them by inspection.
    Connect-MicrosoftTeams -AccessTokens @($ordered[$graphResource].Token, $ordered[$teamsResource].Token) -ErrorAction Stop | Out-Null

    # Remembered so Get-MsecTeamsPolicy does not silently replace a user session with the app's
    # the next time it is called - which would leave the following Set-Cs* failing on rights
    # the caller does have.
    $script:MsecTeamsAsCurrentUser = [bool] $AsCurrentUser

    if ($AsCurrentUser) {
        Write-Verbose "Teams connected as $($ctx.Account.Id) (delegated)."
    }
    else {
        Write-Verbose "Teams connected as app $($script:MsecSession.ClientId) (app-only)."
    }
}
