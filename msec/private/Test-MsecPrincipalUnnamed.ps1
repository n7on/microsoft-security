function Test-MsecPrincipalUnnamed {
    <#
    .SYNOPSIS
        True when Graph returned a principal it would not name - an id-and-type
        shell rather than a readable object.

    .DESCRIPTION
        Graph answers a read the caller is not entitled to by returning the
        object's full property SCHEMA with every value null, not by failing. So an
        app holding 'RoleManagement.Read.Directory' but not 'User.Read.All' gets
        every role assignment and no names at all: a report that is complete and
        entirely anonymous.

        Privilege held by an identity the app cannot name must not be presented as
        a blank cell in an access review - an unnamed administrator has to read as
        an unknown. Callers turn this into IsResolved = $false and count the
        occurrences so the run can say so out loud.

        A missing principal ($null) counts as unnamed: there is certainly no name
        in it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $Principal
    )

    if (-not $Principal) { return $true }

    switch (Get-MsecPrincipalObjectType $Principal) {
        # A user is named by its UPN; displayName can be set on an object whose
        # UPN the app still cannot read, so it is not evidence of a readable user.
        'user'  { return (-not $Principal.userPrincipalName) }
        default { return (-not $Principal.displayName) }
    }
}
