function Export-MsecVMNtpReport {
    <#
    .SYNOPSIS
        Evidence that every VM in the CURRENT subscription has its clock synchronised - one row
        per machine, on a worksheet named after the subscription.

    .DESCRIPTION
        Runs the bundled ntp-status script inside each VM through Azure Run-Command and records
        what the machine itself reports: whether it is synchronised, which daemon is doing it,
        and against which upstream source.

        THE VERDICT IS THE SCRIPT'S, NOT THIS COMMAND'S. Both the Windows and Linux versions
        compute the same A.8.17 rule - synchronised AND naming a real upstream source - so the
        Compliant column means the same thing on both platforms and the two can sit in one
        table without a footnote.

        BOTH HALVES OF THAT RULE MATTER, which is why 'No time source' is its own verdict
        rather than being folded into 'Not synchronised'. A Windows machine falling back to
        Local CMOS Clock reports itself perfectly synchronised - to its own drifting hardware
        clock. It is not an unsynchronised machine that needs restarting; it is a machine
        pointed at nothing, and the fix is different.

        A DOCUMENT PER RUN, NOT A GROWING ONE. This is a snapshot: nothing is appended, and a
        sheet written twice is replaced. Give each scan its own path - the date in the filename
        is what makes it evidence of a particular day.

        SEVERAL SUBSCRIPTIONS, ONE DOCUMENT. The scope is whatever the Az context is on, which
        is also what Run-Command acts on, so the two cannot disagree. Re-run against the same
        path after Select-MsecAzureContext and the next subscription gets its own sheet and its
        own chart.

        EVERY VM APPEARS, INCLUDING THE ONES THAT DID NOT ANSWER - a stopped machine, a wedged
        agent or a timeout gets a row saying so. Evidence that quietly omits what it could not
        reach is not evidence.

    .PARAMETER Path
        The .xlsx to write. Created if absent; an existing file is added to rather than
        replaced, so several subscriptions can share one document.

    .PARAMETER ThrottleLimit
        VMs to query at once, passed to Invoke-MsecAzureVMScript. Default 8.

    .PARAMETER TimeoutSeconds
        Per-VM budget, passed through. Default 300.

    .PARAMETER IncludeStopped
        Attempt stopped VMs too. Off by default because Run-Command cannot reach them - they
        still appear, with Assessment = 'Not running'.

    .PARAMETER TableStyle
        Excel table style. One of Light1-21, Medium1-28 or Dark1-11. Default Medium2.

    .PARAMETER ChartWidth
        Chart width in pixels, default 600 - sized to paste into an A4 portrait Word page.

    .PARAMETER ChartHeight
        Chart height in pixels, default 370.

    .PARAMETER Force
        Replace an existing worksheet without asking. A snapshot report REPLACES rather than
        appends, so writing to a path that already holds this subject's evidence discards it -
        which is worth a question when the path was a typo, and worth suppressing when the run
        is scheduled. Unattended runs need this: there is no one to answer the prompt.
    .PARAMETER PassThru
        Emit the per-VM rows as objects as well as writing them.

    .EXAMPLE
        Select-MsecAzureContext -Subscription 'Contoso Production'
        Export-MsecVMNtpReport -Path "./vm-timesync-$(Get-Date -Format 'yyyy-MM-dd').xlsx"

    .EXAMPLE
        # One evidence document covering the estate, a subscription per sheet.
        $file = "./vm-timesync-$(Get-Date -Format 'yyyy-MM-dd').xlsx"
        foreach ($s in 'PROD', 'TEST', 'DEV') {
            Select-MsecAzureContext -Subscription $s
            Export-MsecVMNtpReport -Path $file
        }

    .EXAMPLE
        # The machines a reviewer will ask about.
        Export-MsecVMNtpReport -Path ./evidence.xlsx -PassThru |
            Where-Object Assessment -ne 'Compliant' |
            Format-Table VmName, Assessment, Synchronized, Source, Daemon

    .OUTPUTS
        With -PassThru, one PSCustomObject per VM, PSTypeName 'MsecVMEvidence'.

    .NOTES
        Needs an Az context - this is ARM, not Graph, so Connect-AzAccount rather than
        Connect-Msec. The caller needs Microsoft.Compute/virtualMachines/runCommand/action on
        the VMs (Virtual Machine Contributor covers it).

        SLOW BY NATURE. One Run-Command per VM, a few seconds each at best.

        VmClockUtc is the guest's own clock at the moment the script ran. It is carried as
        evidence, not compared against the collection time: Run-Command latency is seconds and
        varies, so a small difference means nothing. A difference of minutes or hours is worth
        chasing, and is visible by eye.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Path,

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

        [switch] $PassThru,

        [switch] $Force
    )

    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        throw 'ImportExcel is required for Export-MsecVMNtpReport. Install with: Install-Module ImportExcel -Scope CurrentUser'
    }
    Import-Module ImportExcel -ErrorAction Stop

    if (-not ($TableStyle -as [OfficeOpenXml.Table.TableStyles])) {
        throw "'$TableStyle' is not an Excel table style. Use one of Light1-21, Medium1-28 or Dark1-11 (for example Medium2, the default)."
    }

    if (-not $PSCmdlet.ShouldProcess('the current subscription', 'Run ntp-status on its VMs and write the evidence sheet')) {
        return
    }

    # Best to worst. Used verbatim as the chart's categories, so all five appear every run even
    # at zero - a category that vanished when nothing was in it would make two runs' charts
    # incomparable.
    $order = @('Compliant', 'No time source', 'Not synchronised', 'No answer', 'Not running')
    $stopped = $IncludeStopped

    $rows = Write-MsecVMEvidenceWorkbook -Path $Path -Cmdlet $PSCmdlet -Force:$Force -ScriptName 'ntp-status' `
        -AssessmentOrder $order `
        -Heading 'VM time sync evidence' -ChartTitlePrefix 'VM time sync' `
        -ThrottleLimit $ThrottleLimit -TimeoutSeconds $TimeoutSeconds -IncludeStopped:$IncludeStopped `
        -TableStyle $TableStyle -ChartWidth $ChartWidth -ChartHeight $ChartHeight `
        -ProjectRow {
            param($Vm, $Status, $Result)

            # 'No time source' is separated from 'Not synchronised' on purpose. A Windows box
            # fallen back to Local CMOS Clock reports itself SYNCHRONISED - to its own drifting
            # hardware clock - and the script's Compliant rule catches that by also requiring a
            # source. Folding the two together would hide the difference between a machine
            # whose daemon has stalled and one that was never pointed anywhere.
            $assessment =
                if (-not $Vm.Running -and -not $stopped)    { 'Not running' }
                elseif (-not $Status)                       { 'No answer' }
                elseif ($Status.Compliant)                  { 'Compliant' }
                elseif ($Status.Synchronized)               { 'No time source' }
                else                                        { 'Not synchronised' }

            [ordered]@{
                Assessment   = $assessment
                Synchronized = $Status.Synchronized
                Source       = $Status.Source
                Daemon       = $Status.Daemon
                NtpEnabled   = $Status.NtpEnabled
                TimeZone     = $Status.TimeZone
                # The guest's own clock when the script ran. Evidence, not a computed skew -
                # see the note in the help about why.
                VmClockUtc   = $Status.NowUtc
                Compliant    = $Status.Compliant
            }
        }

    $unassessed = @($rows | Where-Object Assessment -in 'No answer', 'Not running')
    if ($unassessed.Count) {
        Write-Warning "$($unassessed.Count) of $(@($rows).Count) VM(s) returned no time-sync data and are on the sheet as such: $((@($unassessed.VmName) | Sort-Object) -join ', ')"
    }

    if ($PassThru) { $rows }
}
