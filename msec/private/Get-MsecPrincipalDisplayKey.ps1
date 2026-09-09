function Get-MsecPrincipalDisplayKey {
    <#
    .SYNOPSIS
        The identifier to show for a principal: its UPN if it has one, else its
        display name, else the id.

    .DESCRIPTION
        Resolved by type rather than by column, so one column can carry the
        identifier for users, groups and service principals without becoming
        ambiguous - a user is named by userPrincipalName, and nothing else has
        one. The matching *Type column on the row says which kind you are
        reading.

        The id fallback exists so a row is never nameless: an object the app may
        enumerate but not read comes back with every property null, and printing
        a blank cell in an access review is worse than printing a GUID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $Principal,

        [Parameter(Position = 1)]
        [string] $FallbackId
    )

    if ($Principal.userPrincipalName) { return $Principal.userPrincipalName }
    if ($Principal.displayName)       { return $Principal.displayName }
    return $FallbackId
}
