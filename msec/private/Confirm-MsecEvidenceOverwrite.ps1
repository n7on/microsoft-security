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
    [CmdletBinding(DefaultParameterSetName = 'Single')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Path,

        [Parameter(Mandatory, ParameterSetName = 'Single')] [string] $OwnerName,
        [Parameter(Mandatory, ParameterSetName = 'Single')] [AllowEmptyString()] [string] $OwnerId,

        # Several subjects in one run - a report that writes a sheet per group rather than one
        # per tenant. Each needs a Name and an Id. Asked as ONE question: a wildcard can match
        # forty groups, and forty prompts is a prompt nobody reads.
        [Parameter(Mandatory, ParameterSetName = 'Many')] [AllowEmptyCollection()] [object[]] $Owner,

        [Parameter(Mandatory)] [string] $OwnerColumn,
        [Parameter(Mandatory)] $Cmdlet,
        [switch] $Force
    )

    if ($Force) { return $true }

    $subjects = if ($PSCmdlet.ParameterSetName -eq 'Many') { @($Owner) }
                else { @([pscustomobject]@{ Name = $OwnerName; Id = $OwnerId }) }

    $replacing = @(
        foreach ($subject in $subjects) {
            $sheet = Resolve-MsecEvidenceSheet -Path $Path -OwnerName ([string] $subject.Name) `
                         -OwnerId ([string] $subject.Id) -OwnerColumn $OwnerColumn
            if ($sheet.IsReplace) {
                $held = if ($sheet.RowCount) {
                    "$($sheet.RowCount) row(s)" + $(if ($sheet.CollectedUtc) { " collected $($sheet.CollectedUtc) UTC" } else { '' })
                }
                else {
                    'data that could not be read back'
                }
                [pscustomobject]@{ Name = $subject.Name; SheetName = $sheet.SheetName; Held = $held }
            }
        }
    )

    if (-not $replacing.Count) { return $true }

    $query = if ($replacing.Count -eq 1) {
        "Worksheet '$($replacing[0].SheetName)' in '$Path' already holds $($replacing[0].Held) for '$($replacing[0].Name)'. Writing replaces them - a snapshot report does not append. Continue?"
    }
    else {
        "$($replacing.Count) worksheet(s) in '$Path' already hold evidence and will be replaced - a snapshot report does not append: " +
            (($replacing | ForEach-Object { "'$($_.SheetName)' ($($_.Held))" }) -join ', ') + '. Continue?'
    }

    if ($Cmdlet.ShouldContinue($query, 'Replace existing evidence?')) { return $true }

    Write-Warning "Skipped - '$Path' was left unchanged. Use -Force to replace without being asked, or write to a different path."
    return $false
}
