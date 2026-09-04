function Confirm-MsecEvidenceOverwrite {
    <#
    .SYNOPSIS
        Asks before an evidence report replaces a worksheet that already holds data. Returns
        $true to go ahead.

    .DESCRIPTION
        Snapshot reports REPLACE rather than append - that is the point of them, and it is
        also how last month's evidence gets destroyed by a mistyped path. This asks first, and
        only when something would actually be lost: a new file, or a new owner in an existing
        file, is not a question worth interrupting for.

        The prompt names the sheet, how many rows it holds and when they were collected, so
        the answer can be given on the facts rather than on a generic "are you sure".

        ASKED BEFORE THE COLLECTION, NOT AFTER. Callers put this immediately after the owner
        is known and before any data is gathered, so declining costs nothing - no Graph
        enumeration, and on the VM reports no Run Command invocations against live machines.

        Unattended runs need -Force: a scheduled task has no one to answer, and ShouldContinue
        in a non-interactive host is an error rather than a default.

    .PARAMETER Cmdlet
        The calling cmdlet's $PSCmdlet, which is what owns the prompt and honours -Confirm.

    .PARAMETER Force
        Skip the prompt and replace. For scheduled and unattended runs.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $OwnerName,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $OwnerId,
        [Parameter(Mandatory)] [string] $OwnerColumn,
        [Parameter(Mandatory)] $Cmdlet,
        [switch] $Force
    )

    if ($Force) { return $true }

    $sheet = Resolve-MsecEvidenceSheet -Path $Path -OwnerName $OwnerName -OwnerId $OwnerId -OwnerColumn $OwnerColumn
    if (-not $sheet.IsReplace) { return $true }

    $held = if ($sheet.RowCount) {
        "$($sheet.RowCount) row(s)" + $(if ($sheet.CollectedUtc) { " collected $($sheet.CollectedUtc) UTC" } else { '' })
    }
    else {
        'data that could not be read back'
    }

    $query = "Worksheet '$($sheet.SheetName)' in '$Path' already holds $held for '$OwnerName'. Writing replaces them - a snapshot report does not append. Continue?"
    $caption = 'Replace existing evidence?'

    if ($Cmdlet.ShouldContinue($query, $caption)) { return $true }

    Write-Warning "Skipped '$OwnerName' - '$Path' was left unchanged. Use -Force to replace without being asked, or write to a different path."
    return $false
}
