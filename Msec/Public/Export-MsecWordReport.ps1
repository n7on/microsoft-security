function Export-MsecWordReport {
    <#
    .SYNOPSIS
        Build a Word (.docx) report from any pipeline of objects. Detects the shape
        of the input and renders with the matching template.

    .DESCRIPTION
        Shape-aware: the function inspects the first row's properties and picks the
        right layout.

          - VMScript : Invoke-MsecAzureVMScript rows (have VmName + ScriptName + Output).
                      One VM per page, with captured Output/Error rendered in
                      Courier New. The ISO-27001-evidence layout.
          - Generic  : anything else. A single Word table whose columns are the
                      visible properties of the first row. Useful for piping things
                      like Get-MsecSecureScore, Get-MsecIntuneConfigurationProfile, etc.

        Pure-PowerShell via PSWriteOffice (which wraps OfficeIMO). No pandoc,
        no Word, no Windows-only Interop. Install once:

            Install-Module PSWriteOffice -Scope CurrentUser

    .EXAMPLE
        # VMScript-shaped input -> one VM per page, monospaced script output.
        Search-MsecAzureResourceGraph -ResourceType VM | Where-Object Running |
            Invoke-MsecAzureVMScript -ScriptName ntp-status |
            Export-MsecWordReport -Path ./ntp-evidence.docx -Title 'NTP / Time sync evidence'

    .EXAMPLE
        # Anything else -> single banded-row Word table.
        Get-MsecSecureScore -History 12 |
            Export-MsecWordReport -Path ./secure-score-history.docx -Title 'Secure Score Trend'

    .PARAMETER InputObject
        Pipeline input. Any shape - the function detects it after the pipeline ends.

    .PARAMETER Path
        Output .docx path. Existing files are overwritten.

    .PARAMETER Title
        Cover-page title. Defaults to a shape-appropriate label when omitted.

    .PARAMETER Subtitle
        Optional subtitle / context line (e.g. 'ISO 27001 A.8.17 Evidence').

    .PARAMETER TableStyle
        Word table style for the Generic shape. Defaults to 'PlainTable3' (banded
        rows + bold header). Any value of OfficeIMO.Word.WordTableStyle is valid
        (TableGrid, GridTable1Light, GridTable4Accent1, ...). Ignored for the
        VMScript shape.

    .OUTPUTS
        FileInfo for the produced .docx.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject] $InputObject,

        [Parameter(Mandatory)]
        [string] $Path,

        [string] $Title,
        [string] $Subtitle,
        [string] $TableStyle = 'PlainTable3'
    )

    begin {
        if (-not (Get-Module -ListAvailable -Name PSWriteOffice)) {
            throw 'PSWriteOffice is required for Export-MsecWordReport. Install with: Install-Module PSWriteOffice -Scope CurrentUser'
        }
        Import-Module PSWriteOffice -ErrorAction Stop

        # Collect rows so we know the total for the cover page AND can inspect the
        # first row's shape before deciding the layout.
        $rows = [System.Collections.Generic.List[psobject]]::new()
    }

    process {
        $rows.Add($InputObject)
    }

    end {
        if ($rows.Count -eq 0) {
            Write-Warning 'No input rows; nothing to export.'
            return
        }

        # Shape detection: VMScript rows are identified by the three properties that
        # together don't occur on any other msec output shape. Everything else falls
        # to a flat Word table.
        $names = $rows[0].PSObject.Properties.Name
        $shape = if (($names -contains 'VmName') -and
                     ($names -contains 'ScriptName') -and
                     ($names -contains 'Output')) {
            'VMScript'
        }
        else {
            'Generic'
        }

        if (-not $Title) {
            $Title = if ($shape -eq 'VMScript') { 'msec VM script report' } else { 'msec report' }
        }

        $generatedAt = (Get-Date).ToUniversalTime().ToString('u')

        # The DSL scriptblock runs in PSWriteOffice's context - GetNewClosure captures
        # the surrounding state (Title/Subtitle/rows/shape/generatedAt/TableStyle) so
        # they resolve inside.
        $content = {
            # Cover (common to both shapes)
            Add-OfficeWordParagraph -Text $Title -Style 'Heading1' | Out-Null
            if ($Subtitle) {
                Add-OfficeWordParagraph -Text $Subtitle -Style 'Heading2' | Out-Null
            }
            Add-OfficeWordParagraph -Text "Generated:  $generatedAt" | Out-Null
            Add-OfficeWordParagraph -Text "Total rows: $($rows.Count)" | Out-Null

            if ($shape -eq 'VMScript') {
                # One section per VM - default section break is NextPage, so each
                # VM is its own page. Property accesses are guarded against optional
                # fields (ResourceGroupName, Os, Status, ...) so this still works
                # for hand-built rows that have only VmName + ScriptName + Output.
                foreach ($r in $rows) {
                    Add-OfficeWordSection {
                        Add-OfficeWordParagraph -Text "VM: $($r.VmName)" -Style 'Heading1' | Out-Null
                        if ($r.PSObject.Properties.Name -contains 'ResourceGroupName') {
                            Add-OfficeWordParagraph -Text "Resource group: $($r.ResourceGroupName)" | Out-Null
                        }
                        if ($r.PSObject.Properties.Name -contains 'Os') {
                            Add-OfficeWordParagraph -Text "OS:             $($r.Os)" | Out-Null
                        }
                        Add-OfficeWordParagraph -Text "Script:         $($r.ScriptName)" | Out-Null
                        if ($r.PSObject.Properties.Name -contains 'Status') {
                            Add-OfficeWordParagraph -Text "Status:         $($r.Status)" | Out-Null
                        }
                        if ($r.PSObject.Properties.Name -contains 'DurationSeconds' -and $null -ne $r.DurationSeconds) {
                            Add-OfficeWordParagraph -Text "Duration:       $($r.DurationSeconds) s" | Out-Null
                        }
                        Add-OfficeWordParagraph -Text '' | Out-Null

                        Add-OfficeWordParagraph -Text 'Output' -Style 'Heading2' | Out-Null
                        if ($r.Output) {
                            foreach ($line in ($r.Output -split "`n")) {
                                $p = Add-OfficeWordParagraph -Text ($line.TrimEnd("`r")) -PassThru
                                [void]$p.SetFontFamily('Courier New')
                                [void]$p.SetFontSize(10)
                            }
                        }
                        else {
                            Add-OfficeWordParagraph -Text '(no output)' | Out-Null
                        }

                        if (($r.PSObject.Properties.Name -contains 'Error') -and $r.Error) {
                            Add-OfficeWordParagraph -Text '' | Out-Null
                            Add-OfficeWordParagraph -Text 'Error' -Style 'Heading2' | Out-Null
                            foreach ($line in ($r.Error -split "`n")) {
                                $p = Add-OfficeWordParagraph -Text ($line.TrimEnd("`r")) -PassThru
                                [void]$p.SetFontFamily('Courier New')
                                [void]$p.SetFontSize(10)
                            }
                        }
                    } | Out-Null
                }
            }
            else {
                # Generic: dump all rows as a single Word table. Columns are
                # auto-derived from the first row's visible properties by
                # PSWriteOffice.
                Add-OfficeWordParagraph -Text '' | Out-Null
                Add-OfficeWordTable -InputObject $rows -Style $TableStyle | Out-Null
            }
        }.GetNewClosure()

        New-OfficeWord -OutputPath $Path -Content $content | Out-Null
        Get-Item -LiteralPath $Path
    }
}
