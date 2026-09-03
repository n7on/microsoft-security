function Export-MsecVMUpdateReport {
    <#
    .SYNOPSIS
        Evidence of when every VM in the CURRENT subscription was last patched - one row per
        machine, on a worksheet named after the subscription.

    .DESCRIPTION
        Runs the bundled update-status script inside each VM through Azure Run-Command, so the
        answer is what the machine itself reports: Windows Update history on Windows, the
        package manager's log on Linux. One row per VM, showing what that VM said.

        WHY IN-GUEST AND NOT RESOURCE GRAPH. Kql/Graph/VM/LastUpdated.kql answers the same
        question in one fast query, but sees ONLY what Azure Update Manager installed. A VM
        patching itself through Windows Automatic Updates or unattended-upgrades contributes
        nothing there and reads as never updated - which is false, and on an evidence document
        it is worse than useless. This costs a Run-Command per VM and needs the machines
        running, and buys an answer the guest itself vouches for.

        A DOCUMENT PER RUN, NOT A GROWING ONE. This is a snapshot: nothing is appended and no
        history accumulates, so a sheet written twice is simply replaced. Give each run its own
        path - the date in the filename is what makes it evidence of a particular day.

        SEVERAL SUBSCRIPTIONS, ONE DOCUMENT. The scope is whatever the Az context is on, which
        is also what Run-Command acts on, so the two cannot disagree. Re-run against the same
        path after Select-MsecAzureContext and the next subscription gets its own sheet in the
        same file, with its own chart on the Dashboard.

        EVERY VM APPEARS, INCLUDING THE ONES THAT DID NOT ANSWER. A stopped machine, a wedged
        agent or a timeout gets a row with Answered = False and the reason in Error, rather
        than being left out. Evidence that quietly omits the machines it could not reach is
        not evidence - the gaps are exactly what a reviewer needs to see.

    .PARAMETER Path
        The .xlsx to write. Created if absent; an existing file is added to rather than
        replaced, so several subscriptions can share one document. A sheet that already exists
        for the same subscription is replaced, since this is a snapshot.

    .PARAMETER StaleAfterDays
        Days since the last install past which a VM is marked Stale in the Assessment column.
        Default 35 - a calendar month plus slack, so a monthly window that slips does not read
        as a failure.

    .PARAMETER ThrottleLimit
        VMs to query at once, passed to Invoke-MsecAzureVMScript. Default 8.

    .PARAMETER TimeoutSeconds
        Per-VM budget, passed through. Default 300. A VM that exceeds it gets a row saying so
        rather than stalling the run.

    .PARAMETER IncludeStopped
        Attempt stopped VMs too. Off by default because Run-Command cannot reach them - they
        still appear, with Assessment = 'Not running'.

    .PARAMETER TableStyle
        Excel table style. One of Light1-21, Medium1-28 or Dark1-11. Default Medium2.

    .PARAMETER ChartWidth
        Chart width in pixels, default 600 - sized to paste into an A4 portrait Word page.

    .PARAMETER ChartHeight
        Chart height in pixels, default 370.

    .PARAMETER PassThru
        Emit the per-VM rows as objects as well as writing them.

    .EXAMPLE
        Select-MsecAzureContext -Subscription 'Contoso Production'
        Export-MsecVMUpdateReport -Path "./vm-patching-$(Get-Date -Format 'yyyy-MM-dd').xlsx"

    .EXAMPLE
        # One evidence document covering the estate, a subscription per sheet.
        $file = "./vm-patching-$(Get-Date -Format 'yyyy-MM-dd').xlsx"
        foreach ($s in 'PROD', 'TEST', 'DEV') {
            Select-MsecAzureContext -Subscription $s
            Export-MsecVMUpdateReport -Path $file
        }

    .EXAMPLE
        # The machines a reviewer will ask about, without opening the workbook.
        Export-MsecVMUpdateReport -Path ./evidence.xlsx -PassThru |
            Where-Object Assessment -ne 'Up to date' |
            Format-Table VmName, Assessment, DaysSinceUpdate, SecurityPending

    .OUTPUTS
        With -PassThru, one PSCustomObject per VM, PSTypeName 'MsecVMUpdateStatus'.

    .NOTES
        Needs an Az context - this is ARM, not Graph, so Connect-AzAccount rather than
        Connect-Msec. The caller needs Microsoft.Compute/virtualMachines/runCommand/action on
        the VMs (Virtual Machine Contributor covers it).

        SLOW BY NATURE. One Run-Command per VM, a few seconds each at best; a hundred-VM
        subscription at the default throttle is minutes, not seconds.

        The chart plots DaysSinceUpdate per VM, worst first, which reads well up to a few dozen
        machines. On a larger fleet the table is the evidence and the chart is a shape - sort
        or filter it in Excel if you need more from it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Path,

        [ValidateRange(1, 365)]
        [int] $StaleAfterDays = 35,

        [ValidateRange(1, 32)]
        [int] $ThrottleLimit = 8,

        [ValidateRange(0, 3600)]
        [int] $TimeoutSeconds = 300,

        [switch] $IncludeStopped,

        [string] $TableStyle = 'Medium2',

        [ValidateRange(200, 2000)]
        [int] $ChartWidth = 600,

        [ValidateRange(150, 1200)]
        [int] $ChartHeight = 370,

        [switch] $PassThru
    )

    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        throw 'ImportExcel is required for Export-MsecVMUpdateReport. Install with: Install-Module ImportExcel -Scope CurrentUser'
    }
    Import-Module ImportExcel -ErrorAction Stop

    if (-not ($TableStyle -as [OfficeOpenXml.Table.TableStyles])) {
        throw "'$TableStyle' is not an Excel table style. Use one of Light1-21, Medium1-28 or Dark1-11 (for example Medium2, the default)."
    }

    if (-not $PSCmdlet.ShouldProcess('the current subscription', 'Run update-status on its VMs and write the evidence sheet')) {
        return
    }

    # Best to worst. Used verbatim as the chart's categories, so all five appear every run even
    # at zero - a category that vanished when nothing was in it would make two runs' charts
    # incomparable.
    $order = @('Up to date', 'Stale', 'No update history', 'No answer', 'Not running')
    $stale = $StaleAfterDays
    $stopped = $IncludeStopped

    $rows = Write-MsecVMEvidenceWorkbook -Path $Path -ScriptName 'update-status' `
        -AssessmentOrder $order `
        -Heading 'VM patching evidence' -ChartTitlePrefix 'VM patch assessment' `
        -ThrottleLimit $ThrottleLimit -TimeoutSeconds $TimeoutSeconds -IncludeStopped:$IncludeStopped `
        -TableStyle $TableStyle -ChartWidth $ChartWidth -ChartHeight $ChartHeight `
        -ProjectRow {
            param($Vm, $Status, $Result)

            # The four states are deliberately distinct: they need different follow-up. A VM
            # with no install history is NOT stale - one needs patching, the other investigating.
            $assessment =
                if (-not $Vm.Running -and -not $stopped)      { 'Not running' }
                elseif (-not $Status)                         { 'No answer' }
                elseif ($null -eq $Status.DaysSinceUpdate)    { 'No update history' }
                elseif ($Status.DaysSinceUpdate -gt $stale)   { 'Stale' }
                else                                          { 'Up to date' }

            [ordered]@{
                Assessment        = $assessment
                LastUpdate        = $Status.LastUpdate
                DaysSinceUpdate   = $Status.DaysSinceUpdate
                LastUpdatePackage = $Status.LastUpdatePackage
                UpdateCount30d    = $Status.UpdateCount30d
                SecurityPending   = $Status.SecurityPending
                OtherPending      = $Status.OtherPending
                RebootRequired    = $Status.RebootRequired
                AssessedFresh     = $Status.AssessedFresh
                Source            = $Status.Source
            }
        }

    $unassessed = @($rows | Where-Object Assessment -in 'No answer', 'Not running')
    if ($unassessed.Count) {
        Write-Warning "$($unassessed.Count) of $(@($rows).Count) VM(s) returned no patch data and are on the sheet as such: $((@($unassessed.VmName) | Sort-Object) -join ', ')"
    }

    if ($PassThru) { $rows }
}