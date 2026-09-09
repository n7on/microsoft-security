function Get-MsecGraphCacheName {
    <#
    .SYNOPSIS
        Cache name for a bundled Resource Graph query's results.

    .DESCRIPTION
        One cache per .kql file: 'graph-loganalytics-all', 'graph-vm-pendingupdates'. Shared by
        Search-MsecAzureResourceGraph, which reads and writes it, and by the completers that read
        it - which is why it is a function rather than a string built in two places that could
        drift apart.

        THE SUBSCRIPTION SCOPE IS DELIBERATELY NOT PART OF THE KEY. A cache per scope would be
        more precise and completely unusable by a completer, which has no idea what scope the
        next call will use. Instead each cache holds the most recent result for that query
        whatever scope produced it, and records that scope in the payload so -UseCache can say
        what it is handing back. A scoped call therefore overwrites an estate-wide result: that
        is a caching decision, and it is the reason -UseCache is opt-in rather than the default.

    .PARAMETER ResourceType
        The Kql/Graph subfolder.

    .PARAMETER Name
        The .kql base name.

    .OUTPUTS
        String, safe for Get-MsecCachePath's name validation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceType,

        [Parameter(Mandatory)]
        [string] $Name
    )

    # Folder and file names are alphanumeric by convention, so lowercasing is enough to satisfy
    # Get-MsecCachePath. Anything else is rejected there rather than silently mangled here.
    'graph-{0}-{1}' -f $ResourceType.ToLowerInvariant(), $Name.ToLowerInvariant()
}
