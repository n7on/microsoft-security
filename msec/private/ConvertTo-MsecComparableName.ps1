function ConvertTo-MsecComparableName {
    <#
    .SYNOPSIS
        Folds look-alike punctuation so a name typed with a keyboard hyphen can be compared
        with one stored with an en dash.

    .DESCRIPTION
        Intune display names are typed by people, often in a browser on a Mac or pasted from
        Word, so they pick up EN DASH (U+2013), EM DASH (U+2014), curly quotes and non-breaking
        spaces. Those render almost identically to their ASCII counterparts and compare as
        different characters, which produces a name that visibly matches a list and still fails.

        Only punctuation is folded. Letters, digits and case are left alone - this is for
        characters a person cannot tell apart on screen, not for fuzzy matching.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Name)

    $map = @{
        [char]0x2010 = '-'; [char]0x2011 = '-'; [char]0x2012 = '-'   # hyphen, non-breaking hyphen, figure dash
        [char]0x2013 = '-'; [char]0x2014 = '-'; [char]0x2015 = '-'   # en dash, em dash, horizontal bar
        [char]0x2018 = "'"; [char]0x2019 = "'"                        # curly single quotes
        [char]0x201C = '"'; [char]0x201D = '"'                        # curly double quotes
        [char]0x00A0 = ' '; [char]0x2007 = ' '; [char]0x202F = ' '    # non-breaking / figure / narrow spaces
    }

    $builder = [System.Text.StringBuilder]::new()
    foreach ($c in $Name.ToCharArray()) {
        $null = $builder.Append($(if ($map.ContainsKey($c)) { $map[$c] } else { $c }))
    }
    # Trailing and repeated whitespace is invisible too, so it folds with the rest.
    ($builder.ToString() -replace '\s+', ' ').Trim()
}

function Get-MsecConfusableDifference {
    <#
    .SYNOPSIS
        Names the first character that differs between what was typed and what is stored, by
        code point, for an error a reader can act on.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Typed,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Actual
    )

    $limit = [Math]::Min($Typed.Length, $Actual.Length)
    for ($i = 0; $i -lt $limit; $i++) {
        if ($Typed[$i] -ne $Actual[$i]) {
            return ('position {0}: you passed U+{1:X4}, the name has U+{2:X4}' -f ($i + 1), [int]$Typed[$i], [int]$Actual[$i])
        }
    }
    if ($Typed.Length -ne $Actual.Length) { return "length differs: $($Typed.Length) vs $($Actual.Length) characters" }
    'no visible difference'
}