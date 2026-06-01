function Invoke-MsecVMScriptWindows {
    <#
    .SYNOPSIS
        Runs a bundled PowerShell script on one or more Azure Windows VMs.

    .DESCRIPTION
        Pipeline-friendly. Consumes the Name + ResourceGroupName columns from any VM source
        (Search-MsecGraph, Get-AzVM, hand-built objects) - filter to Windows yourself before
        piping:

            Search-MsecGraph -ResourceType VM | Where-Object Os -eq 'Windows' |
                Invoke-MsecVMScriptWindows -ScriptName os-info

        -ScriptName tab-completes from msec/Scripts/Windows/*.ps1. Names not present there
        are accepted at parameter binding (no class-based ValidateSet) but rejected
        immediately in the function's begin block with a clear path-not-found error - same
        pattern as Search-MsecGraph.

        Execution uses Invoke-AzVMRunCommand with CommandId='RunPowerShellScript'. Scripts
        run as SYSTEM via the VM agent. RBAC: caller needs
        Microsoft.Compute/virtualMachines/runCommand/action on each VM (Virtual Machine
        Contributor covers it).

    .PARAMETER ScriptName
        Base name (no extension) of the script under msec/Scripts/Windows/. Tab-completes
        from that folder.

    .PARAMETER Name
        VM name. Bound from the pipeline.
    .PARAMETER ResourceGroupName
        VM's resource group. Bound from the pipeline.

    .OUTPUTS
        PSCustomObject per VM: VmName, ResourceGroupName, ScriptName, Status, Output, Error,
        DurationSeconds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $base = (Get-Module msec).ModuleBase
            if (-not $base) { return }
            $folder = Join-Path $base 'Scripts/Windows'
            if (-not (Test-Path -LiteralPath $folder)) { return }
            Get-ChildItem -LiteralPath $folder -Filter *.ps1 -File |
                Where-Object { $_.BaseName -like "$wordToComplete*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new(
                        $_.BaseName, $_.BaseName, 'ParameterValue', $_.BaseName)
                }
        })]
        [string] $ScriptName,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $Name,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $ResourceGroupName
    )

    begin {
        if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
            throw 'No Azure context. Run Connect-AzAccount before Invoke-MsecVMScriptWindows.'
        }
        $scriptPath = Join-Path $script:MsecModuleRoot "Scripts/Windows/$ScriptName.ps1"
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw "Windows script not found: $scriptPath"
        }
    }

    process {
        Write-Verbose "Running $ScriptName on $ResourceGroupName/$Name (Windows) via RunPowerShellScript"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = $null
        $errorMessage = $null
        try {
            $resp = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $Name `
                -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath -ErrorAction Stop
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
        }

        $status = if ($errorMessage)    { 'Failed' }
                  elseif ($resp.Status) { $resp.Status }
                  else                  { 'Unknown' }

        [PSCustomObject]@{
            VmName            = $Name
            ResourceGroupName = $ResourceGroupName
            ScriptName        = $ScriptName
            Status            = $status
            Output            = $stdout
            Error             = if ($errorMessage) { $errorMessage } else { $stderr }
            DurationSeconds   = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        }
    }
}
