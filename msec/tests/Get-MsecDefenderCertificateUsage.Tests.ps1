#Requires -Module Pester
#
# Tests for Get-MsecDefenderCertificateUsage. It groups DeviceFileCertificateInfo by signing
# certificate and projects validity, trust and device counts.
#
# Covered:
#   - IsTrusted arrives as a NUMBER through the OData surface. Casting to [bool] would make
#     an untrusted certificate read as trusted, since [bool]"0" is $true - the same trap that
#     made Secure Score report every control as enabled.
#   - DaysUntilExpiry is $null, never a sentinel, when the record carries no expiry.
#   - -ExpiringWithinDays must not silently include certificates with unknown expiry.
#   - SignerHash is passed through verbatim: it is the thumbprint a Defender indicator takes.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module Msec -Force -ErrorAction SilentlyContinue }

Describe 'Get-MsecDefenderCertificateUsage' {
    BeforeEach {
        InModuleScope Msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Search-MsecDefenderHunting -MockWith {
                @(
                    [pscustomobject]@{
                        Signer = 'Anthropic, PBC'; Issuer = 'DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1'
                        SignerHash = '0d7581d2c51c59df686c3000c70bf543f9f6c6cb'; IssuerHash = '7b0f'
                        CertificateSerialNumber = '0ed59ca47f15d09a57755e4b12d31a50'
                        CertificateCreationTime = '2025-10-14T00:00:00Z'
                        CertificateExpirationTime = (Get-Date).ToUniversalTime().AddDays(13).ToString('o')
                        Files = 144; Devices = 91; IsTrusted = 1; IsRootSignerMicrosoft = 0
                        FirstSeen = '2026-10-01T00:00:00Z'; LastSeen = '2026-10-07T00:00:00Z'
                    }
                    [pscustomobject]@{
                        Signer = 'Code Sign Test (DO NOT TRUST)'; Issuer = 'Microsoft Testing PCA 2010'
                        SignerHash = 'deadbeef'; IssuerHash = 'cafe'; CertificateSerialNumber = '1'
                        CertificateCreationTime = '2020-01-01T00:00:00Z'
                        CertificateExpirationTime = (Get-Date).ToUniversalTime().AddDays(900).ToString('o')
                        Files = 3; Devices = 53; IsTrusted = 0; IsRootSignerMicrosoft = 0
                        FirstSeen = '2026-10-01T00:00:00Z'; LastSeen = '2026-10-07T00:00:00Z'
                    }
                    [pscustomobject]@{
                        Signer = 'No Expiry Recorded'; Issuer = 'Somewhere'
                        SignerHash = 'abc'; IssuerHash = 'def'; CertificateSerialNumber = '2'
                        CertificateCreationTime = $null; CertificateExpirationTime = $null
                        Files = 1; Devices = 1; IsTrusted = 1; IsRootSignerMicrosoft = 0
                        FirstSeen = '2026-10-01T00:00:00Z'; LastSeen = '2026-10-07T00:00:00Z'
                    }
                )
            }
        }
    }

    It 'treats a numeric IsTrusted of 0 as untrusted' {
        $rows = InModuleScope Msec { , @(Get-MsecDefenderCertificateUsage) }

        $anthropic = $rows | Where-Object Signer -eq 'Anthropic, PBC'
        $test      = $rows | Where-Object Signer -match 'DO NOT TRUST'
        $anthropic.IsTrusted | Should -BeTrue
        # [bool] on the value 0 coming back as a string would be $true, and an untrusted
        # certificate on 53 devices would read as trusted.
        $test.IsTrusted | Should -BeFalse
        $test.IsTrusted | Should -BeOfType [bool]
    }

    It 'passes SignerHash through unchanged, because it is the indicator thumbprint' {
        $row = InModuleScope Msec { Get-MsecDefenderCertificateUsage -Signer 'Anthropic' }
        $row.SignerHash | Should -Be '0d7581d2c51c59df686c3000c70bf543f9f6c6cb'
        $row.SignerHash | Should -Match '^[0-9a-f]{40}$'
    }

    It 'reports DaysUntilExpiry as null, not a sentinel, when there is no expiry' {
        $row = InModuleScope Msec { Get-MsecDefenderCertificateUsage -Signer 'No Expiry' }
        $row.DaysUntilExpiry | Should -BeNullOrEmpty
        $row.ValidTo | Should -BeNullOrEmpty
        # Unknown is not the same as 'does not expire'; both would be wrong to assert.
        $row.Expired | Should -BeNullOrEmpty
    }

    It 'excludes unknown-expiry certificates from -ExpiringWithinDays rather than assuming either way' {
        $rows = InModuleScope Msec { , @(Get-MsecDefenderCertificateUsage -ExpiringWithinDays 30) }

        @($rows).Count | Should -Be 1
        $rows[0].Signer | Should -Be 'Anthropic, PBC'
        # Including it would claim an expiry nobody measured; the row is still available
        # without the filter.
        @($rows | Where-Object Signer -eq 'No Expiry Recorded') | Should -BeNullOrEmpty
    }

    It 'computes DaysUntilExpiry against the recorded expiry' {
        $row = InModuleScope Msec { Get-MsecDefenderCertificateUsage -Signer 'Anthropic' }
        $row.DaysUntilExpiry | Should -BeGreaterThan 12
        $row.DaysUntilExpiry | Should -BeLessThan 14
        $row.Expired | Should -BeFalse
    }

    It 'filters by issuer, which is how an Apple signing identity is told from an Authenticode one' {
        $rows = InModuleScope Msec { , @(Get-MsecDefenderCertificateUsage -Issuer 'DigiCert') }
        @($rows).Count | Should -Be 1
        $rows[0].Signer | Should -Be 'Anthropic, PBC'
    }

    It 'warns rather than returning silence when hunting comes back empty' {
        $warning = InModuleScope Msec {
            Mock Search-MsecDefenderHunting -MockWith { @() }
            $w = @()
            Get-MsecDefenderCertificateUsage -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            "$($w -join ' ')"
        }
        $warning | Should -Match 'NOT evidence that nothing is signed'
    }
}
