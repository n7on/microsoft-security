function Get-MsecEnvironment {
    <#
    .SYNOPSIS
        Resolves the cloud-specific endpoints msec needs (AAD authority, Microsoft Graph,
        Key Vault, ARM, Defender) for an Azure environment, derived from Get-AzEnvironment
        so commercial, Azure China (Mooncake), and US Gov all work without per-cloud
        branches scattered through the module.

    .DESCRIPTION
        With no -Name, uses the current Az context's environment, defaulting to
        'AzureCloud' when the context doesn't name one (keeps behaviour identical to the
        old hardcoded module for commercial callers and for unit tests with a bare mocked
        context). All endpoints have trailing slashes trimmed so callers can concatenate
        a leading-slash path safely.

        Microsoft Graph's endpoint comes from the environment's ExtendedProperties on
        modern Az.Accounts, with a per-cloud fallback for older Az. Defender for Endpoint
        (securitycenter) has no Get-AzEnvironment property and is commercial-only - it is
        $null in sovereign clouds (e.g. retired in Azure China), so callers fail with a
        clear message instead of hitting a dead host.

    .PARAMETER Name
        Azure environment name (e.g. 'AzureCloud', 'AzureChinaCloud', 'AzureUSGovernment').
        Defaults to the current Az context's environment.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $Name
    )

    if (-not $Name) {
        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        $Name = if ($ctx -and $ctx.Environment) { $ctx.Environment } else { 'AzureCloud' }
    }

    $env = Get-AzEnvironment -Name $Name -ErrorAction Stop
    if (-not $env) {
        throw "Unknown Azure environment '$Name'. Connect with Connect-AzAccount -Environment <name> first."
    }

    # Microsoft Graph: present in ExtendedProperties on modern Az; fall back per cloud.
    $graph = $null
    if ($env.ExtendedProperties -and $env.ExtendedProperties.ContainsKey('MicrosoftGraphUrl')) {
        $graph = $env.ExtendedProperties['MicrosoftGraphUrl']
    }
    if (-not $graph) {
        $graph = switch ($Name) {
            'AzureChinaCloud'   { 'https://microsoftgraph.chinacloudapi.cn' }
            'AzureUSGovernment' { 'https://graph.microsoft.us' }
            default             { 'https://graph.microsoft.com' }
        }
    }

    # Defender for Endpoint (securitycenter) is commercial-only here.
    $defender = if ($Name -eq 'AzureCloud') { 'https://api.securitycenter.microsoft.com' } else { $null }

    [pscustomobject]@{
        EnvironmentName   = $Name
        AadAuthority      = $env.ActiveDirectoryAuthority.TrimEnd('/')
        GraphResource     = $graph.TrimEnd('/')
        DefenderResource  = $defender
        KeyVaultResource  = $env.AzureKeyVaultServiceEndpointResourceId.TrimEnd('/')
        KeyVaultDnsSuffix = $env.AzureKeyVaultDnsSuffix
        ArmResource       = $env.ResourceManagerUrl.TrimEnd('/')
    }
}
