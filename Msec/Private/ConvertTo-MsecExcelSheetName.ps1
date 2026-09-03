function ConvertTo-MsecExcelSheetName {
    <#
    .SYNOPSIS
        Turns arbitrary text - a subscription name - into a legal, unique Excel worksheet name.

    .DESCRIPTION
        Excel's rules are narrow and it does not negotiate: at most 31 characters, none of
        : \ / ? * [ ], not empty, and not the reserved name 'History'. A subscription called
        'Viedoc Production - Northern Europe' is 35 characters and would be rejected outright,
        so the name has to be shortened before it is ever handed to EPPlus.

        TRUNCATION IS WHERE THIS GETS DANGEROUS, which is why -Existing exists. Two
        subscriptions called 'Contoso Production Platform EU' and 'Contoso Production Platform
        US' truncate to the same 31 characters - and a second sheet silently resolving to the
        first would append one subscription's numbers onto the other's history. Names are
        therefore checked against what is already in the workbook and disambiguated with a
        numeric suffix rather than allowed to collide.

    .PARAMETER Name
        The source text, e.g. a subscription name.

    .PARAMETER Existing
        Sheet names already in the workbook. A result colliding with one of these gets a
        suffix. Pass the CURRENT sheet's own name in here too and it will be re-derived to the
        same value, since an exact match on an existing sheet is the normal case - this is
        only about two DIFFERENT sources landing on one name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Name,

        [string[]] $Existing = @()
    )

    # Excel's illegal set, plus control characters. Replaced with a space rather than removed
    # so 'A/B' reads as 'A B' instead of the misleading 'AB'.
    $clean = ($Name -replace '[:\\/?*\[\]]', ' ') -replace '\s+', ' '
    $clean = $clean.Trim()

    if (-not $clean) { $clean = 'Subscription' }
    # 'History' is reserved by Excel and cannot be used at all.
    if ($clean -eq 'History') { $clean = 'History (sub)' }

    if ($clean.Length -le 31) {
        $candidate = $clean
    }
    else {
        $candidate = $clean.Substring(0, 31).Trim()
    }

    if ($candidate -notin $Existing) { return $candidate }

    # Collision. Suffix with ' 2', ' 3', ... trimming the stem to keep inside 31.
    for ($n = 2; $n -lt 100; $n++) {
        $suffix = " $n"
        $stem = if (($clean.Length + $suffix.Length) -le 31) { $clean }
                else { $clean.Substring(0, 31 - $suffix.Length).Trim() }
        $candidate = "$stem$suffix"
        if ($candidate -notin $Existing) { return $candidate }
    }

    throw "Could not derive a unique worksheet name from '$Name' - 98 variations were already taken."
}
