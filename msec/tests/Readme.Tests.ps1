#Requires -Module Pester
#
# The README's Commands section is the only index of what this module does, and it drifts
# silently: a new command ships, the help audit passes, the docs page generates, and the one
# place a person actually browses never mentions it. Grant-MsecAzureDevOpsPermission reached a
# release candidate that way - it appeared in the setup examples, so a search for its name found
# it, while the command list did not have it at all.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
    $script:RepoRoot = Join-Path $PSScriptRoot '..' '..'
    $script:Readme   = Join-Path $script:RepoRoot 'README.md'

    # Only bullet links of the documented form count. A mention in prose or an example is not
    # an index entry - that distinction is exactly what hid the gap.
    $lines = Get-Content $script:Readme
    $start = ($lines | Select-String -Pattern '^## Commands$').LineNumber
    $after = $lines[$start..($lines.Count - 1)]
    $end   = ($after | Select-String -Pattern '^## ').LineNumber | Select-Object -First 1
    $block = if ($end) { $after[0..($end - 2)] } else { $after }

    $script:Listed = @($block | ForEach-Object {
        if ($_ -match '^- \[([A-Za-z]+-Msec[A-Za-z]*)\]\(\./docs/commands/') { $Matches[1] }
    } | Sort-Object -Unique)

    $script:Exported = @((Get-Command -Module msec).Name)
}
AfterAll { Remove-Module msec -Force -ErrorAction SilentlyContinue }

Describe 'README command index' {

    It 'lists every exported command' {
        $missing = @($script:Exported | Where-Object { $_ -notin $script:Listed })
        $missing -join ', ' | Should -BeNullOrEmpty
    }

    It 'lists nothing the module does not export' {
        # A renamed or removed command leaves a link that 404s on the docs site.
        $ghost = @($script:Listed | Where-Object { $_ -notin $script:Exported })
        $ghost -join ', ' | Should -BeNullOrEmpty
    }

    It 'points every link at a docs page that exists' {
        $broken = @($script:Listed | Where-Object {
            -not (Test-Path (Join-Path $script:RepoRoot "docs/commands/$_.md"))
        })
        $broken -join ', ' | Should -BeNullOrEmpty
    }

    It 'has no heading that swallowed its first bullet' {
        # '### Entra ID- [Get-Msec...' renders as neither a heading nor a list item, and is what
        # a string-replace insert produces when it eats the newline.
        $offenders = @(Get-Content $script:Readme | Where-Object { $_ -match '^#{1,4} .+- \[' })
        $offenders -join ' | ' | Should -BeNullOrEmpty
    }
}
