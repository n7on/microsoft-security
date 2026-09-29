function Get-MsecExoConnection {
    <#
    .SYNOPSIS
        Live ExchangeOnlineManagement connections to one endpoint.

    .DESCRIPTION
        ExchangeOnlineManagement serves two different services from one module and they are
        distinguishable only by URI, so a loose check lets an Exchange session satisfy a
        requirement for a Compliance one - and the failure then lands later as a missing-cmdlet
        error naming nothing.

        IT DOES NOT USE Get-Command. Asking whether Get-EXOMailbox exists answers whether the
        MODULE IS INSTALLED, not whether anything is connected: it returns true on a machine
        that has never signed in, and every call after it fails on transport instead.

        The URI carries a regional prefix (eur01b.ps.compliance.protection.outlook.com), so the
        match is deliberately a substring rather than an equality.

    .PARAMETER Endpoint
        Exchange (outlook.office365.com) or Compliance (ps.compliance.protection.outlook.com).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Exchange', 'Compliance')]
        [string] $Endpoint
    )

    if (-not (Get-Command Get-ConnectionInformation -ErrorAction SilentlyContinue)) { return @() }

    $connections = @()
    try { $connections = @(Get-ConnectionInformation -ErrorAction Stop) } catch { return @() }

    $pattern = if ($Endpoint -eq 'Compliance') { 'compliance\.protection\.outlook' } else { 'outlook\.office365\.com' }
    @($connections | Where-Object { "$($_.ConnectionUri)" -match $pattern })
}
