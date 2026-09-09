#Requires -Module Pester
#
# Tests for Get-MsecKeyVaultCertificate.
#
# The behaviour that matters most is the one a live run proved out immediately: on a real
# tenant, 185 of 258 vaults could be LISTED but not READ INTO. Listing vaults is control-plane
# (Reader); listing the certificates inside one is data-plane, granted separately. Having the
# first without the second is the normal state for an auditor's account.
#
# If an unreadable vault contributed no rows, that inventory would have read as "18
# certificates" with no hint that 71% of the estate was never examined.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecKeyVaultCertificate' {

    BeforeEach {
        InModuleScope Msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-1' } } }
        }
    }

    It 'tells a vault it cannot read from an empty one' {
        $rows = InModuleScope Msec {
            Mock Get-AzKeyVault -MockWith {
                [pscustomobject]@{ VaultName = 'kv-ok';      ResourceGroupName = 'rg'; Location = 'westeurope'; VaultUri = 'https://kv-ok.vault.azure.net/' }
                [pscustomobject]@{ VaultName = 'kv-empty';   ResourceGroupName = 'rg'; Location = 'westeurope'; VaultUri = 'https://kv-empty.vault.azure.net/' }
                [pscustomobject]@{ VaultName = 'kv-denied';  ResourceGroupName = 'rg'; Location = 'westeurope'; VaultUri = 'https://kv-denied.vault.azure.net/' }
            }
            Mock Get-AzKeyVaultCertificate -ParameterFilter { $VaultName -eq 'kv-denied' } -MockWith {
                throw 'Operation returned an invalid status code: Forbidden'
            }
            Mock Get-AzKeyVaultCertificate -ParameterFilter { $VaultName -eq 'kv-empty' } -MockWith { @() }
            Mock Get-AzKeyVaultCertificate -ParameterFilter { $VaultName -eq 'kv-ok' -and -not $Name } -MockWith {
                [pscustomobject]@{ Name = 'wildcard' }
            }
            Mock Get-AzKeyVaultCertificate -ParameterFilter { $VaultName -eq 'kv-ok' -and $Name -eq 'wildcard' } -MockWith {
                [pscustomobject]@{
                    Name = 'wildcard'; Enabled = $true; Thumbprint = 'AABB'
                    NotBefore = [datetime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
                    Expires   = [datetime]::UtcNow.AddDays(40)
                    SecretId  = 'https://kv-ok.vault.azure.net/secrets/wildcard'
                    Id        = 'https://kv-ok.vault.azure.net/certificates/wildcard'
                    Certificate = [pscustomobject]@{ Subject = 'CN=*.contoso.com'; Issuer = 'CN=DigiCert' }
                }
            }
            Get-MsecKeyVaultCertificate -WarningAction SilentlyContinue
        }

        @($rows).Count | Should -Be 3

        # Three different answers, and only one of them is good news.
        ($rows | Where-Object VaultName -eq 'kv-ok').Status     | Should -Be 'Present'
        ($rows | Where-Object VaultName -eq 'kv-empty').Status  | Should -Be 'Empty'
        ($rows | Where-Object VaultName -eq 'kv-denied').Status | Should -Be 'Unreadable'

        # The denied vault must not look like it holds nothing.
        ($rows | Where-Object VaultName -eq 'kv-denied').Name | Should -BeNullOrEmpty
        ($rows | Where-Object VaultName -eq 'kv-denied').DaysUntilExpiry | Should -BeNullOrEmpty

        $cert = $rows | Where-Object Status -eq 'Present'
        $cert.Subject | Should -Be 'CN=*.contoso.com'
        $cert.Issuer  | Should -Be 'CN=DigiCert'
        $cert.SecretId | Should -Be 'https://kv-ok.vault.azure.net/secrets/wildcard'
    }

    It 'names the data-plane grant when a vault is forbidden' {
        $warnings = @()
        InModuleScope Msec {
            Mock Get-AzKeyVault -MockWith {
                [pscustomobject]@{ VaultName = 'kv-denied'; ResourceGroupName = 'rg'; Location = 'we'; VaultUri = 'u' }
            }
            Mock Get-AzKeyVaultCertificate -MockWith { throw 'Forbidden' }
            Get-MsecKeyVaultCertificate
        } -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

        # Reader on the vault is not enough, and the message has to say so or the reader will
        # go looking at the wrong permission.
        ($warnings -join ' ') | Should -Match 'Key Vault Reader|access policy'
        ($warnings -join ' ') | Should -Match 'Unreadable rather than empty'
    }

    It 'matches -Tag case-insensitively, on key and on value' {
        $rows = InModuleScope Msec {
            Mock Get-AzKeyVault -MockWith {
                # Azure treats tags as case-insensitive; the Az objects expose an ordinary
                # hashtable that is not, so this vault would be missed by an exact match.
                [pscustomobject]@{ VaultName = 'kv-dns'; ResourceGroupName = 'rg'; Location = 'we'; VaultUri = 'u'
                                   Tags = @{ 'product' = 'dns' } }
                [pscustomobject]@{ VaultName = 'kv-other'; ResourceGroupName = 'rg'; Location = 'we'; VaultUri = 'u'
                                   Tags = @{ 'Product' = 'Billing' } }
            }
            Mock Get-AzKeyVaultCertificate -MockWith { @() }
            Get-MsecKeyVaultCertificate -Tag @{ Product = 'DNS' } -WarningAction SilentlyContinue
        }

        @($rows).Count  | Should -Be 1
        $rows.VaultName | Should -Be 'kv-dns'
    }

    It 'keeps expired certificates inside any -ExpiringWithinDays window' {
        $rows = InModuleScope Msec {
            Mock Get-AzKeyVault -MockWith {
                [pscustomobject]@{ VaultName = 'kv'; ResourceGroupName = 'rg'; Location = 'we'; VaultUri = 'u' }
            }
            Mock Get-AzKeyVaultCertificate -ParameterFilter { -not $Name } -MockWith {
                [pscustomobject]@{ Name = 'long-dead' }
                [pscustomobject]@{ Name = 'due-soon' }
                [pscustomobject]@{ Name = 'healthy' }
            }
            Mock Get-AzKeyVaultCertificate -ParameterFilter { $Name } -MockWith {
                $days = switch ($Name) { 'long-dead' { -400 } 'due-soon' { 20 } 'healthy' { 300 } }
                [pscustomobject]@{
                    Name = $Name; Enabled = $true; Thumbprint = 'X'
                    NotBefore = [datetime]::UtcNow.AddDays(-800)
                    Expires = [datetime]::UtcNow.AddDays($days)
                    SecretId = 's'; Id = 'i'
                    Certificate = [pscustomobject]@{ Subject = 'CN=x'; Issuer = 'CN=y' }
                }
            }
            Get-MsecKeyVaultCertificate -ExpiringWithinDays 30 -WarningAction SilentlyContinue
        }

        # A certificate that lapsed 400 days ago is not less urgent than one lapsing next week.
        @($rows | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('due-soon', 'long-dead')
        ($rows | Where-Object Name -eq 'long-dead').IsExpired | Should -BeTrue
    }

    It 'excludes disabled certificates unless asked' {
        $script:Make = {
            InModuleScope Msec -Parameters @{ IncludeDisabled = $args[0] } {
                param($IncludeDisabled)
                Mock Get-AzKeyVault -MockWith {
                    [pscustomobject]@{ VaultName = 'kv'; ResourceGroupName = 'rg'; Location = 'we'; VaultUri = 'u' }
                }
                Mock Get-AzKeyVaultCertificate -ParameterFilter { -not $Name } -MockWith {
                    [pscustomobject]@{ Name = 'live' }; [pscustomobject]@{ Name = 'retired' }
                }
                Mock Get-AzKeyVaultCertificate -ParameterFilter { $Name } -MockWith {
                    [pscustomobject]@{
                        Name = $Name; Enabled = ($Name -eq 'live'); Thumbprint = 'X'
                        NotBefore = [datetime]::UtcNow.AddDays(-10); Expires = [datetime]::UtcNow.AddDays(10)
                        SecretId = 's'; Id = 'i'; Certificate = [pscustomobject]@{ Subject = 'CN=x'; Issuer = 'CN=y' }
                    }
                }
                if ($IncludeDisabled) { Get-MsecKeyVaultCertificate -IncludeDisabled -WarningAction SilentlyContinue }
                else { Get-MsecKeyVaultCertificate -WarningAction SilentlyContinue }
            }
        }

        # A disabled certificate is presented to nothing, so its expiry is not an outage.
        @(& $script:Make $false | ForEach-Object { $_.Name }) | Should -Be @('live')
        @(& $script:Make $true  | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('live', 'retired')
    }

    It 'throws a clear error without an Az context' {
        InModuleScope Msec {
            Mock Get-AzContext -MockWith { $null }
            { Get-MsecKeyVaultCertificate } | Should -Throw '*Connect-AzAccount*'
        }
    }
}
