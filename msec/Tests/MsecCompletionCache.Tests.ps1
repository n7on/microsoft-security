#Requires -Module Pester
#
# Tests for the module's completion cache - the only on-disk state it keeps - and for the
# -SubscriptionId completer that every Azure-facing command shares.
#
# The cache exists so completers never call Azure: one that queries ARM blocks the prompt on
# every Tab, and when ARM is unhealthy it hangs rather than failing fast.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:PrevCacheEnv = $env:MSEC_CACHE_DIR
    $env:MSEC_CACHE_DIR  = Join-Path ([System.IO.Path]::GetTempPath()) "msec-test-cache-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $env:MSEC_CACHE_DIR -Force | Out-Null
    $script:CacheDir = $env:MSEC_CACHE_DIR
}

AfterAll {
    if ($script:CacheDir -and (Test-Path -LiteralPath $script:CacheDir)) {
        Remove-Item -LiteralPath $script:CacheDir -Recurse -Force
    }
    $env:MSEC_CACHE_DIR = $script:PrevCacheEnv
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Msec completion cache' {
    It 'honours MSEC_CACHE_DIR, and otherwise defaults to per-user state' {
        # The override is what lets the whole suite run without touching the developer's real
        # cache. The default must not be the module folder - routinely read-only, and shared.
        (InModuleScope msec { Get-MsecCachePath -Name 'subscriptions' }) |
            Should -Be (Join-Path $script:CacheDir 'subscriptions.json')

        $default = InModuleScope msec {
            $saved = $env:MSEC_CACHE_DIR
            $env:MSEC_CACHE_DIR = $null
            try { Get-MsecCachePath -Name 'subscriptions' } finally { $env:MSEC_CACHE_DIR = $saved }
        }
        $default | Should -Not -BeLike "$((Get-Module msec).ModuleBase)*"
    }

    It 'round-trips items, and degrades to empty rather than throwing' {
        # Read-MsecCache is called from completers, so a missing or hand-mangled file must
        # degrade to silence - a completer that throws breaks the prompt itself.
        $result = InModuleScope msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Tenant = @{ Id = 'tenant-1' } } }
            Save-MsecCache -Name 'subscriptions' -Item @(
                [pscustomobject]@{ Id = 'sub-1'; Name = 'Contoso-Prod'; TenantId = 't1' }
            )
            Set-Content -LiteralPath (Get-MsecCachePath -Name 'corrupt') -Value '{ not json'
            [pscustomobject]@{
                Saved   = @(Read-MsecCache -Name 'subscriptions')
                Missing = @(Read-MsecCache -Name 'no-such-cache')
                Corrupt = @(Read-MsecCache -Name 'corrupt')
            }
        }

        $result.Saved.Name    | Should -Be 'Contoso-Prod'
        $result.Missing.Count | Should -Be 0
        $result.Corrupt.Count | Should -Be 0
    }

    It 'every test file that can trigger a cache write redirects MSEC_CACHE_DIR' {
        # This bit three times: a test mocks Get-AzSubscription, the command under test refreshes
        # the cache on its way past, and the MOCK data lands in the developer's real cache. It is
        # silent - you notice later when tab completion offers 'sub-1'.
        $writers = 'Search-MsecAzureResourceGraph', 'Search-MsecLogAnalytics',
                   'Get-MsecSubscriptionList', 'Save-MsecCache'

        $offenders = Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File | ForEach-Object {
            $text = Get-Content -LiteralPath $_.FullName -Raw
            $triggers = @($writers | Where-Object { $text -match "\b$([regex]::Escape($_))\b" })
            if ($triggers.Count -gt 0 -and $text -notmatch 'MSEC_CACHE_DIR') { $_.Name }
        }

        $offenders | Should -BeNullOrEmpty
    }
}

Describe '-SubscriptionId completion' {
    BeforeAll {
        InModuleScope msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Tenant = @{ Id = 'tenant-1' } } }
            Save-MsecCache -Name 'subscriptions' -Item @(
                [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111'; Name = 'Contoso-Prod';    TenantId = 't1' }
                [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222'; Name = 'Contoso-Prod-US'; TenantId = 't1' }
                [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333'; Name = 'Fabrikam-Dev';    TenantId = 't1' }
            )
        }
    }

    It 'matches on name or id prefix but always inserts the id' {
        # The parameter takes a GUID and nobody remembers GUIDs. Matching the name while
        # completing to the id is the entire point.
        $line = 'Search-MsecAzureResourceGraph -ResourceType VM -SubscriptionId Contoso'
        $byName = (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches
        $byName.CompletionText | Should -Contain '11111111-1111-1111-1111-111111111111'
        $byName.CompletionText | Should -Contain '22222222-2222-2222-2222-222222222222'
        $byName.CompletionText | Should -Not -Contain '33333333-3333-3333-3333-333333333333'
        # The list shows the name, or you are picking a GUID blind.
        ($byName | Where-Object CompletionText -eq '11111111-1111-1111-1111-111111111111').ListItemText |
            Should -Match 'Contoso-Prod'

        $line = 'Search-MsecAzureResourceGraph -ResourceType VM -SubscriptionId 33333'
        (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText |
            Should -Contain '33333333-3333-3333-3333-333333333333'
    }

    It 'never makes a network call from the completer' {
        # Structural guard, so that "improving" this into a live Get-AzSubscription fails here
        # first rather than hanging someone's prompt during an ARM outage.
        $psm1  = Get-Content -LiteralPath (Join-Path (Get-Module msec).ModuleBase 'msec.psm1') -Raw
        $start = $psm1.IndexOf('$msecSubscriptionCompleter = {')
        $body  = $psm1.Substring($start, $psm1.IndexOf('Register-ArgumentCompleter') - $start)

        foreach ($forbidden in 'Get-AzSubscription', 'Search-AzGraph', 'Invoke-Az') {
            $body | Should -Not -Match ([regex]::Escape($forbidden))
        }
    }

    It 'refreshes the cache on an estate-wide call, but does not enumerate when scoped' {
        # The cmdlet already enumerates every accessible subscription when unscoped, so keeping
        # the cache warm costs nothing - and -CurrentSubscription must not smuggle that
        # enumeration back in.
        $cached = InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-current' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'brand-new-sub'; Name = 'Newly-Added'; TenantId = 't1' }) }
            Mock Search-AzGraph     -MockWith { @() }
            $null = Search-MsecAzureResourceGraph -ResourceType VM
            Read-MsecCache -Name 'subscriptions'
        }
        $cached.Name | Should -Contain 'Newly-Added'

        InModuleScope msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-current' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { throw 'should not enumerate when scoped' }
            Mock Search-AzGraph     -MockWith { @() }
            { Search-MsecAzureResourceGraph -ResourceType VM -CurrentSubscription } | Should -Not -Throw
        }
    }
}
