function Invoke-MsecAzureVMScript {
    <#
    .SYNOPSIS
        Runs a bundled script on one or more Azure VMs. -Os selects the script flavour
        (Linux .sh under Scripts/VM/Linux/ or Windows .ps1 under Scripts/VM/Windows/).

    .DESCRIPTION
        Pipeline-friendly. Consumes Name + ResourceGroupName (and optionally Os, Location)
        from any VM source - Search-MsecAzureResourceGraph, Get-AzVM, hand-built objects.

        -Os can be set on the command line (all piped rows use that OS) OR bound per-row
        from the pipeline's Os property. The latter is what Search-MsecAzureResourceGraph
        produces, so the simple form Just Works:

            Search-MsecAzureResourceGraph -ResourceType VM | Where-Object Running |
                Invoke-MsecAzureVMScript -ScriptName ntp-status -ThrottleLimit 8

        -ScriptName tab-completes from Scripts/<Os>/ when -Os is on the command line,
        or falls back to scripts that exist for BOTH OSes when -Os is being supplied
        via the pipeline.

        Linux scripts run via CommandId='RunShellScript' (as root); Windows scripts via
        CommandId='RunPowerShellScript' (as SYSTEM). RBAC: caller needs
        Microsoft.Compute/virtualMachines/runCommand/action on each VM (Virtual Machine
        Contributor covers it).

        -ThrottleLimit > 1 fans the run-commands out across the pipeline in parallel via
        ForEach-Object -Parallel, using the caller's Az context. Order of output is the
        order results complete in, not input order - sort downstream if you care.

    .PARAMETER Os
        'Linux' or 'Windows'. Either supply on the command line, or pipe rows that have
        an Os property and the value is taken per-row.

    .PARAMETER ScriptName
        Base name (no extension) of the script under msec/Scripts/<Os>/. Must exist for
        every OS that comes down the pipeline - missing scripts produce a clear
        "<Os> script not found" error at first encounter.

    .PARAMETER Name
        VM name. Bound from the pipeline.
    .PARAMETER ResourceGroupName
        VM's resource group. Bound from the pipeline.
    .PARAMETER Location
        Optional pass-through column. If the piped source has Location, it appears in
        each output row.

    .PARAMETER ThrottleLimit
        Maximum number of VMs to run the script against concurrently. Default 1
        (sequential, streams results as each VM finishes). Values >1 buffer pipeline
        input and dispatch via ForEach-Object -Parallel.

    .PARAMETER TimeoutSeconds
        Max seconds to wait for any single VM's Run-Command to complete. Default
        300 (5 min) - generous enough for cold/slow VMs while still bounding the
        worst case far below Az's own 45-minute internal timeout. Each call runs
        as the cmdlet's own cancellable background job (-AsJob) with Wait-Job
        -Timeout, so a stuck agent yields one Failed/Timeout row - and the
        cancellation actually frees the slot - instead of hanging the whole batch.
        Raise to 600 for very slow fleets, lower (e.g. 120) for tight aggressive
        runs. Set to 0 to disable the timeout entirely (useful for tests that mock
        Invoke-AzVMRunCommand - Pester mocks don't propagate into background-job
        runspaces).

    .EXAMPLE
        # Mixed Linux + Windows, single call, parallel:
        Search-MsecAzureResourceGraph -ResourceType VM | Where-Object Running |
            Invoke-MsecAzureVMScript -ScriptName ntp-status -ThrottleLimit 8

    .EXAMPLE
        # Explicit -Os (overrides any per-row Os; safe when you've filtered already):
        Search-MsecAzureResourceGraph -ResourceType VM | Where-Object Os -eq 'Linux' |
            Invoke-MsecAzureVMScript -Os Linux -ScriptName ntp-status -ThrottleLimit 8

    .OUTPUTS
        PSCustomObject per VM: VmName, ResourceGroupName, Location, Os, ScriptName,
        Status, Output, Error, DurationSeconds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateSet('Linux', 'Windows')]
        [string] $Os,

        [Parameter(Mandatory)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $base = (Get-Module msec).ModuleBase
            if (-not $base) { return }

            # NB: the canonical OS map (extension + CommandId) lives in
            # Resolve-MsecAzureVMScriptDispatch. A completer scriptblock runs in the caller's
            # session, not module scope, so it can't call that private helper - it only needs
            # the file glob, kept in sync here by hand.
            $os = $fakeBoundParameters['Os']
            if ($os) {
                # -Os is on the command line - filter to that OS's folder.
                $folder = Join-Path $base "Scripts/VM/$os"
                if (-not (Test-Path -LiteralPath $folder)) { return }
                $filter = if ($os -eq 'Linux') { '*.sh' } else { '*.ps1' }
                $names  = Get-ChildItem -LiteralPath $folder -Filter $filter -File |
                    ForEach-Object BaseName
            } else {
                # No -Os yet - the user is likely binding it from the pipeline. Suggest
                # only scripts that exist in BOTH OS folders so the same -ScriptName is
                # safe to use across a mixed Linux/Windows pipeline.
                $linux = @(Get-ChildItem (Join-Path $base 'Scripts/VM/Linux')   -Filter '*.sh'  -File -EA SilentlyContinue |
                    ForEach-Object BaseName)
                $win   = @(Get-ChildItem (Join-Path $base 'Scripts/VM/Windows') -Filter '*.ps1' -File -EA SilentlyContinue |
                    ForEach-Object BaseName)
                $names = $linux | Where-Object { $_ -in $win }
            }

            $names |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new(
                        $_, $_, 'ParameterValue', $_)
                }
        })]
        [string] $ScriptName,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $Name,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $ResourceGroupName,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string] $Location,

        # Optional. When the piped row carries SubscriptionId (Search-MsecAzureResourceGraph
        # projects it), it GUARDS against acting on the wrong subscription: a VM whose
        # SubscriptionId differs from the active Az context is failed gracefully instead of
        # dispatched. Scope the query with Search-MsecAzureResourceGraph -SubscriptionId, or
        # switch context, so targets match the active sub.
        [Parameter(ValueFromPipelineByPropertyName)]
        [string] $SubscriptionId,

        [ValidateRange(1, 32)]
        [int] $ThrottleLimit = 1,

        [ValidateRange(0, 3600)]
        [int] $TimeoutSeconds = 300
    )

    begin {
        if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
            throw 'No Azure context. Run Connect-AzAccount before Invoke-MsecAzureVMScript.'
        }

        # Script path + Run-Command id are resolved by Resolve-MsecAzureVMScriptDispatch
        # (the single source of truth for the OS map) and memoized per OS here - -Os may be
        # one command-line value or vary row-by-row when bound from the pipeline.
        $dispatchByOs = @{}

        # The per-VM work lives in Private/Invoke-MsecAzureVMScriptCore.ps1. The sequential
        # path calls it directly. The parallel path can't (ForEach-Object -Parallel
        # runspaces don't see module-scope functions, and PS 7+ refuses scriptblocks
        # passed via $using:), so we capture the function BODY as a string here and
        # re-define the function inside each parallel runspace below.
        $coreFn = (Get-Command Invoke-MsecAzureVMScriptCore -CommandType Function).Definition

        # Buffer used only by the parallel path; sequential streams each VM as it arrives.
        $pending = [System.Collections.Generic.List[pscustomobject]]::new()
    }

    process {
        # $Os is per-row when pipeline-bound, constant when set on the command line.
        # Resolve once per OS, then reuse.
        if (-not $dispatchByOs.ContainsKey($Os)) {
            $dispatchByOs[$Os] = Resolve-MsecAzureVMScriptDispatch -Os $Os -ScriptName $ScriptName
        }
        $dispatch = $dispatchByOs[$Os]

        $vm = [pscustomobject]@{
            Name              = $Name
            ResourceGroupName = $ResourceGroupName
            Location          = $Location
            Os                = $Os
            SubscriptionId    = $SubscriptionId
            ScriptName        = $ScriptName
            ScriptPath        = $dispatch.ScriptPath
            CommandId         = $dispatch.CommandId
        }

        if ($ThrottleLimit -le 1) {
            Write-Verbose "Running $ScriptName on $ResourceGroupName/$Name ($Os) via $($dispatch.CommandId)"
            Invoke-MsecAzureVMScriptCore -Vm $vm -TimeoutSeconds $TimeoutSeconds
        }
        else {
            $pending.Add($vm)
        }
    }

    end {
        if ($ThrottleLimit -le 1 -or $pending.Count -eq 0) { return }

        Write-Host "Dispatching $($pending.Count) VM(s) with ThrottleLimit=$ThrottleLimit, TimeoutSeconds=$TimeoutSeconds" -ForegroundColor Cyan

        # Thread-safe progress counter. Synchronized hashtable lets every runspace
        # increment concurrently; the Monitor.Enter/Exit lock around print+update
        # keeps the count and message atomic, so two simultaneous completions
        # don't garble each other's output.
        $progress = [hashtable]::Synchronized(@{
            Total     = $pending.Count
            Completed = 0
            Failed    = 0
        })

        $pending | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            # Re-create the module's private worker function inside this runspace
            # from the body we captured up in begin{}. This is the canonical PS 7+
            # idiom for sharing function code with ForEach-Object -Parallel. The
            # worker reads the active Az context (autosaved to disk, so every runspace
            # sees it) to validate each VM's subscription against the active one.
            ${function:Invoke-MsecAzureVMScriptCore} = $using:coreFn
            $r = Invoke-MsecAzureVMScriptCore -Vm $_ -TimeoutSeconds $using:TimeoutSeconds

            # Progress update. Lock-wrap so increment + print stay atomic across
            # concurrent completions - otherwise the [n/N] count and the message
            # can interleave from different VMs on the same terminal line.
            $p = $using:progress
            [System.Threading.Monitor]::Enter($p)
            try {
                $p.Completed++
                if ($r.Status -ne 'Succeeded') { $p.Failed++ }

                $sym    = if ($r.Status -eq 'Succeeded') { 'OK  ' } else { 'FAIL' }
                $color  = if ($r.Status -eq 'Succeeded') { 'Green' } else { 'Red'  }
                $tag    = '[{0,3}/{1,-3}]' -f $p.Completed, $p.Total
                $name   = '{0,-32}' -f $r.VmName
                $osTag  = '{0,-7}' -f $r.Os
                $detail = if ($r.Status -eq 'Succeeded') {
                    "in $($r.DurationSeconds)s"
                } elseif ($r.Error) {
                    $msg = ($r.Error -replace '\s+', ' ').Trim()
                    if ($msg.Length -gt 80) { $msg.Substring(0, 77) + '...' } else { $msg }
                } else {
                    'no error details'
                }
                Write-Host "$tag $sym $name $osTag $detail" -ForegroundColor $color
            }
            finally {
                [System.Threading.Monitor]::Exit($p)
            }

            # Emit the result for the downstream pipeline (Sort-Object, Export-Excel, etc).
            $r
        }

        # Final summary - useful when the user has redirected output elsewhere and
        # wants the headline number without scrolling.
        $sumColor = if ($progress.Failed -eq 0) { 'Green' } else { 'Yellow' }
        Write-Host "Done. $($progress.Completed - $progress.Failed) succeeded, $($progress.Failed) failed of $($progress.Total)." -ForegroundColor $sumColor
    }
}
