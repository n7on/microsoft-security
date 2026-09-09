function Export-MsecEntraGroupMemberReport {
    <#
    .SYNOPSIS
        Evidence of who is in which Entra group - one worksheet per group, a Summary comparing
        them, and a chart of the membership mix.

    .DESCRIPTION
        A snapshot, not a trend: nothing is appended, and a group written twice is replaced.
        Rows come from Get-MsecEntraGroupMember, so everything it knows about the limits of the
        answer applies here and is carried into the table rather than smoothed over.

        ONE WORKSHEET PER GROUP, named after it, holding that group's members. The Summary
        sheet has one row per group instead, which is the sheet a reviewer actually reads
        first - how big each group is, how much of it is standing rather than PIM-eligible, and
        how much of it is guests or service principals.

        THE CHART COMPARES GROUPS, not membership types within one group. Groups are the x
        axis, so the question it answers is "which of these is the outlier" - the access group
        that grew, the one that is all guests, the one with a service principal in it. A chart
        per group would be a dozen tiny pictures of a number you can already read in a cell.

        WORKSHEET NAMES ARE NOT GROUP NAMES, quite. Excel allows 31 characters and forbids
        : \ / ? * [ ], so a long group name is truncated and a truncation collision is suffixed
        to keep two groups apart. GroupName and GroupId are columns on every row, so the full
        name is always readable regardless of what the tab says.

        PIM-ELIGIBLE MEMBERS ARE INCLUDED and counted separately, because a group whose
        membership is mostly eligible is a different thing from one where everybody has standing
        access - and a listing that omitted them would report a PIM-governed group as empty.

        AN EMPTY GROUP STILL GETS A WORKSHEET AND A SUMMARY ROW. "Nobody is in it" is a finding,
        and one that disappears if empty groups are skipped. A group whose membership could not
        be read is marked Unreadable rather than reported as empty, and warned about.

    .PARAMETER Path
        The .xlsx to write. Created if absent; an existing file is added to rather than
        replaced, so groups collected in separate runs can share one document.

    .PARAMETER Name
        Group display names, wildcards supported. Passed to Get-MsecEntraGroupMember, so a name
        matching nothing is warned about and a name matching several groups returns all of them.

    .PARAMETER Id
        Group object ids, for when a display name is ambiguous.

    .PARAMETER Recurse
        Expand nested groups, so the people inside them are reported as members of the outer
        group and the nested group itself is not listed. See Get-MsecEntraGroupMember.

    .PARAMETER TableStyle
        Excel table style. One of Light1-21, Medium1-28 or Dark1-11. Default Medium2.

    .PARAMETER ChartWidth
        Chart width in pixels, default 600 - sized to paste into an A4 portrait Word page.

    .PARAMETER ChartHeight
        Chart height in pixels, default 370.

    .PARAMETER Force
        Replace existing worksheets without asking. Unattended runs need this: there is no one
        to answer the prompt.

    .PARAMETER PassThru
        Emit the per-member rows as objects as well as writing them.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Export-MsecEntraGroupMemberReport -Path ./group-members.xlsx -Name 'sg-admins', 'sg-devops'

    .EXAMPLE
        # Every access group, with nested groups expanded to the people actually inside them.
        Export-MsecEntraGroupMemberReport -Path ./access-review.xlsx -Name 'sg-*' -Recurse

    .EXAMPLE
        # The rows a reviewer will ask about: guests and service principals holding access.
        Export-MsecEntraGroupMemberReport -Path ./review.xlsx -Name 'sg-*' -PassThru |
            Where-Object { $_.UserType -eq 'Guest' -or $_.MemberType -eq 'servicePrincipal' } |
            Sort-Object GroupName, MemberName

    .OUTPUTS
        With -PassThru, one PSCustomObject per (group, member) - the rows from
        Get-MsecEntraGroupMember.

    .NOTES
        Needs Connect-Msec, 'Group.Read.All', and
        'PrivilegedEligibilitySchedule.Read.AzureADGroup' for the eligible members.

        THE OVERWRITE PROMPT COMES AFTER THE COLLECTION HERE, unlike the VM reports which ask
        first. Which worksheets are at stake is not knowable until the group names have been
        resolved - '-Name sg-*' could be one group or forty - and reading group membership has
        no side effects, so a declined run costs a Graph read rather than Run Commands against
        live machines.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Path,

        [Parameter(Position = 1)]
        [string[]] $Name,

        [Parameter()]
        [string[]] $Id,

        [Parameter()]
        [Alias('Transitive')]
        [switch] $Recurse,

        [string] $TableStyle = 'Medium2',

        [ValidateRange(200, 2000)]
        [int] $ChartWidth = 600,

        [ValidateRange(150, 1200)]
        [int] $ChartHeight = 370,

        [switch] $Force,

        [switch] $PassThru
    )

    Assert-MsecSession

    if (-not $Name -and -not $Id) {
        throw 'Give at least one -Name or -Id. Exporting every group in the tenant is not the intent here.'
    }

    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        throw 'ImportExcel is required for Export-MsecEntraGroupMemberReport. Install with: Install-Module ImportExcel -Scope CurrentUser'
    }
    Import-Module ImportExcel -ErrorAction Stop

    if (-not ($TableStyle -as [OfficeOpenXml.Table.TableStyles])) {
        throw "'$TableStyle' is not an Excel table style. Use one of Light1-21, Medium1-28 or Dark1-11 (for example Medium2, the default)."
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Collect Entra group members and write the evidence sheets')) {
        return
    }

    $collectedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')

    # ---- collect ------------------------------------------------------------------------------

    $forward = @{}
    if ($Name)    { $forward['Name']    = $Name }
    if ($Id)      { $forward['Id']      = $Id }
    if ($Recurse) { $forward['Recurse'] = $true }

    $rows = @(Get-MsecEntraGroupMember @forward)

    if (-not $rows.Count) {
        Write-Warning 'No groups matched, so there is nothing to report.'
        return
    }

    foreach ($row in $rows) {
        $row | Add-Member -NotePropertyName 'CollectedUtc' -NotePropertyValue $collectedUtc -Force
    }

    # Grouped by ID, not by name: two groups can share a display name, and merging them would
    # put two different groups' members on one sheet under one heading.
    $byGroup = @($rows | Group-Object -Property GroupId | Sort-Object { $_.Group[0].GroupName })

    # ---- confirm ------------------------------------------------------------------------------
    #
    # Asked ONCE for the whole run rather than once per group: a wildcard can match forty
    # groups, and forty prompts is a prompt nobody reads.

    $owners = @($byGroup | ForEach-Object {
        [pscustomobject]@{ Name = [string] $_.Group[0].GroupName; Id = [string] $_.Name }
    })

    if (-not (Confirm-MsecEvidenceOverwrite -Path $Path -Owner $owners -OwnerColumn 'GroupId' `
                  -Cmdlet $PSCmdlet -Force:$Force)) {
        return
    }

    # ---- write --------------------------------------------------------------------------------

    $existingSheets = @()
    if (Test-Path -LiteralPath $Path) {
        $package = Open-ExcelPackage -Path $Path
        try { $existingSheets = @($package.Workbook.Worksheets | ForEach-Object { $_.Name }) }
        finally { Close-ExcelPackage $package -NoSave }
    }

    # Reserved, so a group genuinely called 'Summary' gets suffixed rather than overwriting the
    # sheet the whole report is read from.
    $taken = [System.Collections.Generic.List[string]]::new()
    $taken.Add('Dashboard'); $taken.Add('Summary')

    $summary = [System.Collections.Generic.List[object]]::new()

    foreach ($g in $byGroup) {
        $groupRows = @($g.Group)
        $first     = $groupRows[0]
        $groupName = [string] $first.GroupName
        $groupId   = [string] $g.Name

        # This group's own sheet is replaced, not collided with - the same rule the other
        # evidence reports use.
        $sheet = Resolve-MsecEvidenceSheet -Path $Path -OwnerName $groupName -OwnerId $groupId -OwnerColumn 'GroupId'
        $sheetName = $sheet.SheetName
        if ($sheetName -in $taken) {
            $sheetName = ConvertTo-MsecExcelSheetName -Name $groupName -Existing (@($taken) + $existingSheets)
        }
        $taken.Add($sheetName)

        $tableName = 'tbl' + ($sheetName -replace '[^A-Za-z0-9]', '')
        if ($tableName -eq 'tbl') { $tableName = 'tblGroup' }

        # Real members first, then the placeholder rows an empty or unreadable group carries -
        # a reviewer should meet people, not bookkeeping.
        $ordered = @($groupRows | Sort-Object `
            @{ Expression = { if ($_.MemberType -in 'None', 'Unreadable') { 1 } else { 0 } } },
            @{ Expression = { if ($_.MembershipType -eq 'Eligible') { 1 } else { 0 } } },
            MemberType, MemberName)

        Write-MsecExcelTable -Path $Path -WorksheetName $sheetName -Row $ordered `
                             -TableName $tableName -TableStyle $TableStyle | Out-Null

        $real = @($groupRows | Where-Object { $_.MemberType -notin 'None', 'Unreadable' })

        $summary.Add([pscustomobject]@{
            GroupName         = $groupName
            Worksheet         = $sheetName
            Members           = $real.Count
            Active            = @($real | Where-Object MembershipType -eq 'Active').Count
            Eligible          = @($real | Where-Object MembershipType -eq 'Eligible').Count
            Users             = @($real | Where-Object MemberType -eq 'user').Count
            Guests            = @($real | Where-Object { $_.UserType -eq 'Guest' }).Count
            ServicePrincipals = @($real | Where-Object MemberType -eq 'servicePrincipal').Count
            NestedGroups      = @($real | Where-Object MemberType -eq 'group').Count
            # Disabled and still in an access group: the account cannot sign in today, but the
            # membership survives it being re-enabled.
            Disabled          = @($real | Where-Object { $_.AccountEnabled -eq $false }).Count
            GroupType         = [string] $first.GroupType
            IsRoleAssignable  = [bool] $first.IsRoleAssignable
            Unreadable        = @($groupRows | Where-Object MemberType -eq 'Unreadable').Count -gt 0
            GroupId           = $groupId
            CollectedUtc      = $collectedUtc
        })
    }

    # Other groups' Summary rows are carried over, so groups collected in separate runs can
    # share one document - the same rule as the other evidence reports.
    $existingSummary = @()
    if ($existingSheets -contains 'Summary') {
        try { $existingSummary = @(Import-Excel -Path $Path -WorksheetName 'Summary' -ErrorAction Stop) }
        catch { Write-Verbose "Could not read the existing Summary sheet: $($_.Exception.Message)" }
    }
    $writtenIds = @($summary | ForEach-Object { $_.GroupId })
    $carried = @($existingSummary | Where-Object { $_.GroupId -and $_.GroupId -notin $writtenIds })

    $allSummary = @(@($carried) + @($summary) | Sort-Object GroupName)

    Write-MsecExcelTable -Path $Path -WorksheetName 'Summary' -Row $allSummary `
                         -TableName 'tblSummary' -TableStyle $TableStyle | Out-Null

    # ---- dashboard ----------------------------------------------------------------------------
    #
    # One chart, groups on the x axis. Columns rather than a line: these are unrelated groups,
    # and a line joining them would imply a progression that does not exist.

    $collected = @($allSummary.CollectedUtc | Where-Object { $_ } | Sort-Object -Unique)
    $heading = if ($collected.Count -gt 1) {
        "Entra group membership - collected $($collected[0]) to $($collected[-1]) UTC"
    }
    else {
        "Entra group membership - collected $($collected[0]) UTC"
    }

    Add-MsecExcelDashboard -Path $Path -Heading $heading `
        -ChartWidth $ChartWidth -ChartHeight $ChartHeight -Chart @(
            [pscustomobject]@{
                Sheet     = 'Summary'
                Table     = 'tblSummary'
                XColumn   = 'GroupName'
                Title     = 'Group membership'
                Series    = @('Members', 'Eligible', 'Guests', 'ServicePrincipals', 'Disabled')
                ChartType = 'ColumnClustered'
                ChartName = 'chartGroupMembership'
            })

    # ---- report -------------------------------------------------------------------------------

    $unreadable = @($summary | Where-Object Unreadable)
    if ($unreadable.Count) {
        Write-Warning "$($unreadable.Count) group(s) could not have their membership read and are reported as Unreadable rather than empty: $(($unreadable.GroupName) -join ', ')."
    }

    $empty = @($summary | Where-Object { -not $_.Unreadable -and $_.Members -eq 0 })
    if ($empty.Count) {
        Write-Warning "$($empty.Count) group(s) have no members at all: $(($empty.GroupName) -join ', ')."
    }

    $withGuests = @($summary | Where-Object { $_.Guests -gt 0 -or $_.ServicePrincipals -gt 0 })
    if ($withGuests.Count) {
        Write-Warning "$($withGuests.Count) group(s) contain guests or service principals - members no MFA or Conditional Access policy aimed at employees will cover."
    }

    if ($PassThru) { $rows }
}
