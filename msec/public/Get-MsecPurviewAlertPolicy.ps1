function Get-MsecPurviewAlertPolicy {
    <#
    .SYNOPSIS
        Purview alert policies - the detection layer that decides what anyone ever hears about.

    .DESCRIPTION
        Every other Purview command here reports what is PREVENTED. This one reports what is
        NOTICED, and it is the part people forget to check: a disabled alert policy is silent in
        exactly the way a working one is, so the gap is invisible until an incident review asks
        why nobody was told. Measured on one tenant: 65 policies, 7 of them disabled, including
        "Shared files externally" and "User copies a file with sensitive data to a removable
        drive".

        IsEnabled IS THE INVERSE OF THE RAW PROPERTY. The service stores Disabled; reading it
        straight means every filter reads backwards, and `Where-Object Disabled` quietly returns
        the healthy ones. Both are on the row, with IsEnabled first, because a positive name is
        the one people filter on correctly.

        SYSTEM RULES ARE MOST OF THE LIST AND ARE NOT YOUR CONFIGURATION. Microsoft ships the
        majority of these; IsSystemRule separates them from the ones your organisation added, and
        -CustomOnly narrows to the latter. A count that mixes them tells you nothing about how
        much alerting anyone here actually set up.

        NotificationEnabled IS NOT WHETHER THE ALERT FIRES. It controls whether an email goes
        out. An enabled policy with notifications off still raises the alert in the portal and
        still tells nobody - worth checking separately from IsEnabled, and the reason both are
        columns.

    .PARAMETER Name
        Limit to policies whose name matches. Wildcards allowed.

    .PARAMETER Category
        Limit to one category, e.g. ThreatManagement or DataLossPrevention.

    .PARAMETER CustomOnly
        Only policies your organisation created, excluding Microsoft's built-ins.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecPurviewAlertPolicy | Group-Object Category | Sort-Object Count -Descending

    .EXAMPLE
        # Detection that has been switched off - silent in the same way a working policy is.
        Get-MsecPurviewAlertPolicy | Where-Object { -not $_.IsEnabled } |
            Format-Table Name, Category, Severity, IsSystemRule

    .EXAMPLE
        # Enabled, but nobody is told.
        Get-MsecPurviewAlertPolicy |
            Where-Object { $_.IsEnabled -and -not $_.NotificationEnabled -and -not $_.IsSystemRule }

    .OUTPUTS
        One PSCustomObject per alert policy, PSTypeName 'MsecPurviewAlertPolicy'.

    .NOTES
        Needs Connect-Msec; the compliance session opens on first use. Read-only.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [string] $Name,

        [Parameter()]
        [string] $Category,

        [Parameter()]
        [switch] $CustomOnly
    )

    Initialize-MsecExoSession -Endpoint Compliance
    Assert-MsecExoCmdlet -Name 'Get-ProtectionAlert' -Feature 'Purview alert policies'

    $alerts = @(Get-ProtectionAlert -ErrorAction Stop)
    if ($Name)     { $alerts = @($alerts | Where-Object { $_.Name -like $Name }) }
    if ($Category) { $alerts = @($alerts | Where-Object { [string] $_.Category -eq $Category }) }
    if ($CustomOnly) { $alerts = @($alerts | Where-Object { -not $_.IsSystemRule }) }

    foreach ($alert in $alerts) {
        [PSCustomObject]@{
            PSTypeName          = 'MsecPurviewAlertPolicy'
            Name                = [string] $alert.Name
            Category            = [string] $alert.Category
            Severity            = [string] $alert.Severity
            # Positive form first - see the help. Disabled is kept so nothing is hidden.
            IsEnabled           = (-not [bool] $alert.Disabled)
            Disabled            = [bool] $alert.Disabled
            # Microsoft's own, or something this organisation set up.
            IsSystemRule        = [bool] $alert.IsSystemRule
            # Whether anyone is EMAILED. An enabled policy with this off still tells nobody.
            NotificationEnabled = [bool] $alert.NotificationEnabled
            NotifyUser          = @($alert.NotifyUser | ForEach-Object { [string] $_ })
            Mode                = [string] $alert.Mode
            ThreatType          = [string] $alert.ThreatType
            Operation           = [string] $alert.Operation
            AggregationType     = [string] $alert.AggregationType
            Threshold           = $alert.Threshold
            Workload            = [string] $alert.Workload
            CreatedBy           = [string] $alert.CreatedBy
            WhenChangedUtc      = $alert.WhenChangedUTC
            Comment             = [string] $alert.Comment
        }
    }
}
