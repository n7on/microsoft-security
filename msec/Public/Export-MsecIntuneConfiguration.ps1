function Export-MsecIntuneConfiguration {
    <#
    .SYNOPSIS
        Exports the full contents of an Intune configuration (Settings Catalog policy or
        classic Template) plus its assignments. Pipeline-friendly.

    .DESCRIPTION
        For each input, calls the right Graph endpoints for its Source:

          - SettingsCatalog -> /beta/deviceManagement/configurationPolicies/{id}
                            + /beta/deviceManagement/configurationPolicies/{id}/settings
                            + /beta/deviceManagement/configurationPolicies/{id}/assignments
          - Templates       -> /v1.0/deviceManagement/deviceConfigurations/{id}
                            + /v1.0/deviceManagement/deviceConfigurations/{id}/assignments

        Without -OutDir, emits a PSCustomObject per input - pipe to ConvertTo-Json / Out-File
        as you like. With -OutDir, writes one JSON file per config and emits the FileInfo so
        you can chain with Get-Item / Set-Content / git add.

        Required Graph permission: DeviceManagementConfiguration.Read.All (Application) -
        the same permission Get-MsecIntuneConfiguration uses.

    .PARAMETER Id
        Configuration ID. Bound from the pipeline (via the Id property of objects emitted by
        Get-MsecIntuneConfiguration) or supplied explicitly.

    .PARAMETER Source
        'SettingsCatalog' or 'Templates'. Determines which Graph endpoints to call.
        Bound from the pipeline (Source property) or supplied explicitly.

    .PARAMETER DisplayName
        Used when -OutDir is set, to name the JSON file. Bound from the pipeline; if empty,
        the response's name is used; if still empty, the Id is used.

    .PARAMETER OutDir
        Directory to write per-config JSON files into. Created if it doesn't exist. Filenames
        are sanitised (illegal Windows filename chars replaced with '-'). Existing files are
        overwritten - useful for periodic backups under version control.

    .EXAMPLE
        # Export everything to a folder (idempotent re-run produces a clean diff in git):
        Get-MsecIntuneConfiguration | Export-MsecIntuneConfiguration -OutDir ./intune-backup

    .EXAMPLE
        # Pipe one configuration to JSON for review:
        Get-MsecIntuneConfiguration |
            Where-Object DisplayName -eq 'Win10 Hardening' |
            Export-MsecIntuneConfiguration |
            ConvertTo-Json -Depth 100

    .EXAMPLE
        # Explicit form (no pipeline):
        Export-MsecIntuneConfiguration -Id 'abc-123' -Source Templates |
            ConvertTo-Json -Depth 100 |
            Out-File ./policy.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $Id,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateSet('SettingsCatalog', 'Templates')]
        [string] $Source,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string] $DisplayName,

        [Parameter()]
        [string] $OutDir
    )

    begin {
        Assert-MsecSession
        if ($OutDir -and -not (Test-Path -LiteralPath $OutDir)) {
            New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
        }
    }

    process {
        Write-Verbose "Exporting $Source/$Id"

        $export = switch ($Source) {
            'SettingsCatalog' {
                $policy      = Invoke-MsecGraphRequest -Path "/beta/deviceManagement/configurationPolicies/$Id"
                $settings    = @(Invoke-MsecGraphRequest -Path "/beta/deviceManagement/configurationPolicies/$Id/settings" -All)
                $assignments = @((Invoke-MsecGraphRequest -Path "/beta/deviceManagement/configurationPolicies/$Id/assignments").value)
                [PSCustomObject]@{
                    Id          = $Id
                    Source      = $Source
                    DisplayName = $policy.name
                    ExportedAt  = (Get-Date).ToString('o')
                    Policy      = $policy
                    Settings    = $settings
                    Assignments = $assignments
                }
            }
            'Templates' {
                $config      = Invoke-MsecGraphRequest -Path "/v1.0/deviceManagement/deviceConfigurations/$Id"
                $assignments = @((Invoke-MsecGraphRequest -Path "/v1.0/deviceManagement/deviceConfigurations/$Id/assignments").value)
                [PSCustomObject]@{
                    Id            = $Id
                    Source        = $Source
                    DisplayName   = $config.displayName
                    ExportedAt    = (Get-Date).ToString('o')
                    Configuration = $config
                    Assignments   = $assignments
                }
            }
        }

        if ($OutDir) {
            # Pick the best available name for the file. Pipeline-provided DisplayName wins
            # (matches what Get-MsecIntuneConfiguration projects); fall back to the response's
            # name, then to the bare Id.
            $name = if ($DisplayName)         { $DisplayName }
                    elseif ($export.DisplayName) { $export.DisplayName }
                    else                          { $Id }
            $safeName = ($name -replace '[\\/:*?"<>|]', '-').Trim()
            $file = Join-Path $OutDir "$safeName.json"

            Write-Verbose "Writing $file"
            $export | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $file -Encoding UTF8
            Get-Item -LiteralPath $file
        }
        else {
            $export
        }
    }
}
