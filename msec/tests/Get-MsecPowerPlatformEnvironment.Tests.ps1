#Requires -Module Pester
#
# Tests for Get-MsecPowerPlatformEnvironment.
#
# The trap this exists for: DLP SCOPE IS A FILTER TYPE, NOT A LIST. A connector policy carries
# environmentFilterType of 'none' (every environment), 'include' (only the listed ones) or
# 'exclude' (all but the listed ones). Reading only .environments would report a tenant-wide
# policy - filterType 'none', empty list - as covering nothing, which is the most dangerous way
# to be wrong here: it turns a protected tenant into a page of false findings, and the real
# uncovered environments get lost in them.
#
# And the usual one: policies unreadable must leave IsCoveredByDlp null, never false.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop

    $script:StubbedAz = @()
    $azStubs = @{
        'Get-AzContext'     = { [CmdletBinding()] param() }
        'Get-AzAccessToken' = { [CmdletBinding()] param($ResourceUrl) }
    }
    foreach ($c in $azStubs.Keys) {
        if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
            Set-Item "function:global:$c" -Value $azStubs[$c] -Force
            $script:StubbedAz += $c
        }
    }
}
AfterAll {
    foreach ($c in $script:StubbedAz) { Remove-Item "function:global:$c" -ErrorAction SilentlyContinue }
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecPowerPlatformEnvironment' {

    BeforeEach {
        InModuleScope msec {
            Mock Get-AzContext     -MockWith { [pscustomobject]@{ Account = 'me' } }
            Mock Get-AzAccessToken -MockWith { [pscustomobject]@{ Token = 'tok' } }
        }
    }

    It "treats environmentFilterType 'none' as covering every environment" {
        $rows = InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                if ("$Uri" -like '*scopes/admin/environments*') {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ name = 'env-1'; location = 'europe'
                                           properties = [pscustomobject]@{ displayName = 'Default'; isDefault = $true; environmentSku = 'Default' } }) }
                }
                else {
                    # Tenant-wide policy: filter type 'none' and an EMPTY environment list.
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ displayName = 'Tenant DLP'
                                           environments = [pscustomobject]@{ environmentFilterType = 'none'; environments = @() } }) }
                }
            }
            Get-MsecPowerPlatformEnvironment
        }

        $rows[0].IsCoveredByDlp | Should -BeTrue
        $rows[0].DlpPolicies | Should -Be 'Tenant DLP'
    }

    It "applies an 'include' policy only to the listed environments" {
        $rows = InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                if ("$Uri" -like '*scopes/admin/environments*') {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ name = 'env-1'; properties = [pscustomobject]@{ displayName = 'Listed' } }
                        [pscustomobject]@{ name = 'env-2'; properties = [pscustomobject]@{ displayName = 'Not listed' } }) }
                }
                else {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ displayName = 'Scoped DLP'
                                           environments = [pscustomobject]@{ environmentFilterType = 'include'
                                                                             environments = @([pscustomobject]@{ name = 'env-1' }) } }) }
                }
            }
            Get-MsecPowerPlatformEnvironment
        }

        ($rows | Where-Object DisplayName -eq 'Listed').IsCoveredByDlp     | Should -BeTrue
        ($rows | Where-Object DisplayName -eq 'Not listed').IsCoveredByDlp | Should -BeFalse
    }

    It "applies an 'exclude' policy to everything except the listed environments" {
        $rows = InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                if ("$Uri" -like '*scopes/admin/environments*') {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ name = 'env-1'; properties = [pscustomobject]@{ displayName = 'Carved out' } }
                        [pscustomobject]@{ name = 'env-2'; properties = [pscustomobject]@{ displayName = 'Everything else' } }) }
                }
                else {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ displayName = 'All but one'
                                           environments = [pscustomobject]@{ environmentFilterType = 'exclude'
                                                                             environments = @([pscustomobject]@{ name = 'env-1' }) } }) }
                }
            }
            Get-MsecPowerPlatformEnvironment
        }

        ($rows | Where-Object DisplayName -eq 'Carved out').IsCoveredByDlp      | Should -BeFalse
        ($rows | Where-Object DisplayName -eq 'Everything else').IsCoveredByDlp | Should -BeTrue
    }

    It 'reports IsCoveredByDlp as null when the policy list cannot be read' {
        $rows = InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                if ("$Uri" -like '*scopes/admin/environments*') {
                    [pscustomobject]@{ value = @([pscustomobject]@{ name = 'env-1'; properties = [pscustomobject]@{ displayName = 'Env' } }) }
                }
                else { throw 'Forbidden' }
            }
            Get-MsecPowerPlatformEnvironment -WarningAction SilentlyContinue
        }

        # $false would state the environment is definitely unprotected. Nothing established that.
        $rows[0].IsCoveredByDlp | Should -BeNullOrEmpty
        $rows[0].DlpPolicyCount | Should -BeNullOrEmpty
    }

    It 'does not assume an unrecognised filter type is harmless' {
        $rows = InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                if ("$Uri" -like '*scopes/admin/environments*') {
                    [pscustomobject]@{ value = @([pscustomobject]@{ name = 'env-1'; properties = [pscustomobject]@{ displayName = 'Env' } }) }
                }
                else {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ displayName = 'Future policy'
                                           environments = [pscustomobject]@{ environmentFilterType = 'somethingNew'; environments = @() } }) }
                }
            }
            Get-MsecPowerPlatformEnvironment
        }

        # The policy is not counted as covering, so the environment still reads uncovered
        # rather than being silently credited with protection msec does not understand.
        $rows[0].IsCoveredByDlp | Should -BeFalse
    }

    It 'returns only uncovered environments with -UncoveredOnly' {
        $rows = InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                if ("$Uri" -like '*scopes/admin/environments*') {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ name = 'env-1'; properties = [pscustomobject]@{ displayName = 'Covered' } }
                        [pscustomobject]@{ name = 'env-2'; properties = [pscustomobject]@{ displayName = 'Open' } }) }
                }
                else {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ displayName = 'DLP'
                                           environments = [pscustomobject]@{ environmentFilterType = 'include'
                                                                             environments = @([pscustomobject]@{ name = 'env-1' }) } }) }
                }
            }
            Get-MsecPowerPlatformEnvironment -UncoveredOnly
        }

        $rows.Count | Should -Be 1
        $rows[0].DisplayName | Should -Be 'Open'
    }

    It 'names the role needed when Power Platform answers 403' {
        InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                $response = [pscustomobject]@{ StatusCode = 403 }
                $ex = [System.Exception]::new('Forbidden')
                Add-Member -InputObject $ex -NotePropertyName Response -NotePropertyValue $response -Force
                throw $ex
            }
            # A bare 'Forbidden' sends the reader looking at app permissions, which are not
            # involved at all - this command runs as the user.
            { Get-MsecPowerPlatformEnvironment } | Should -Throw '*Power Platform Administrator*'
        }
    }
}
