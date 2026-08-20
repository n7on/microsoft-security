<#
.SYNOPSIS
    Regenerates docs/commands/*.md from the module's comment-based help, using PlatyPS.

.DESCRIPTION
    The generated markdown IS the documentation shipped with the repo and linked from
    README.md, so it is committed rather than built on demand. Run this after changing any
    command's help, and commit the result alongside the code change.

    A script rather than the bare PlatyPS one-liner for two reasons, both of which are
    silent if you forget them:

      1. PlatyPS 0.14 predates -ProgressAction becoming a common parameter in PowerShell
         7.4, so it documents it per-command with an unfilled '{{ Fill ProgressAction
         Description }}' placeholder. It belongs under [<CommonParameters>] and is stripped
         here.

      2. Comment-based help fails SILENTLY in one specific way: any line inside the help
         block that starts with '.word' is read as a help keyword, and an unrecognised one
         truncates everything after it. Get-Help then shows the syntax where the synopsis
         should be, and no description at all. That has already happened twice in this
         module (a wrapped line beginning '.kql'), so it is checked here rather than
         discovered by a reader of the published docs.

.PARAMETER OutputFolder
    Where the markdown goes. Defaults to ./docs/commands relative to the repo root.

.PARAMETER SkipHelpAudit
    Generate without running the help audit first.

.PARAMETER AuditOnly
    Run the help audit and exit non-zero if it finds anything, without generating or
    touching any file. This is what CI runs: it catches the failure modes that render as
    visible placeholders or a missing description, and unlike diffing the generated
    markdown it cannot produce a spurious failure because the runner's PowerShell emits
    common parameters differently from the developer's.

.EXAMPLE
    ./tools/Update-MsecHelp.ps1

.EXAMPLE
    # See what would be reported without writing any files.
    ./tools/Update-MsecHelp.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string] $OutputFolder,

    [Parameter()]
    [switch] $SkipHelpAudit,

    [Parameter()]
    [switch] $AuditOnly
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path $repoRoot 'Msec' 'Msec.psd1'
if (-not $OutputFolder) { $OutputFolder = Join-Path $repoRoot 'docs' 'commands' }

if (-not (Get-Module -ListAvailable PlatyPS)) {
    throw "PlatyPS is not installed. Run: Install-Module PlatyPS -Scope CurrentUser"
}
Import-Module PlatyPS

# The MANIFEST, not the .psm1. PlatyPS documents a module's exported commands, and
# FunctionsToExport is what defines that set - importing the .psm1 directly would document
# whatever happens to be in Public/, including a command not yet exported.
Import-Module $manifest -Force

# ---- Help audit ---------------------------------------------------------------------
# Valid comment-based help keywords. Anything else at the start of a line inside a help
# block silently truncates the rest of that block.
$validKeywords = @(
    'SYNOPSIS', 'DESCRIPTION', 'PARAMETER', 'EXAMPLE', 'INPUTS', 'OUTPUTS', 'NOTES', 'LINK',
    'COMPONENT', 'ROLE', 'FUNCTIONALITY', 'FORWARDHELPTARGETNAME', 'FORWARDHELPCATEGORY',
    'REMOTEHELPRUNSPACE', 'EXTERNALHELP'
)

if (-not $SkipHelpAudit) {
    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($file in Get-ChildItem (Join-Path $repoRoot 'Msec') -Recurse -Filter *.ps1 |
                        Where-Object { $_.FullName -notmatch [regex]::Escape([IO.Path]::DirectorySeparatorChar + 'Tests' + [IO.Path]::DirectorySeparatorChar) }) {
        $lines  = Get-Content -LiteralPath $file.FullName
        $inHelp = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '<#') { $inHelp = $true }
            if ($lines[$i] -match '#>') { $inHelp = $false; continue }
            if (-not $inHelp) { continue }
            if ($lines[$i] -match '^\s*\.([A-Za-z][A-Za-z0-9_]*)' -and
                $Matches[1].ToUpperInvariant() -notin $validKeywords) {
                $problems.Add("$($file.Name):$($i + 1) starts with .$($Matches[1]) - reword or rewrap; this truncates the help block")
            }
        }
    }

    # A command whose Description is empty almost always means the above happened.
    foreach ($command in (Get-Module Msec).ExportedFunctions.Keys | Sort-Object) {
        $help = Get-Help $command -ErrorAction SilentlyContinue
        if (-not $help.Description) { $problems.Add("$command has no parsed DESCRIPTION") }
        if ($help.Synopsis -match [regex]::Escape($command) + '\s+(\[|-)') {
            $problems.Add("$command has no parsed SYNOPSIS (Get-Help is showing the syntax instead)")
        }
        if (-not @($help.Examples.Example).Count) { $problems.Add("$command has no examples") }
    }

    if ($problems.Count) {
        Write-Warning "Help audit found $($problems.Count) issue(s):"
        $problems | ForEach-Object { Write-Warning "  $_" }

        # Advisory when generating locally - you may be mid-edit - but fatal in CI, where
        # the whole point is to stop help that renders as a placeholder from being merged.
        if ($AuditOnly) { throw "Help audit failed with $($problems.Count) issue(s)." }
    }
    else {
        Write-Host 'Help audit: clean.' -ForegroundColor Green
    }
}

if ($AuditOnly) { return }

# ---- Generate -----------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess($OutputFolder, 'Regenerate command markdown')) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    $generated = New-MarkdownHelp -Module Msec -OutputFolder $OutputFolder -Force

    # Strip the -ProgressAction section and its mention in every SYNTAX block. It is a
    # common parameter, covered by [<CommonParameters>], and PlatyPS 0.14 does not know it.
    $stripped = 0
    foreach ($file in $generated) {
        $text = Get-Content -Raw -LiteralPath $file.FullName
        $before = $text

        # The parameter's own section, up to the next '### ' heading.
        $text = $text -replace '(?ms)^### -ProgressAction\r?\n.*?(?=^### )', ''
        # And its appearance in the syntax block, with the surrounding space it leaves.
        $text = $text -replace '\s*\[-ProgressAction <ActionPreference>\]', ''

        if ($text -ne $before) {
            Set-Content -LiteralPath $file.FullName -Value $text -NoNewline
            $stripped++
        }
    }

    Write-Host "Generated $(@($generated).Count) file(s) in $OutputFolder; stripped -ProgressAction from $stripped." -ForegroundColor Green

    $remaining = Select-String -Path (Join-Path $OutputFolder '*.md') -Pattern '\{\{' -ErrorAction SilentlyContinue
    if ($remaining) {
        Write-Warning "$(@($remaining).Count) unfilled PlatyPS placeholder(s) remain - fix the source help, not the markdown:"
        $remaining | ForEach-Object { Write-Warning "  $($_.Filename):$($_.LineNumber) $($_.Line.Trim())" }
    }
}
