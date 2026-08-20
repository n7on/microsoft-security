function Get-MsecPrincipalObjectType {
    <#
    .SYNOPSIS
        The bare Entra object type of a Graph principal - 'user', 'group',
        'servicePrincipal' - from its '@odata.type'.

    .DESCRIPTION
        Graph returns the type as '#microsoft.graph.user'; every msec row wants
        'user'. One function rather than an inline -replace at each site, so no
        column can end up spelling it the other way - a report saying 'user' in
        one column and '#microsoft.graph.user' in another cannot be filtered with
        a single Where-Object.

        Returns $null for a principal that carries no '@odata.type' at all. That
        happens on a cast query, where the cast implies the type and Graph omits
        it, so callers using OData casts must stamp the type themselves rather
        than rely on this.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $Principal
    )

    if ($Principal -and $Principal.'@odata.type') {
        return ($Principal.'@odata.type' -replace '^#?microsoft\.graph\.', '')
    }
    return $null
}
