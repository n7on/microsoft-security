function Get-MsecPurviewInformationBarrier {
    <#
    .SYNOPSIS
        Information barrier policies - who is prevented from communicating with whom.

    .DESCRIPTION
        Information barriers stop defined groups of people contacting each other in Teams,
        SharePoint and OneDrive. Most tenants have none, and that is a legitimate answer: they
        exist for regulated separation - trading desks, or clinical staff who must not see each
        other's material. Reporting the absence is the point, because "we have no barriers" is a
        decision when it is deliberate and a gap when it is not, and the two look identical until
        someone asks.

        STATE IS NOT THE SAME AS ACTIVE. A barrier policy is authored inactive and only takes
        effect once applied, so an Inactive policy protects nothing while still appearing in a
        policy count.

        LIKE THE AUTO-LABELING COMMAND, THIS PROJECTION IS UNVERIFIED AGAINST LIVE DATA - it was
        written on a tenant with no barrier policies. Missing properties resolve to $null rather
        than erroring, and Raw keeps the untouched object.

    .PARAMETER Name
        Limit to policies whose name matches. Wildcards allowed.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecPurviewInformationBarrier | Format-Table Name, State, AssignedSegment

    .OUTPUTS
        One PSCustomObject per policy, PSTypeName 'MsecPurviewInformationBarrier'. No rows means
        no barriers are defined.

    .NOTES
        Needs Connect-Msec; the compliance session opens on first use. Read-only.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [string] $Name
    )

    Initialize-MsecExoSession -Endpoint Compliance
    Assert-MsecExoCmdlet -Name 'Get-InformationBarrierPolicy' -Feature 'information barrier policies'

    $policies = @(Get-InformationBarrierPolicy -ErrorAction Stop)
    if ($Name) { $policies = @($policies | Where-Object { $_.Name -like $Name }) }

    foreach ($policy in $policies) {
        [PSCustomObject]@{
            PSTypeName      = 'MsecPurviewInformationBarrier'
            Name            = [string] $policy.Name
            State           = [string] $policy.State
            # Authored and applied are different things - see the help.
            IsActive        = ([string] $policy.State -eq 'Active')
            AssignedSegment = [string] $policy.AssignedSegment
            SegmentsAllowed = @($policy.SegmentsAllowed | ForEach-Object { [string] $_ })
            SegmentsBlocked = @($policy.SegmentsBlocked | ForEach-Object { [string] $_ })
            Comment         = [string] $policy.Comment
            WhenChangedUtc  = $policy.WhenChanged
            Raw             = $policy
        }
    }
}
