#Requires -Module Pester
#
# Tests for Get-MsecAzureDevOpsSecureFile.
#
# The one thing that must never change: this command does not call the download endpoint. Secure
# files hold signing certificates and private keys, and an inventory that fetches them to produce
# itself is worse than no inventory. A test asserts no request ever goes near it.
#
# Kind is a guess from the file extension and is documented as one. The NAME is always returned so
# the guess can be checked rather than trusted - a '.key' could be anything.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureDevOpsSecureFile' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            function script:Set-FileMock {
                param($Files, $Open = @())
                $script:MockFiles = $Files
                $script:MockOpen  = @($Open)
                Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                    if ($Path -eq '_apis/projects') { return @([pscustomobject]@{ id = 'p1'; name = 'Viedoc4' }) }
                    if ($Path -match '/securefiles$') { return $script:MockFiles }
                    if ($Path -match '/pipelinePermissions/securefile/(\d+)$') {
                        if ($script:MockOpen -contains [int] $Matches[1]) {
                            return [pscustomobject]@{ allPipelines = [pscustomobject]@{ authorized = $true }; pipelines = @(1) }
                        }
                        return [pscustomobject]@{ pipelines = @(1) }
                    }
                    return @()
                }
            }
            function script:New-File {
                param([int] $Id, [string] $Name, [int] $AgeDays = 10)
                [pscustomobject]@{ id = $Id; name = $Name
                                   createdOn = [datetime]::UtcNow.AddDays(-$AgeDays)
                                   modifiedOn = [datetime]::UtcNow.AddDays(-$AgeDays)
                                   createdBy = [pscustomobject]@{ displayName = 'Ada' } }
            }
        }
    }

    It 'never requests the file contents' {
        InModuleScope msec {
            . Set-FileMock -Files @(New-File -Id 1 -Name 'signing.pfx')
            Get-MsecAzureDevOpsSecureFile -Organization 'contoso' | Out-Null

            # There IS a download endpoint. An inventory that fetches private keys to list them
            # would be worse than no inventory.
            Should -Invoke Invoke-MsecAzureDevOpsRequest -Times 0 -Exactly -ParameterFilter {
                $Path -match 'securefiles/.+' -and $Path -notmatch 'pipelinePermissions'
            }
        }
    }

    It 'guesses the kind from the extension and keeps the name' {
        $rows = InModuleScope msec {
            . Set-FileMock -Files @(
                (New-File -Id 1 -Name 'signing.pfx')
                (New-File -Id 2 -Name 'release.jks')
                (New-File -Id 3 -Name 'app.mobileprovision')
                (New-File -Id 4 -Name 'migrations.done.key')
                (New-File -Id 5 -Name 'notes.txt'))
            Get-MsecAzureDevOpsSecureFile -Organization 'contoso'
        }

        ($rows | Where-Object Name -eq 'signing.pfx').Kind         | Should -Be 'Certificate'
        ($rows | Where-Object Name -eq 'release.jks').Kind         | Should -Be 'Keystore'
        ($rows | Where-Object Name -eq 'app.mobileprovision').Kind | Should -Be 'ProvisioningProfile'
        # A .key could be anything - it is grouped, not identified, which is why the name stays.
        ($rows | Where-Object Name -eq 'migrations.done.key').Kind | Should -Be 'Key'
        ($rows | Where-Object Name -eq 'notes.txt').Kind           | Should -Be 'Other'
    }

    It 'reports age, because signing material expires' {
        $rows = InModuleScope msec {
            . Set-FileMock -Files @(New-File -Id 1 -Name 'old.pfx' -AgeDays 1479)
            Get-MsecAzureDevOpsSecureFile -Organization 'contoso'
        }

        # Measured live: keys uploaded four years ago, still present.
        $rows.AgeDays | Should -Be 1479
        $rows.AgeDays | Should -BeOfType [int]
    }

    It 'flags a file any pipeline may use' {
        $rows = InModuleScope msec {
            . Set-FileMock -Files @((New-File -Id 7 -Name 'open.pfx'), (New-File -Id 8 -Name 'closed.pfx')) -Open @(7)
            Get-MsecAzureDevOpsSecureFile -Organization 'contoso'
        }

        ($rows | Where-Object Name -eq 'open.pfx').OpenToAllPipelines   | Should -BeTrue
        ($rows | Where-Object Name -eq 'closed.pfx').OpenToAllPipelines | Should -BeFalse
    }

    It 'throws a clear error when not connected' {
        InModuleScope msec {
            $script:MsecSession = $null
            { Get-MsecAzureDevOpsSecureFile -Organization 'contoso' } | Should -Throw '*Connect-Msec*'
        }
    }
}
