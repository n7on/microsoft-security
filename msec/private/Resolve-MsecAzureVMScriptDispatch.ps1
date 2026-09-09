function Resolve-MsecAzureVMScriptDispatch {
    <#
    .SYNOPSIS
        Maps an OS + bundled-script base name to the script's path and the matching Azure
        Run-Command id. Single source of truth for the OS -> (file extension, CommandId)
        mapping used when dispatching - throws a clear "<Os> script not found" error if the
        script doesn't exist for that OS.

    .PARAMETER Os
        'Linux' or 'Windows'.
    .PARAMETER ScriptName
        Base name (no extension) of the script under Scripts/VM/<Os>/.

    .OUTPUTS
        PSCustomObject with ScriptPath and CommandId.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Linux', 'Windows')][string] $Os,
        [Parameter(Mandatory)][string] $ScriptName
    )

    # The one place OS dispatch is defined: extension on disk + Az Run-Command id.
    # (Linux runs as root via RunShellScript; Windows as SYSTEM via RunPowerShellScript.)
    $map = @{
        Linux   = @{ Extension = '.sh';  CommandId = 'RunShellScript' }
        Windows = @{ Extension = '.ps1'; CommandId = 'RunPowerShellScript' }
    }

    $info = $map[$Os]
    $path = Join-Path $script:MsecModuleRoot "Scripts/VM/$Os/$ScriptName$($info.Extension)"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "$Os script not found: $path"
    }

    [pscustomobject]@{
        ScriptPath = $path
        CommandId  = $info.CommandId
    }
}
