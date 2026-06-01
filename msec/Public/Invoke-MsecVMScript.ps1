function Invoke-MsecVMScript {
    <#
    .SYNOPSIS
        Runs a bundled script on one or more Azure VMs. -Os selects the script flavour
        (Linux .sh under Scripts/Linux/ or Windows .ps1 under Scripts/Windows/).

    .DESCRIPTION
        Pipeline-friendly. Consumes the Name + ResourceGroupName columns from any VM source
        (Search-MsecResourceGraph, Get-AzVM, hand-built objects). Filter to the target OS yourself
        before piping - this function does not look at each row's Os property:

            Search-MsecResourceGraph -ResourceType VM | Where-Object Os -eq 'Linux' |
                Invoke-MsecVMScript -Os Linux -ScriptName os-info

        -ScriptName tab-completes from the Scripts/<Os>/ folder based on whichever -Os value
        you've already entered on the command line (so type -Os first, then -ScriptName, for
        completion to work properly).

        Linux scripts run via CommandId='RunShellScript' (as root); Windows scripts via
        CommandId='RunPowerShellScript' (as SYSTEM). RBAC: caller needs
        Microsoft.Compute/virtualMachines/runCommand/action on each VM (Virtual Machine
        Contributor covers it).

    .PARAMETER Os
        'Linux' or 'Windows'. Determines which Scripts/<Os>/ folder is used, the script
        extension (.sh / .ps1), and the run-command id.

    .PARAMETER ScriptName
        Base name (no extension) of the script under msec/Scripts/<Os>/. Tab-completes from
        that folder once -Os is set. Invalid names produce a clear "Linux/Windows script
        not found" error in the function's begin block.

    .PARAMETER Name
        VM name. Bound from the pipeline.
    .PARAMETER ResourceGroupName
        VM's resource group. Bound from the pipeline.

    .EXAMPLE
        Search-MsecResourceGraph -ResourceType VM | Where-Object Os -eq 'Linux' |
            Invoke-MsecVMScript -Os Linux -ScriptName os-info | Format-Table

    .EXAMPLE
        Search-MsecResourceGraph -ResourceType VM | Where-Object Os -eq 'Windows' |
            Invoke-MsecVMScript -Os Windows -ScriptName os-info

    .OUTPUTS
        PSCustomObject per VM: VmName, ResourceGroupName, Os, ScriptName, Status, Output,
        Error, DurationSeconds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Linux', 'Windows')]
        [string] $Os,

        [Parameter(Mandatory)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $os = $fakeBoundParameters['Os']
            if (-not $os) { return }
            $base = (Get-Module msec).ModuleBase
            if (-not $base) { return }
            $folder = Join-Path $base "Scripts/$os"
            if (-not (Test-Path -LiteralPath $folder)) { return }
            $filter = if ($os -eq 'Linux') { '*.sh' } else { '*.ps1' }
            Get-ChildItem -LiteralPath $folder -Filter $filter -File |
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
            throw 'No Azure context. Run Connect-AzAccount before Invoke-MsecVMScript.'
        }

        $extension  = if ($Os -eq 'Linux') { '.sh' }            else { '.ps1' }
        $commandId  = if ($Os -eq 'Linux') { 'RunShellScript' } else { 'RunPowerShellScript' }
        $scriptPath = Join-Path $script:MsecModuleRoot "Scripts/$Os/$ScriptName$extension"

        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw "$Os script not found: $scriptPath"
        }
    }

    process {
        Write-Verbose "Running $ScriptName on $ResourceGroupName/$Name ($Os) via $commandId"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = $null
        $errorMessage = $null
        try {
            $resp = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $Name `
                -CommandId $commandId -ScriptPath $scriptPath -ErrorAction Stop
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
            Os                = $Os
            ScriptName        = $ScriptName
            Status            = $status
            Output            = $stdout
            Error             = if ($errorMessage) { $errorMessage } else { $stderr }
            DurationSeconds   = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        }
    }
}
