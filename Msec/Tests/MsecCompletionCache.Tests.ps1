#Requires -Module Pester
#
# Tests for the module's completion cache - the only on-disk state it keeps - and for the
# -Subscription completer that every Azure-facing command shares.
#
# The cache exists so completers never call Azure: one that queries ARM blocks the prompt on
# every Tab, and when ARM is unhealthy it hangs rather than failing fast.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
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
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Msec completion cache' {
    It 'honours MSEC_CACHE_DIR, scopes by tenant, and defaults to per-user state' {
        # The override is what lets the whole suite run without touching the developer's real
        # cache. The tenant folder is what lets two tenants stay warm across a context flip
        # instead of overwriting each other. The default must not be the module folder -
        # routinely read-only, and shared.
        $paths = InModuleScope Msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Tenant = @{ Id = 'tenant-A' } } }
            $a = Get-MsecCachePath -Name 'subscriptions'
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Tenant = @{ Id = 'tenant-B' } } }
            $b = Get-MsecCachePath -Name 'subscriptions'
            $saved = $env:MSEC_CACHE_DIR
            $env:MSEC_CACHE_DIR = $null
            try { $d = Get-MsecCachePath -Name 'subscriptions' } finally { $env:MSEC_CACHE_DIR = $saved }
            [pscustomobject]@{ A = $a; B = $b; Default = $d }
        }

        $paths.A | Should -Be (Join-Path (Join-Path $script:CacheDir 'tenant-A') 'subscriptions.json')
        $paths.B | Should -Be (Join-Path (Join-Path $script:CacheDir 'tenant-B') 'subscriptions.json')
        $paths.Default | Should -Not -BeLike "$((Get-Module Msec).ModuleBase)*"
    }

    It 'round-trips items, and degrades to empty rather than throwing' {
        # Read-MsecCache is called from completers, so a missing or hand-mangled file must
        # degrade to silence - a completer that throws breaks the prompt itself.
        $result = InModuleScope Msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Tenant = @{ Id = 'tenant-1' } } }
            Save-MsecCache -Name 'subscriptions' -Item @(
                [pscustomobject]@{ Id = 'sub-1'; Name = 'Contoso-Prod'; TenantId = 't1' }
            )
            $corrupt = Get-MsecCachePath -Name 'corrupt'
            New-Item -ItemType Directory -Path (Split-Path -Parent $corrupt) -Force | Out-Null
            Set-Content -LiteralPath $corrupt -Value '{ not json'
            $saved = @(Read-MsecCache -Name 'subscriptions')
            # Another tenant reads its own folder, so it sees nothing of this one - and this
            # one's cache survives the flip rather than being discarded and overwritten.
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Tenant = @{ Id = 'a-different-tenant' } } }
            $otherTenant = @(Read-MsecCache -Name 'subscriptions')
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Tenant = @{ Id = 'tenant-1' } } }
            [pscustomobject]@{
                Saved       = $saved
                Missing     = @(Read-MsecCache -Name 'no-such-cache')
                Corrupt     = @(Read-MsecCache -Name 'corrupt')
                OtherTenant = $otherTenant
                StillThere  = @(Read-MsecCache -Name 'subscriptions')
            }
        }

        $result.Saved.Name        | Should -Be 'Contoso-Prod'
        $result.Missing.Count     | Should -Be 0
        $result.Corrupt.Count     | Should -Be 0
        $result.OtherTenant.Count | Should -Be 0
        $result.StillThere.Name   | Should -Be 'Contoso-Prod'
    }

}

Describe '-Subscription completion' {
    BeforeAll {
        # Both ends have to agree on the tenant, because the cache is partitioned by it: this
        # BeforeAll writes the cache, and the completer under test reads it back - but the
        # completer runs OUTSIDE InModuleScope, via TabExpansion2. Mocking only the write side
        # would send it to a folder the read side never looks in.
        #
        # -ModuleName msec is what makes that work: it intercepts the module's own calls to
        # Get-AzContext wherever they come from, including the completer's
        # `& $module { Read-MsecCache }`. This used to rely on the developer's real context
        # being present on both sides, which is true locally and false on any CI runner.
        Mock -ModuleName msec Get-AzContext -MockWith {
            [pscustomobject]@{ Tenant = @{ Id = 'completion-tenant' } }
        }
        InModuleScope Msec {
            Save-MsecCache -Name 'subscriptions' -Item @(
                [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111'; Name = 'Contoso-Prod';    TenantId = 't1' }
                [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222'; Name = 'Contoso-Prod-US'; TenantId = 't1' }
                [pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333'; Name = 'Fabrikam-Dev';    TenantId = 't1' }
                [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444'; Name = 'Shared-Name';    TenantId = 't1' }
                [pscustomobject]@{ Id = '55555555-5555-5555-5555-555555555555'; Name = 'Shared-Name';    TenantId = 't2' }
            )
        }
    }

    It 'completes -Subscription to the name, or to the id when that name is ambiguous' {
        $line = 'Search-MsecAzureResourceGraph -ResourceType VM -Subscription Contoso'
        $byName = (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches
        $byName.CompletionText | Should -Contain 'Contoso-Prod'
        $byName.CompletionText | Should -Contain 'Contoso-Prod-US'
        $byName.CompletionText | Should -Not -Contain 'Fabrikam-Dev'
        # The id is still shown, so you know which subscription you are picking.
        ($byName | Where-Object CompletionText -eq 'Contoso-Prod').ListItemText |
            Should -Match '11111111-1111-1111-1111-111111111111'

        # A name two subscriptions share is completed as the ID: the name would bind and then
        # fail as ambiguous, so offering it would hand over a value known not to work.
        $line = 'Search-MsecAzureResourceGraph -ResourceType VM -Subscription Shared'
        $ambiguous = (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches.CompletionText
        $ambiguous | Should -Contain '44444444-4444-4444-4444-444444444444'
        $ambiguous | Should -Contain '55555555-5555-5555-5555-555555555555'
        $ambiguous | Should -Not -Contain 'Shared-Name'
    }

    It 'never makes a network call from the completer' {
        # Structural guard, so that "improving" this into a live Get-AzSubscription fails here
        # first rather than hanging someone's prompt during an ARM outage.
        $psm1  = Get-Content -LiteralPath (Join-Path (Get-Module Msec).ModuleBase 'Msec.psm1') -Raw
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
        $cached = InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-current' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { @([pscustomobject]@{ Id = 'brand-new-sub'; Name = 'Newly-Added'; TenantId = 't1' }) }
            Mock Search-AzGraph     -MockWith { @() }
            $null = Search-MsecAzureResourceGraph -ResourceType VM
            Read-MsecCache -Name 'subscriptions'
        }
        $cached.Name | Should -Contain 'Newly-Added'

        InModuleScope Msec {
            Mock Get-AzContext      -MockWith { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-current' }; Tenant = @{ Id = 'tenant-1' } } }
            Mock Get-AzSubscription -MockWith { throw 'should not enumerate when scoped' }
            Mock Search-AzGraph     -MockWith { @() }
            { Search-MsecAzureResourceGraph -ResourceType VM -CurrentSubscription } | Should -Not -Throw
        }
    }
}
