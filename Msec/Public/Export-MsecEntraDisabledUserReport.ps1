function Export-MsecEntraDisabledUserReport {
    <#
    .SYNOPSIS
        Evidence of every disabled ("archived") account in the tenant - one row per account,
        how long it has been disabled, and what it still costs in licences.

    .DESCRIPTION
        The same evidence shape as the VM reports: one row per subject, a worksheet named after
        the tenant, a shared Summary counting them by category, and a chart per tenant. A
        snapshot, not a trend - nothing is appended, and a sheet written twice is replaced.

        Rows come from Get-MsecEntraDisabledUser, so everything it knows about the limits of
        the answer applies here and is carried into the table rather than smoothed over.

        THE AGE BUCKET IS THE CATEGORY, AND 'Unknown' IS ONE OF THEM. Entra stores no
        disabledDateTime; the date comes from the directory audit log, which retains 30 days on
        P1/P2 and 7 on the free tier. An account disabled inside that window gets an exact
        date, and one disabled before it gets a bracket - so its bucket is genuinely unknown,
        not zero and not recent. Lumping those in with '< 30 days' would be the one reading
        that is certainly wrong, since anything the audit log cannot see is OLDER than the
        window, never newer.

        THE CHART COUNTS TWICE PER BUCKET: accounts, and how many of those still hold licences.
        A disabled account with licences assigned is both spend and standing attack surface, and
        it is the finding most likely to get acted on - so it belongs in the picture rather than
        only in a column.

    .PARAMETER Path
        The .xlsx to write. Created if absent; an existing file is added to rather than
        replaced, so several tenants can share one document.

    .PARAMETER Days
        How far back to search the audit log for the disable event, passed through to
        Get-MsecEntraDisabledUser. Default 30, the P1/P2 retention ceiling. Drop to 7 on a
        free-tier tenant - asking for more cannot find more.

    .PARAMETER UserType
        'Member', 'Guest' or 'All'. Default All. A disabled guest is usually a finished
        engagement nobody cleaned up, which is worth being able to separate.

    .PARAMETER TableStyle
        Excel table style. One of Light1-21, Medium1-28 or Dark1-11. Default Medium2.

    .PARAMETER ChartWidth
        Chart width in pixels, default 600 - sized to paste into an A4 portrait Word page.

    .PARAMETER ChartHeight
        Chart height in pixels, default 370.

    .PARAMETER Force
        Replace an existing worksheet without asking. A snapshot report REPLACES rather than
        appends, so writing to a path that already holds this subject's evidence discards it -
        which is worth a question when the path was a typo, and worth suppressing when the run
        is scheduled. Unattended runs need this: there is no one to answer the prompt.
    .PARAMETER PassThru
        Emit the per-account rows as objects as well as writing them.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Export-MsecEntraDisabledUserReport -Path "./disabled-users-$(Get-Date -Format 'yyyy-MM-dd').xlsx"

    .EXAMPLE
        # The rows a reviewer will ask about: dead accounts still holding licences.
        Export-MsecEntraDisabledUserReport -Path ./evidence.xlsx -PassThru |
            Where-Object LicenseCount -gt 0 |
            Sort-Object LicenseCount -Descending |
            Format-Table UserPrincipalName, DisabledFor, LicenseCount, LastSuccessfulSignIn

    .OUTPUTS
        With -PassThru, one PSCustomObject per disabled account, PSTypeName
        'MsecEntraDisabledUserEvidence'.

    .NOTES
        Needs Connect-Msec - this is Graph, so no Az context is involved, unlike the VM
        reports. User.Read.All and AuditLog.Read.All, both of which New-MsecApp already grants.

        The tenant's display name is read from /organization to name the worksheet. If that
        call fails the tenant id is used instead, which is ugly but unambiguous.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Path,

        [ValidateRange(1, 30)]
        [int] $Days = 30,

        [ValidateSet('Member', 'Guest', 'All')]
        [string] $UserType = 'All',

        [string] $TableStyle = 'Medium2',

        [ValidateRange(200, 2000)]
        [int] $ChartWidth = 600,

        [ValidateRange(150, 1200)]
        [int] $ChartHeight = 370,

        [switch] $PassThru,

        [switch] $Force
    )

    Assert-MsecSession

    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        throw 'ImportExcel is required for Export-MsecEntraDisabledUserReport. Install with: Install-Module ImportExcel -Scope CurrentUser'
    }
    Import-Module ImportExcel -ErrorAction Stop

    if (-not ($TableStyle -as [OfficeOpenXml.Table.TableStyles])) {
        throw "'$TableStyle' is not an Excel table style. Use one of Light1-21, Medium1-28 or Dark1-11 (for example Medium2, the default)."
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Collect disabled accounts and write the evidence sheet')) {
        return
    }

    $tenantId = $script:MsecSession.TenantId
    $collectedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')

    # A GUID makes a legal worksheet name and a useless one, so the display name is preferred.
    # Best effort: a failure here costs readability, not the report.
    $tenantName = $tenantId
    try {
        $organisation = Invoke-MsecGraphRequest -Path '/v1.0/organization?$select=id,displayName'
        $name = @($organisation.value)[0].displayName
        if ($name) { $tenantName = $name }
    }
    catch {
        Write-Verbose "Could not read the tenant display name, using the id: $($_.Exception.Message)"
    }

    # BEFORE ANYTHING IS COLLECTED, so declining costs nothing rather than throwing away a
    # full directory enumeration.
    if (-not (Confirm-MsecEvidenceOverwrite -Path $Path -OwnerName $tenantName -OwnerId $tenantId `
                  -OwnerColumn 'TenantId' -Cmdlet $PSCmdlet -Force:$Force)) {
        return
    }

    # ---- collect ------------------------------------------------------------------------------

    $users = @(Get-MsecEntraDisabledUser -Days $Days -UserType $UserType)

    if (-not $users.Count) {
        Write-Warning "No disabled accounts found in '$tenantName'. Nothing to report."
        return
    }

    # Oldest first, so the chart reads as an aging curve left to right. 'Unknown' last because
    # it is not a point on that curve - see the note in the help.
    $bucketOrder = @('Under 30 days', '30 to 90 days', '90 to 365 days', 'Over 365 days', 'Unknown')

    $rows = foreach ($user in $users) {
        # DisabledDays is exact when the audit log had the event. Beyond retention there is a
        # bracket instead, and DisabledAtLeastDays is its lower bound - enough to place the
        # account in a bucket whenever the bracket does not straddle one.
        # NOT $days: PowerShell is case-insensitive, so that IS the -Days parameter, and its
        # ValidateRange(1,30) then rejects any account disabled longer than the audit window -
        # which is most of them. Same trap as a loop variable shadowing a typed parameter.
        $disabledDays = $user.DisabledDays
        $atLeast = $user.DisabledAtLeastDays
        $atMost = $user.DisabledAtMostDays

        $bucket =
            if ($null -ne $disabledDays) {
                if     ($disabledDays -lt 30)  { 'Under 30 days' }
                elseif ($disabledDays -lt 90)  { '30 to 90 days' }
                elseif ($disabledDays -lt 365) { '90 to 365 days' }
                else                   { 'Over 365 days' }
            }
            # No exact date. The bracket can still place it when BOTH ends fall in one bucket -
            # 'at least 30, at most 60' is squarely 30-to-90. Where the bracket straddles a
            # boundary the honest answer is Unknown rather than a coin toss.
            elseif ($null -ne $atMost -and $atMost -lt 90 -and $atLeast -ge 30) { '30 to 90 days' }
            elseif ($null -ne $atMost -and $atMost -lt 365 -and $atLeast -ge 90) { '90 to 365 days' }
            elseif ($null -ne $atLeast -and $atLeast -ge 365) { 'Over 365 days' }
            else { 'Unknown' }

        [pscustomobject]@{
            PSTypeName            = 'MsecEntraDisabledUserEvidence'
            UserPrincipalName     = $user.UserPrincipalName
            DisplayName           = $user.DisplayName
            DisabledFor           = $bucket
            LicenseCount          = $user.LicenseCount
            UserType              = $user.UserType
            Department            = $user.Department
            JobTitle              = $user.JobTitle
            DisabledSince         = $user.DisabledSince
            DisabledDays          = $disabledDays
            DisabledBy            = $user.DisabledBy
            DisabledAtLeastDays   = $atLeast
            DisabledAtMostDays    = $atMost
            DisabledSource        = $user.DisabledSource
            LastSuccessfulSignIn  = $user.LastSuccessfulSignIn
            LastSignIn            = $user.LastSignIn
            LastPasswordChange    = $user.LastPasswordChange
            LastDirectoryChange   = $user.LastDirectoryChange
            OnPremisesSyncEnabled = $user.OnPremisesSyncEnabled
            OnPremisesLastSync    = $user.OnPremisesLastSync
            CreatedDateTime       = $user.CreatedDateTime
            Id                    = $user.Id
            TenantName            = $tenantName
            TenantId              = $tenantId
            CollectedUtc          = $collectedUtc
        }
    }
    $rows = @($rows)

    # Oldest and least-known first, then licensed accounts ahead of unlicensed within a bucket:
    # a reviewer scanning the table should meet the expensive, long-dead accounts immediately.
    $rows = @($rows | Sort-Object `
        @{ Expression = { [array]::IndexOf($bucketOrder, $_.DisabledFor) }; Descending = $true },
        @{ Expression = 'LicenseCount'; Descending = $true },
        UserPrincipalName)

    # ---- write ---------------------------------------------------------------------------------

    $count = Write-MsecEvidenceWorkbook -Path $Path `
        -OwnerName $tenantName -OwnerId $tenantId -OwnerColumn 'TenantId' `
        -Row $rows `
        -CategoryProperty 'DisabledFor' -CategoryOrder $bucketOrder `
        -OwnerLabel 'Tenant' -CategoryLabel 'DisabledFor' `
        -Count ([ordered]@{
            Accounts = { $true }
            Licensed = { $_.LicenseCount -gt 0 }
        }) `
        -Heading 'Disabled account evidence' -ChartTitlePrefix 'Disabled accounts by age' `
        -CollectedUtc $collectedUtc `
        -TableStyle $TableStyle -ChartWidth $ChartWidth -ChartHeight $ChartHeight

    $licensed = @($rows | Where-Object { $_.LicenseCount -gt 0 })
    if ($licensed.Count) {
        Write-Warning "$($licensed.Count) of $count disabled account(s) still hold licences, totalling $((($licensed | Measure-Object -Property LicenseCount -Sum).Sum)) assignments."
    }

    if ($PassThru) { $rows }
}
