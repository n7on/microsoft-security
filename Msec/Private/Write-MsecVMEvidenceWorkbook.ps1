function Write-MsecVMEvidenceWorkbook {
    <#
    .SYNOPSIS
        The shared machinery behind the per-VM evidence reports: run a bundled script on every
        VM in the current subscription, and write the answers as a snapshot workbook.

    .DESCRIPTION
        Export-MsecVMUpdateReport and Export-MsecVMNtpReport differ only in WHICH script they
        run and how they read its answer. Everything else - discovering the VMs, running the
        script, naming the worksheet, replacing rather than appending, the shared Summary
        sheet, the per-block timestamps, the dashboard - is identical, and duplicating it would
        mean fixing every bug twice.

        So the caller supplies three things: the script to run, a scriptblock that turns one
        VM's answer into a row, and the ordered list of assessment verdicts that scriptblock
        can return. This function does the rest.

        THE CONTRACT FOR -ProjectRow. It is called once per VM with three positional
        arguments - the VM as Resource Graph returned it, the script's parsed output (or $null
        if it did not answer), and the Run-Command result row (or $null if the VM was never
        attempted). It returns an ordered hashtable of that report's own columns, one of which
        must be 'Assessment' and must be a member of -AssessmentOrder. The common columns are
        added around it here, so a report never has to restate them.

        WHY EVERY VM GETS A ROW. A stopped machine, a wedged agent or a timeout has no answer,
        and evidence that quietly omits what it could not reach is not evidence - the gaps are
        usually the finding. The Assessment column is where that shows up, which is why it is
        the caller's job to name those states rather than this function's to guess them.

        A SNAPSHOT, NOT A SERIES. A sheet written twice is replaced. Give each scan its own
        file; several subscriptions can share one, a sheet each.

    .PARAMETER Path
        The .xlsx to write. Added to rather than replaced, so subscriptions can share a file.

    .PARAMETER ScriptName
        Bundled script to run, e.g. 'update-status'. Must exist for every OS in the fleet.

    .PARAMETER ProjectRow
        Scriptblock turning one VM's answer into that report's columns. See the contract above.

    .PARAMETER AssessmentOrder
        Every verdict -ProjectRow can return, ordered best to worst. Used verbatim as the
        chart's categories, so all of them appear every run even at zero - a category that
        vanished when nothing was in it would make two runs' charts incomparable.

    .PARAMETER Heading
        Dashboard heading, e.g. 'VM time sync evidence'. The collection span is appended.

    .PARAMETER ChartTitlePrefix
        Prefix for each chart's title; the subscription name is appended.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ScriptName,
        [Parameter(Mandatory)] [scriptblock] $ProjectRow,
        [Parameter(Mandatory)] [string[]] $AssessmentOrder,
        [Parameter(Mandatory)] [string] $Heading,
        [Parameter(Mandatory)] [string] $ChartTitlePrefix,

        [int]    $ThrottleLimit  = 8,
        [int]    $TimeoutSeconds = 300,
        [switch] $IncludeStopped,
        [string] $TableStyle     = 'Medium2',
        [int]    $ChartWidth     = 600,
        [int]    $ChartHeight    = 370
    )

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        throw 'No Azure context. Run Connect-AzAccount, then Select-MsecAzureContext to pick the subscription to report on.'
    }

    $subscriptionName = [string] $context.Subscription.Name
    $subscriptionId   = [string] $context.Subscription.Id
    if (-not $subscriptionName) { $subscriptionName = $subscriptionId }

    $collectedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')

    # ---- discover ----------------------------------------------------------------------------

    Write-Verbose "Listing VMs in '$subscriptionName'"
    $allVms = @(Search-MsecAzureResourceGraph -ResourceType VM -CurrentSubscription)

    if (-not $allVms.Count) {
        Write-Warning "No VMs found in '$subscriptionName'. Nothing to report."
        return
    }

    $targets = if ($IncludeStopped) { $allVms } else { @($allVms | Where-Object Running) }

    # ---- ask each VM -------------------------------------------------------------------------

    $results = @()
    if ($targets.Count) {
        $results = @($targets | Invoke-MsecAzureVMScript -ScriptName $ScriptName `
                                    -ThrottleLimit $ThrottleLimit -TimeoutSeconds $TimeoutSeconds)
    }

    # Keyed so a VM that was never attempted still gets a row below.
    $byName = @{}
    foreach ($result in $results) { $byName[$result.VmName] = $result }

    # ---- one row per VM ----------------------------------------------------------------------

    $rows = foreach ($vm in $allVms) {
        $result = $byName[$vm.Name]

        $status = $null
        if ($result -and $result.Status -eq 'Succeeded' -and $result.Output) {
            # A clipped or non-JSON body is a failed answer, not a clean machine. Azure returns
            # only the last 4096 bytes of stdout, which is why the bundled scripts budget theirs.
            try   { $status = $result.Output | ConvertFrom-Json -ErrorAction Stop }
            catch { Write-Verbose "Unparseable output from $($vm.Name): $($_.Exception.Message)" }
        }

        $projected = & $ProjectRow $vm $status $result

        $row = [ordered]@{
            PSTypeName        = 'MsecVMEvidence'
            VmName            = $vm.Name
            ResourceGroupName = $vm.ResourceGroupName
            Os                = $vm.Os
            PowerState        = $(if ($vm.Running) { 'Running' } else { 'Stopped' })
            Assessment        = $projected['Assessment']
        }
        foreach ($key in $projected.Keys) {
            if ($key -ne 'Assessment') { $row[$key] = $projected[$key] }
        }

        $row['Location']         = $vm.Location
        $row['RunStatus']        = $result.Status
        $row['Error']            = $result.Error
        $row['SubscriptionName'] = $subscriptionName
        $row['SubscriptionId']   = $subscriptionId
        $row['CollectedUtc']     = $collectedUtc

        [pscustomobject] $row
    }
    $rows = @($rows)

    # Worst first: the machines that could not be assessed at the top, then the failures, then
    # the healthy. On an evidence table the gaps are what a reviewer is looking for, so they
    # should not be at the bottom of a long list.
    $rows = @($rows | Sort-Object `
        @{ Expression = { [array]::IndexOf($AssessmentOrder, $_.Assessment) }; Descending = $true },
        VmName)

    # ---- write ---------------------------------------------------------------------------------
    #
    # Everything from here - sheet naming, replace semantics, the Summary block, timestamps and
    # the dashboard - is shared with the directory evidence reports and lives in one place.
    $count = Write-MsecEvidenceWorkbook -Path $Path `
        -OwnerName $subscriptionName -OwnerId $subscriptionId -OwnerColumn 'SubscriptionId' `
        -Row $rows `
        -CategoryProperty 'Assessment' -CategoryOrder $AssessmentOrder `
        -OwnerLabel 'Subscription' -CategoryLabel 'Assessment' `
        -Count ([ordered]@{ VMs = { $true } }) `
        -Heading $Heading -ChartTitlePrefix $ChartTitlePrefix -CollectedUtc $collectedUtc `
        -TableStyle $TableStyle -ChartWidth $ChartWidth -ChartHeight $ChartHeight

    $breakdown = foreach ($assessment in $AssessmentOrder) {
        $n = @($rows | Where-Object { $_.Assessment -eq $assessment }).Count
        if ($n) { "$assessment`: $n" }
    }
    Write-Verbose "$subscriptionName`: $count row(s) - $($breakdown -join ', ')"

    return $rows
}