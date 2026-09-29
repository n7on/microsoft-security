function Get-MsecTenantDomain {
    <#
    .SYNOPSIS
        The tenant's default verified domain, read from Graph.

    .DESCRIPTION
        Connect-ExchangeOnline and Connect-IPPSSession both want an -Organization that the
        caller rarely has to hand, and getting it wrong produces a routing error rather than an
        auth one. The app already holds Organization.Read.All, so asking Graph costs nothing
        and removes a required argument from both.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $org = (Invoke-MsecGraphRequest -Path '/v1.0/organization').value[0]
        $domain = @($org.verifiedDomains | Where-Object { $_.isDefault })[0].name
    }
    catch {
        throw "Could not resolve the tenant domain from Graph, so -Organization must be given explicitly: $(Get-MsecGraphErrorMessage $_)"
    }

    if (-not $domain) { throw 'Graph returned no default verified domain. Pass -Organization explicitly.' }
    [string] $domain
}
