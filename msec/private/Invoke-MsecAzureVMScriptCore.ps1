function Invoke-MsecAzureVMScriptCore {
    <#
    .SYNOPSIS
        Runs one Run-Command on one VM and emits a single result row. Private worker
        for Invoke-MsecAzureVMScript - factored out so the sequential and parallel paths
        share identical logic.

    .DESCRIPTION
        The sequential path calls this directly; the parallel path captures
        (Get-Command Invoke-MsecAzureVMScriptCore).Definition once in the caller's
        runspace and re-injects it inside each ForEach-Object -Parallel runspace via
        ${function:Invoke-MsecAzureVMScriptCore} = $using:funcDef. PowerShell 7 refuses to
        pass scriptblocks across runspace boundaries via $using:, but it happily
        passes the function BODY (a string) and lets each runspace redefine the
        function in its own session state.

        It targets the CURRENT Az context's subscription and never switches context per VM;
        a $Vm whose SubscriptionId differs from the active context is failed gracefully (see
        the inline comment on the guard below).

    .PARAMETER Vm
        A PSCustomObject with the dispatch metadata: Name, ResourceGroupName,
        Location, Os, SubscriptionId, ScriptName, ScriptPath, CommandId. Built by
        Invoke-MsecAzureVMScript's process{} block.

    .PARAMETER TimeoutSeconds
        Max seconds to wait for Invoke-AzVMRunCommand on this one VM. 0 (default)
        means "no timeout" - the call blocks as long as Azure does. >0 runs the call
        as the cmdlet's own background job (-AsJob) with Wait-Job -Timeout; on timeout
        the job is ABANDONED (not stopped synchronously - that can block on a wedged VM),
        so the VM yields a single Failed/Timeout row and the batch keeps moving.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Vm,

        [int] $TimeoutSeconds = 0
    )

    # Single-context model: the run-command targets the CURRENT Az context's subscription.
    # We deliberately do NOT switch context per VM - that implicit routing required a saved
    # context for every sub and failed obscurely when one was missing. If a piped VM lives
    # in a different subscription than the active context, fail it gracefully with a clear
    # remedy instead of dispatching to the wrong sub or throwing a raw Azure error.
    if ($Vm.SubscriptionId) {
        $currentSub = (Get-AzContext -ErrorAction SilentlyContinue).Subscription.Id
        if ($currentSub -and $Vm.SubscriptionId -ne $currentSub) {
            return [PSCustomObject]@{
                VmName            = $Vm.Name
                ResourceGroupName = $Vm.ResourceGroupName
                Location          = $Vm.Location
                Os                = $Vm.Os
                ScriptName        = $Vm.ScriptName
                Status            = 'Failed'
                Output            = $null
                Error             = "VM is in subscription $($Vm.SubscriptionId) but the active Az context is $currentSub. Switch context with 'Set-AzContext -SubscriptionId $($Vm.SubscriptionId)', or scope your query with 'Search-MsecAzureResourceGraph -SubscriptionId $currentSub', so targets match the active subscription."
                DurationSeconds   = 0
            }
        }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = $null
    $errorMessage = $null
    try {
        $cmd = @{
            ResourceGroupName = $Vm.ResourceGroupName
            Name              = $Vm.Name
            CommandId         = $Vm.CommandId
            ScriptPath        = $Vm.ScriptPath
            ErrorAction       = 'Stop'
        }

        if ($TimeoutSeconds -gt 0) {
            # Bound a wedged VM so it can't stall the batch: run the call as the cmdlet's own
            # background job (-AsJob) and wait only up to our budget.
            $job = Invoke-AzVMRunCommand @cmd -AsJob

            $completed = Wait-Job $job -Timeout $TimeoutSeconds
            if ($completed) {
                $resp = Receive-Job $job -ErrorAction Stop
                Remove-Job $job
            }
            else {
                # Timed out. Crucially we do NOT Stop-Job / Remove-Job -Force here: both WAIT
                # for the job to actually stop, and Azure's run-command cancellation often
                # isn't prompt, so they would BLOCK until the stuck call returns (up to Az's
                # 45-min internal timeout). Inside ForEach-Object -Parallel that stalls the
                # whole batch on its slowest VM - the "hang on the last VM". So we ABANDON the
                # job and return immediately; it finishes on its own and is reaped when the
                # session/process ends. (Measured: abandon returns at the timeout; a blocking
                # Stop/Remove waits out the full stuck duration.)
                throw "VM did not respond within $TimeoutSeconds seconds (timeout)."
            }
        }
        else {
            # Direct synchronous call - no per-VM timeout. This is the path Pester's mocks
            # intercept (mocks don't propagate into background-job runspaces), so all
            # existing tests use it via the TimeoutSeconds=0 default.
            $resp = Invoke-AzVMRunCommand @cmd
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
    }
    $sw.Stop()

    $stdout = $null; $stderr = $null
    if ($resp -and $resp.Value) {
        # Preferred path: identify stdout/stderr by the Code field's StdOut/StdErr suffix.
        $stdout = ($resp.Value | Where-Object Code -like '*StdOut*' | Select-Object -First 1).Message
        $stderr = ($resp.Value | Where-Object Code -like '*StdErr*' | Select-Object -First 1).Message

        # Fallback: if the Code-based filter didn't find anything but Value had entries,
        # concatenate every non-empty Message - Invoke-AzVMRunCommand's response shape
        # has varied between Az.Compute versions.
        if (-not $stdout -and -not $stderr) {
            $stdout = (@($resp.Value) | ForEach-Object { $_.Message } |
                Where-Object { $_ }) -join "`n`n"
        }

        # Linux Azure VM agent's RunShellScript wraps the actual stdout/stderr inside a
        # single Message like:
        #
        #     Enable succeeded:
        #     [stdout]
        #     <actual stdout>
        #
        #     [stderr]
        #     <actual stderr>
        #
        # Strip the wrapper so downstream parsers (e.g. ConvertFrom-Json) see the real
        # script output. Windows doesn't add this wrapper, so the regex simply won't
        # match there and the output is left untouched.
        if ($stdout -match '(?ms)^.*?\[stdout\][\r\n]+(.*?)[\r\n]+\[stderr\][\r\n]*(.*)$') {
            $stdout = $matches[1].Trim()
            $stderrFromWrapper = $matches[2].Trim()
            if (-not $stderr) { $stderr = $stderrFromWrapper }
        }
    }

    $status = if ($errorMessage)    { 'Failed' }
              elseif ($resp.Status) { $resp.Status }
              else                  { 'Unknown' }

    [PSCustomObject]@{
        VmName            = $Vm.Name
        ResourceGroupName = $Vm.ResourceGroupName
        Location          = $Vm.Location
        Os                = $Vm.Os
        ScriptName        = $Vm.ScriptName
        Status            = $status
        Output            = $stdout
        Error             = if ($errorMessage) { $errorMessage } else { $stderr }
        DurationSeconds   = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}
