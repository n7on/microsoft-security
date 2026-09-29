function Resolve-MsecPurviewLocation {
    <#
    .SYNOPSIS
        Turns a DLP location ArrayList into a readable scope plus a count.

    .DESCRIPTION
        These properties are collections of location objects, and stringifying one produces a
        space-joined wall of fifty Teams names that is unreadable in a table and unusable in a
        filter. Worse, 'All' arrives as an ordinary member of that list rather than as a flag, so
        "all of SharePoint" and "one site called All" look identical until you look at the type.

        Returns a hashtable: Scope ('All', 'None', or 'Named'), Count, and Names.

        Count is the number of NAMED locations and is 0 when Scope is 'All' - an estate-wide
        policy has no list to count. Do not read Count as coverage.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        $Location
    )

    $items = @($Location)
    if (-not $items.Count) {
        return @{ Scope = 'None'; Count = 0; Names = @() }
    }

    $names = @($items | ForEach-Object {
        if ($_.DisplayName) { [string] $_.DisplayName } else { [string] $_.Name }
    } | Where-Object { $_ })

    if ($names -contains 'All') {
        return @{ Scope = 'All'; Count = 0; Names = @('All') }
    }

    @{ Scope = 'Named'; Count = $names.Count; Names = $names }
}
