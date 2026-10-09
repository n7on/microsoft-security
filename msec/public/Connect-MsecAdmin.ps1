function Connect-MsecAdmin {
    <#
    .SYNOPSIS
        Signs in AS YOU, with delegated write scopes, for the commands that change something.
        Read commands keep using the app; this session is only for writes.

    .DESCRIPTION
        THE APP CANNOT DO THIS, ON PURPOSE. Every Graph permission New-MsecApp consents is
        *.Read.All, so the certificate in Key Vault cannot change anything - that is the
        module's central promise and it is enforced by the token, not by naming. Writes
        therefore run as a person instead: attributable to a named account, subject to your
        Conditional Access and MFA, bounded by your own Defender RBAC rather than tenant-wide
        application permissions, and impossible from an unattended pipeline unless somebody
        deliberately sets one up.

        NOT THE -AsCurrentUser PATTERN, AND HERE IS WHY. Connect-MsecTeams borrows the Az
        context's token, which works because Azure PowerShell's first-party app holds the
        scopes those commands need. Measured on a live tenant, its Graph token carries
        Application.ReadWrite.All, Group.ReadWrite.All, Directory.AccessAsUser.All and
        User.Read.All - and nothing for security. There is no SecurityAlert.ReadWrite.All in
        it, so borrowing cannot resolve an alert. This asks for consent properly instead.

        CONSENT REQUESTED IS NOT CONSENT GRANTED. Connect-MgGraph succeeds when a tenant
        declines a scope; the context simply comes back without it, and the first write then
        fails with a 403 that names nothing. Every requested scope is checked against what was
        actually granted, and a missing one is reported by name here rather than discovered
        later.

        IT WILL REFUSE A DIFFERENT TENANT FROM THE ONE YOU ARE READING. If Connect-Msec holds
        a session, this must sign in to the same tenant. Reading one tenant and writing to
        another is the kind of mistake that is obvious afterwards and invisible at the time.

    .PARAMETER Scope
        Delegated scopes to request. DEFAULTS TO EVERY SCOPE THE MODULE'S WRITE COMMANDS NEED,
        so a bare Connect-MsecAdmin makes all of them work and nobody has to know which consent
        belongs to which command. Pass it explicitly for a least-privilege session covering only
        what you intend to do.

    .PARAMETER TenantId
        Tenant to sign in to. Defaults to the tenant Connect-Msec is using, which is almost
        always what you want.

    .PARAMETER PassThru
        Emit the Graph context as well as the summary.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec      # reads, as the app
        Connect-MsecAdmin                        # writes, as you

    .EXAMPLE
        # Only what this session needs.
        Connect-MsecAdmin -Scope SecurityAlert.ReadWrite.All

    .OUTPUTS
        One PSCustomObject describing the session: Account, TenantId, GrantedScope.

    .NOTES
        Needs the Microsoft.Graph.Authentication module, which is NOT a dependency of msec -
        it is only required by the write commands.

        Disconnect with Disconnect-MgGraph. Connect-Msec and this session are independent;
        disconnecting one leaves the other alone.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        # THE DEFAULT IS EVERY SCOPE THE MODULE'S WRITE COMMANDS NEED, so one connection makes
        # all of them work. The alternative - defaulting to a subset - means knowing which scope
        # a given command wants before you can run it, and discovering you guessed wrong only
        # when the write fails. Nobody should have to remember that resolving an incident and
        # creating a detection rule are different consents.
        #
        # ADDING A WRITE COMMAND MEANS ADDING ITS SCOPE HERE. Pass -Scope explicitly for a
        # least-privilege session covering only what you intend to do.
        #
        #   SecurityAlert.ReadWrite.All      Set-MsecDefenderAlert
        #   SecurityIncident.ReadWrite.All   Set-MsecDefenderIncident
        #   CustomDetection.ReadWrite.All    New-MsecDefenderDetectionRule
        [string[]] $Scope = @(
            'SecurityIncident.ReadWrite.All'
            'SecurityAlert.ReadWrite.All'
            'CustomDetection.ReadWrite.All'
        ),

        [string] $TenantId,

        [switch] $PassThru
    )

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Microsoft.Graph.Authentication is required for Connect-MsecAdmin. Install with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    # Default to the tenant being READ, so a write cannot land somewhere else by accident.
    if (-not $TenantId -and $script:MsecSession -and $script:MsecSession.TenantId) {
        $TenantId = $script:MsecSession.TenantId
    }

    $connectArgs = @{ Scopes = $Scope; NoWelcome = $true; ErrorAction = 'Stop' }
    if ($TenantId) { $connectArgs['TenantId'] = $TenantId }

    Connect-MgGraph @connectArgs

    $context = Get-MgContext
    if (-not $context) { throw 'Connect-MgGraph returned no context. The sign-in did not complete.' }

    # See the help: a declined scope is not an error, it is an absence.
    $granted = @($context.Scopes)
    $missing = @($Scope | Where-Object { $_ -notin $granted })
    if ($missing.Count) {
        throw ("Signed in as $($context.Account), but the tenant did not grant: $($missing -join ', '). " +
               "Connect-MgGraph does not fail on a declined scope - it returns a context without it, and the " +
               "first write would 403 naming nothing. An administrator must consent these for the Microsoft " +
               "Graph PowerShell application. Granted: $($granted -join ', ')")
    }

    # Reading one tenant and writing to another is silently wrong rather than loudly broken.
    if ($script:MsecSession -and $script:MsecSession.TenantId -and
        $context.TenantId -and $context.TenantId -ne $script:MsecSession.TenantId) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        throw ("Connect-Msec is reading tenant $($script:MsecSession.TenantId) but this sign-in landed on " +
               "$($context.TenantId). Refusing rather than writing to a different tenant than you are reading. " +
               'Pass -TenantId explicitly if that is genuinely what you intend.')
    }

    $script:MsecAdminSession = [PSCustomObject]@{
        PSTypeName   = 'MsecAdminSession'
        Account      = [string] $context.Account
        TenantId     = [string] $context.TenantId
        GrantedScope = $granted
        ConnectedUtc = [datetime]::UtcNow
    }

    Write-Verbose "Write session established as $($context.Account) in tenant $($context.TenantId)."

    $script:MsecAdminSession
    if ($PassThru) { $context }
}
