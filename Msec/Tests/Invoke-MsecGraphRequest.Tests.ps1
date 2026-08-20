#Requires -Module Pester
#
# Tests for the private Graph caller. It carries three behaviours every command in the
# module depends on and none of them tested directly until now: page concatenation,
# throttle retry, and progress reporting during long paging runs - the last being what
# stops a multi-minute call from looking like a hang.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-MsecGraphRequest' {
    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{
                TenantId = 'tenant'; ClientId = 'client'
                KeyVaultName = 'kv'; KeyName = 'k'
                ThumbprintBytes = [byte[]](1..20)
                # Pre-seeded so no token call is needed.
                Tokens = @{ 'https://graph.microsoft.com' = @{
                    Token = 'mock'; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) } }
            }
        }
    }

    It 'follows @odata.nextLink and concatenates every page' {
        $items = InModuleScope msec {
            $script:Page = 0
            Mock Invoke-RestMethod -MockWith {
                $script:Page++
                if ($script:Page -lt 3) {
                    [pscustomobject]@{
                        value = @([pscustomobject]@{ n = $script:Page })
                        '@odata.nextLink' = "https://graph.microsoft.com/v1.0/next$($script:Page)"
                    }
                }
                else {
                    [pscustomobject]@{ value = @([pscustomobject]@{ n = $script:Page }) }
                }
            }
            @(Invoke-MsecGraphRequest -Path '/v1.0/things' -All)
        }

        $items.Count | Should -Be 3
        $items.n     | Should -Be @(1, 2, 3)
    }

    It 'reports progress while paging, but stays silent for a single-page response' {
        $calls = InModuleScope msec {
            Mock Write-Progress -MockWith { }
            Mock Invoke-RestMethod -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ n = 1 }) }
            }
            $null = @(Invoke-MsecGraphRequest -Path '/v1.0/things' -All)
            # An ordinary one-page call must not litter the host with a progress bar.
            Should -Invoke Write-Progress -Times 0 -Exactly
            'quiet'
        }
        $calls | Should -Be 'quiet'

        $result = InModuleScope msec {
            Mock Write-Progress -MockWith { }
            $script:P = 0
            Mock Invoke-RestMethod -MockWith {
                $script:P++
                if ($script:P -lt 4) {
                    [pscustomobject]@{
                        value = @([pscustomobject]@{ n = $script:P })
                        '@odata.nextLink' = "https://graph.microsoft.com/v1.0/next$($script:P)"
                    }
                }
                else {
                    [pscustomobject]@{ value = @([pscustomobject]@{ n = $script:P }) }
                }
            }
            $rows = @(Invoke-MsecGraphRequest -Path '/v1.0/signIns' -All)

            # Three nextLinks were followed, so three status updates plus one -Completed.
            # Without these a caller blocked here for minutes shows a frozen bar.
            Should -Invoke Write-Progress -Times 3 -Exactly -ParameterFilter { -not $Completed }
            Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter { $Completed }
            $rows.Count
        }
        $result | Should -Be 4
    }

    It 'retries a 429 with backoff and returns the eventual result' {
        $result = InModuleScope msec {
            Mock Start-Sleep -MockWith { }
            $script:Attempt = 0
            Mock Invoke-RestMethod -MockWith {
                $script:Attempt++
                if ($script:Attempt -lt 3) {
                    throw 'Response status code does not indicate success: 429 (Too Many Requests).'
                }
                [pscustomobject]@{ value = @([pscustomobject]@{ ok = $true }) }
            }
            $rows = @(Invoke-MsecGraphRequest -Path '/v1.0/things' -All)
            # Two waits for two throttles - it must actually back off, not hot-loop.
            Should -Invoke Start-Sleep -Times 2 -Exactly
            [pscustomobject]@{ Attempts = $script:Attempt; Rows = $rows }
        }

        $result.Attempts   | Should -Be 3
        $result.Rows.Count | Should -Be 1
    }

    It 'does not retry a 403 - retrying cannot help and would only delay the message' {
        $result = InModuleScope msec {
            Mock Start-Sleep -MockWith { }
            $script:Tries = 0
            Mock Invoke-RestMethod -MockWith {
                $script:Tries++
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }
            $threw = $false
            try { Invoke-MsecGraphRequest -Path '/v1.0/things' -All } catch { $threw = $true }
            [pscustomobject]@{ Tries = $script:Tries; Threw = $threw }
        }

        $result.Threw | Should -BeTrue
        $result.Tries | Should -Be 1
    }
}
