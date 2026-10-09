#Requires -Module Pester
#
# Tests for New-MsecDefenderIndicator. It POSTs to the Defender indicator API on a DELEGATED
# token from the Az context, because that API has no read-only scope and the msec app is
# deliberately read-only.
#
# Covered:
#   - A malformed certificate thumbprint is rejected BEFORE the call. The API accepts one
#     without complaint and the indicator then matches nothing, which is indistinguishable
#     from a working indicator the product is ignoring.
#   - An existing identical indicator is reported, not duplicated.
#   - A failed duplicate check warns and still allows a deliberate creation.
#   - ShouldProcess: -WhatIf creates nothing.
#   - A 403 names the USER's missing scope, not the app's.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module Msec -Force -ErrorAction SilentlyContinue }

Describe 'New-MsecDefenderIndicator' {
    BeforeEach {
        InModuleScope Msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'me@contoso.com' } } }
            Mock Get-AzAccessToken -MockWith { [pscustomobject]@{ Token = 'delegated-token' } }
            Mock Get-MsecEnvironment -MockWith { @{ DefenderResource = 'https://api.securitycenter.microsoft.com' } }
        }
    }

    It 'rejects a malformed certificate thumbprint before sending anything' {
        InModuleScope Msec {
            Mock Invoke-RestMethod -MockWith { throw 'should not be called' }
            $err = $null
            try {
                New-MsecDefenderIndicator -Type CertificateThumbprint -Value 'not-a-thumbprint' `
                    -Action Allowed -Title 't' -Description 'd' -Confirm:$false
            } catch { $err = "$($_.Exception.Message)" }

            $err | Should -Match 'not a SHA-1 certificate thumbprint'
            # The message has to name where the right value comes from, or the reader is left
            # hunting for a thumbprint they already have in another command's output.
            $err | Should -Match 'SignerHash'
            # Validated before the token is even fetched, so nothing reaches the network.
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
    }

    It 'accepts a thumbprint with spaces or colons and normalises it to lower-case hex' {
        $sent = InModuleScope Msec {
            $script:body = $null
            Mock Invoke-RestMethod -ParameterFilter { $Method -ne 'Post' } -MockWith { [pscustomobject]@{ value = @() } }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Post' } -MockWith {
                $script:body = $Body | ConvertFrom-Json
                [pscustomobject]@{ id = '1'; indicatorType = 'CertificateThumbprint'; indicatorValue = $script:body.indicatorValue; action = 'Allowed' }
            }
            New-MsecDefenderIndicator -Type CertificateThumbprint `
                -Value '0D:75:81:D2:C5:1C:59:DF:68:6C:30:00:C7:0B:F5:43:F9:F6:C6:CB' `
                -Action Allowed -Title 't' -Description 'd' -Confirm:$false | Out-Null
            $script:body
        }

        $sent.indicatorValue | Should -Be '0d7581d2c51c59df686c3000c70bf543f9f6c6cb'
    }

    It 'reports an existing identical indicator instead of creating a duplicate' {
        $row = InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Method -ne 'Post' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = '42'; indicatorType = 'CertificateThumbprint'
                                       indicatorValue = '0d7581d2c51c59df686c3000c70bf543f9f6c6cb'
                                       action = 'Allowed'; title = 'existing'; createdBy = 'someone@contoso.com' }
                ) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Post' } -MockWith { throw 'must not POST' }
            New-MsecDefenderIndicator -Type CertificateThumbprint `
                -Value '0d7581d2c51c59df686c3000c70bf543f9f6c6cb' -Action Allowed `
                -Title 't' -Description 'd' -Confirm:$false -WarningAction SilentlyContinue
        }

        $row.AlreadyExisted | Should -BeTrue
        $row.Id | Should -Be '42'
        InModuleScope Msec { Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'Post' } }
    }

    It 'warns but still creates when the duplicate check itself fails' {
        $out = InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Method -ne 'Post' } -MockWith { throw 'transient 500' }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Post' } -MockWith {
                [pscustomobject]@{ id = '7'; indicatorType = 'CertificateThumbprint'; indicatorValue = 'a' * 40; action = 'Allowed' }
            }
            $w = @()
            $r = New-MsecDefenderIndicator -Type CertificateThumbprint -Value ('a' * 40) `
                    -Action Allowed -Title 't' -Description 'd' -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
            [pscustomobject]@{ Row = $r; Warnings = "$($w -join ' ')" }
        }

        $out.Row.Id | Should -Be '7'
        # Silence here would mean the caller believes a guard ran that did not.
        $out.Warnings | Should -Match 'duplicate check did NOT run'
    }

    It 'creates nothing under -WhatIf' {
        InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Method -ne 'Post' } -MockWith { [pscustomobject]@{ value = @() } }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Post' } -MockWith { throw 'must not POST under -WhatIf' }
            New-MsecDefenderIndicator -Type CertificateThumbprint -Value ('b' * 40) `
                -Action Allowed -Title 't' -Description 'd' -WhatIf | Out-Null
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'Post' }
        }
    }

    It 'blames the signed-in user for a 403, not the msec app' {
        $err = InModuleScope Msec {
            Mock Invoke-RestMethod -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            try { New-MsecDefenderIndicator -Type DomainName -Value 'x.example' -Action Block -Title 't' -Description 'd' -Confirm:$false; $null }
            catch { "$($_.Exception.Message)" }
        }

        $err | Should -Match 'Ti\.ReadWrite'
        $err | Should -Match 'me@contoso\.com'
        # The app is deliberately not the identity here, so the message must not send anyone to New-MsecApp.
        $err | Should -Not -Match 'New-MsecApp'
    }

    It 'refuses without an Azure context and says why the app cannot stand in' {
        $err = InModuleScope Msec {
            Mock Get-AzContext -MockWith { $null }
            try { New-MsecDefenderIndicator -Type DomainName -Value 'x.example' -Action Block -Title 't' -Description 'd' -Confirm:$false; $null }
            catch { "$($_.Exception.Message)" }
        }

        $err | Should -Match 'Connect-AzAccount'
        $err | Should -Match 'no read-only scope'
    }
}
