function Connect-MsecGraphSdk {
    <#
    .SYNOPSIS
        Signs the Microsoft.Graph PowerShell SDK in using the msec session's token, so
        Get-Mg* commands run as the msec app without its private key ever leaving Key Vault.

    .DESCRIPTION
        Hands Connect-MgGraph the access token Connect-MsecServiceSession already holds. That
        is the only handoff that preserves msec's central property: the certificate's private
        key stays in Key Vault and signing happens there.

        THE USUAL CERTIFICATE ROUTE CANNOT WORK HERE, and that is the point.
        Connect-MgGraph -ClientId -TenantId -CertificateThumbprint needs the private key
        present on the machine. Anything that ships a PFX or a base64 certificate to a build
        agent is putting the key somewhere it can be copied; this command exists so that is
        never necessary.

        THE TOKEN IS NOT REFRESHED. Connect-MgGraph is given a static token, so the SDK cannot
        renew it - unlike msec's own commands, which re-acquire as needed. Tokens last about
        an hour. A script that runs longer must call this again; -MinimumMinutes is how a
        long report asserts it has enough time before it starts rather than failing in the
        middle.

        APP-ONLY, NEVER DELEGATED. There is no signed-in user, so anything /me-shaped fails by
        design - Get-MgContext reports AppOnly. And the SDK can only do what the app was
        consented for: msec's roles are all *.Read.All, so every New-Mg*, Update-Mg* and
        Remove-Mg* answers 403. That is a guarantee rather than a limitation.

    .PARAMETER MinimumMinutes
        Fail unless the token has at least this long left. Default 5. A long-running report
        should ask for the time it needs - a token with four minutes on it will connect
        happily and then start failing partway through the run, which is far harder to
        diagnose than a refusal up front.

    .PARAMETER PassThru
        Emit the resulting Graph context.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Connect-MsecGraphSdk
        Get-MgUser -Top 5

    .EXAMPLE
        # A report that will run for half an hour, refusing to start without the headroom.
        Connect-MsecGraphSdk -MinimumMinutes 30
        Get-MgGroup -All | ForEach-Object { ... }

    .OUTPUTS
        With -PassThru, the Microsoft.Graph authentication context.

    .NOTES
        Needs Connect-Msec first, and the Microsoft.Graph.Authentication module - which is NOT
        a dependency of msec. It is imported only when this command is called, so the module
        installs and runs normally on a machine that has never heard of the Graph SDK.

        The cloud is taken from the msec session, not assumed. The SDK's environment names
        differ from Azure's (China, not AzureChinaCloud), so they are matched on the Graph
        endpoint itself rather than by name.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateRange(0, 60)]
        [int] $MinimumMinutes = 5,

        [switch] $PassThru
    )

    Assert-MsecSession

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Microsoft.Graph.Authentication is required for Connect-MsecGraphSdk. Install with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $resource = if ($script:MsecSession.Endpoints -and $script:MsecSession.Endpoints.GraphResource) {
        $script:MsecSession.Endpoints.GraphResource
    }
    else {
        'https://graph.microsoft.com'
    }

    # Matched on the ENDPOINT, not the name. The SDK calls the Chinese cloud 'China' where Az
    # calls it 'AzureChinaCloud', so mapping by name would need a lookup table that goes stale
    # every time a sovereign cloud is added - and the endpoint is what actually has to agree.
    $environment = 'Global'
    try {
        $match = @(Get-MgEnvironment -ErrorAction Stop |
                       Where-Object { $_.GraphEndpoint -and $_.GraphEndpoint.TrimEnd('/') -eq $resource.TrimEnd('/') })
        if ($match.Count -eq 1) {
            $environment = $match[0].Name
        }
        elseif ($match.Count -gt 1) {
            $environment = $match[0].Name
            Write-Warning "$($match.Count) Graph SDK environments share the endpoint '$resource'; using '$environment'."
        }
        else {
            # Better to say so than to sign in silently against the wrong cloud, which fails
            # later as a wall of 401s that look like a permission problem.
            Write-Warning "No Microsoft.Graph SDK environment matches the endpoint '$resource'. Falling back to 'Global', which is probably wrong for this cloud."
        }
    }
    catch {
        Write-Warning "Could not list the Graph SDK environments, so 'Global' is assumed: $($_.Exception.Message)"
    }

    $token = Get-MsecAccessToken -Resource $resource

    # Checked AFTER acquisition, because acquiring is what refreshes a stale one - testing the
    # cache first would refuse over a token the very next line would have replaced.
    $expiry = $script:MsecSession.Tokens[$resource].ExpiresOn
    if ($expiry) {
        $left = [int] ($expiry - [DateTimeOffset]::UtcNow).TotalMinutes
        if ($left -lt $MinimumMinutes) {
            throw "The Graph token has $left minute(s) left, which is under the $MinimumMinutes requested. The SDK is handed a static token and cannot renew it, so a longer run would start working and then fail partway through. Run Connect-Msec again for a fresh token."
        }
        Write-Verbose "Graph token valid for about $left more minute(s)."
    }

    $secure = ConvertTo-SecureString -String $token -AsPlainText -Force

    Connect-MgGraph -AccessToken $secure -Environment $environment -NoWelcome -ErrorAction Stop

    Write-Verbose "Microsoft.Graph SDK connected to $environment as app $($script:MsecSession.ClientId) (app-only)."

    if ($PassThru) { Get-MgContext }
}
