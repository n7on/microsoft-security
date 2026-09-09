#Requires -Module Pester
#
# Guards the manifest against the whole test suite's blind spot.
#
# Every other test runs inside InModuleScope, which can see functions the module does NOT
# export. So a new command in Public/ that never made it into FunctionsToExport passes every
# test, generates its help, and is simply absent when someone imports the module. That has
# happened here.
#
# These two tests compare the filesystem to the manifest, from OUTSIDE the module, which is the
# only place the discrepancy is visible.

BeforeAll {
    $script:ModuleRoot   = Join-Path $PSScriptRoot '..'
    $script:ManifestPath = Join-Path $script:ModuleRoot 'Msec.psd1'

    $script:Exported = @((Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop).ExportedFunctions.Keys)
    $script:PublicFunctions = @(
        Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Public') -Filter '*.ps1' -File |
            ForEach-Object BaseName
    )
}

Describe 'Msec.psd1' {
    It 'exports every command in Public/' {
        # The failure this exists for: the file is there, the function is defined, the tests
        # pass, and Get-Command finds nothing because the manifest was never updated.
        $missing = @($script:PublicFunctions | Where-Object { $_ -notin $script:Exported })
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'every Public/*.ps1 must be in FunctionsToExport'
    }

    It 'exports nothing that no longer exists' {
        # The other direction: a command removed from Public/ but left in the manifest. The
        # module still imports, but Test-ModuleManifest reports a command nobody can call.
        $orphaned = @($script:Exported | Where-Object { $_ -notin $script:PublicFunctions })
        $orphaned -join ', ' | Should -BeNullOrEmpty -Because 'FunctionsToExport must not name a command with no file'
    }

    It 'exports the file name, so Public/ is the source of truth' {
        # One function per file, named for the file. The two checks above only mean anything
        # if that convention holds - a file defining a differently-named function would pass
        # both while exporting nothing usable.
        foreach ($name in $script:PublicFunctions) {
            $path = Join-Path $script:ModuleRoot "Public/$name.ps1"
            $content = Get-Content -Path $path -Raw
            $content | Should -Match "function\s+$([regex]::Escape($name))\s*\{" -Because "$name.ps1 should define function $name"
        }
    }
}
