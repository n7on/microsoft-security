#Requires -Module Pester
#
# Tests for Get-MsecAzureCost.
#
# Three things here are easy to get wrong, and all three were found against the live API:
#
#   * Cost Management THROTTLES hard, and the natural use - a loop over every resource group -
#     is exactly the shape that trips it. Losing a scope silently makes the total too low,
#     which is the worst way for a cost report to be wrong: it still looks like a total.
#   * the response carries a CURRENCY, and dropping it is how a report adds SEK to EUR.
#   * column ORDER is not contractual, so reading rows[0][0] as the cost works right up until
#     the API reorders and it starts returning a currency code as a number.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:Ok = {
        param($Cost, $Currency = 'SEK', $Columns = @('PreTaxCost', 'Currency'))
        $row = if ($Columns[0] -eq 'PreTaxCost') { @($Cost, $Currency) } else { @($Currency, $Cost) }
        [pscustomobject]@{
            StatusCode = 200
            Content = (@{ properties = @{ columns = @($Columns | ForEach-Object { @{ name = $_ } }); rows = @(, $row) } } | ConvertTo-Json -Depth 10)
        }
    }
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureCost' {

    BeforeEach {
        InModuleScope Msec {
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-1' } }
            }
        }
    }

    It 'returns the cost with its currency, unrounded' {
        $row = InModuleScope Msec -Parameters @{ Ok = $script:Ok } {
            param($Ok)
            Mock Invoke-AzRestMethod -MockWith { & $Ok 3796.3584217 'SEK' }
            Get-MsecAzureCost
        }

        # Not rounded: the collector must not lose the difference between 0.4 and 0, because
        # the second reads as free.
        $row.Cost     | Should -Be 3796.3584217
        $row.Currency | Should -Be 'SEK'
        $row.Scope    | Should -Be 'sub-1'
    }

    It 'reads the columns by name, not by position' {
        $row = InModuleScope Msec -Parameters @{ Ok = $script:Ok } {
            param($Ok)
            # The same answer with the columns the other way round. Reading rows[0][0] would
            # return 'SEK' as the cost.
            Mock Invoke-AzRestMethod -MockWith { & $Ok 1234.5 'EUR' @('Currency', 'PreTaxCost') }
            Get-MsecAzureCost
        }

        $row.Cost     | Should -Be 1234.5
        $row.Currency | Should -Be 'EUR'
    }

    It 'retries a throttled scope, then reports it as missing rather than as zero' {
        $rows = InModuleScope Msec -Parameters @{ Ok = $script:Ok } {
            param($Ok)
            $script:Calls = 0
            Mock Start-Sleep -MockWith { }
            Mock Invoke-AzRestMethod -MockWith {
                $script:Calls++
                # Throttled twice, then answers - the ordinary case under a resource-group loop.
                if ($script:Calls -le 2) { [pscustomobject]@{ StatusCode = 429; Content = '{}'; Headers = @() } }
                else { & $Ok 99.5 'SEK' }
            }
            $result = Get-MsecAzureCost
            $result
        }

        @($rows).Count | Should -Be 1
        $rows.Cost     | Should -Be 99.5
    }

    It 'warns loudly when a scope is lost to throttling, because the total goes short' {
        $warnings = @()
        $rows = InModuleScope Msec {
            Mock Start-Sleep -MockWith { }
            Mock Invoke-AzRestMethod -MockWith { [pscustomobject]@{ StatusCode = 429; Content = '{}'; Headers = @() } }
            Get-MsecAzureCost -ResourceGroupName 'rg-busy'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        # No row at all - a fabricated 0 would silently understate the estate's spend.
        @($rows).Count | Should -Be 0
        ($warnings -join ' ') | Should -Match 'contributes NO row'
        ($warnings -join ' ') | Should -Match 'short by its cost'
    }

    It 'warns when a run spans two billing currencies' {
        $warnings = @()
        InModuleScope Msec -Parameters @{ Ok = $script:Ok } {
            param($Ok)
            $script:N = 0
            Mock Invoke-AzRestMethod -MockWith {
                $script:N++
                if ($script:N -eq 1) { & $Ok 100 'SEK' } else { & $Ok 200 'EUR' }
            }
            Get-MsecAzureCost -ResourceGroupName 'rg-se', 'rg-de'
        } -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

        # Adding SEK to EUR produces a number that means nothing, and nothing downstream can
        # tell it happened unless this says so.
        ($warnings -join ' ') | Should -Match 'billing currencies'
        ($warnings -join ' ') | Should -Match 'Do NOT sum'
    }

    It 'names Cost Management Reader on a denial' {
        $warnings = @()
        InModuleScope Msec {
            Mock Invoke-AzRestMethod -MockWith { [pscustomobject]@{ StatusCode = 403; Content = 'denied' } }
            Get-MsecAzureCost
        } -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

        # Reader on the subscription is NOT enough for this API, and the message must say so
        # or the reader checks access that is already correct.
        ($warnings -join ' ') | Should -Match 'Cost Management Reader'
        ($warnings -join ' ') | Should -Match 'not sufficient'
    }

    It 'treats a scope with no charges as zero, not as a failure' {
        $row = InModuleScope Msec {
            # An empty resource group genuinely costs nothing.
            Mock Invoke-AzRestMethod -MockWith {
                [pscustomobject]@{ StatusCode = 200
                    Content = (@{ properties = @{ columns = @(@{ name = 'PreTaxCost' }, @{ name = 'Currency' }); rows = @() } } | ConvertTo-Json -Depth 10) }
            }
            Get-MsecAzureCost -ResourceGroupName 'rg-empty'
        }

        $row.Cost              | Should -Be 0
        $row.ResourceGroupName | Should -Be 'rg-empty'
    }

    It 'throws a clear error without an Az context' {
        InModuleScope Msec {
            Mock Get-AzContext -MockWith { $null }
            { Get-MsecAzureCost } | Should -Throw '*Connect-AzAccount*'
        }
    }
}
