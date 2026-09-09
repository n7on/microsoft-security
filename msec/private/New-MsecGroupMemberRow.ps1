function New-MsecGroupMemberRow {
    <#
    .SYNOPSIS
        Projects one Graph directory object into a Get-MsecEntraGroupMember row.

    .DESCRIPTION
        Shared by the members read and the PIM-eligible read, so an eligible member is
        described exactly the same way an active one is and the two are comparable in the
        same table. Only MembershipType differs, which is the point.

    .PARAMETER Common
        The group columns repeated on every row - name, id, type - so a row stands alone when
        several groups are in one table.

    .PARAMETER Member
        The directory object from Graph.

    .PARAMETER MembershipType
        'Active' for a real member, 'Eligible' for one who has to activate through PIM first.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Common,
        [Parameter(Mandatory)] $Member,
        [Parameter(Mandatory)] [ValidateSet('Active', 'Eligible')] [string] $MembershipType
    )

    # '#microsoft.graph.user' -> 'user'. A cast or an $expand can omit @odata.type entirely,
    # in which case the type is genuinely unknown rather than absent-meaning-user - saying
    # 'user' here would silently mislabel every service principal in that response.
    $type = [string] $Member.'@odata.type'
    $type = if ($type) { $type -replace '^#microsoft\.graph\.', '' } else { 'unknown' }

    [PSCustomObject]($Common + [ordered]@{
        PSTypeName              = 'MsecEntraGroupMember'
        MemberName              = $Member.displayName
        MemberUserPrincipalName = $Member.userPrincipalName
        MemberType              = $type
        MemberId                = $Member.id
        MembershipType          = $MembershipType
        AccountEnabled          = $Member.accountEnabled
        UserType                = $Member.userType
        OnPremisesSyncEnabled   = $Member.onPremisesSyncEnabled
        Raw                     = $Member
    })
}
