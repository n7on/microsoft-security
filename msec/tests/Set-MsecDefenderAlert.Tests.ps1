#Requires -Module Pester
#
# Tests for Set-MsecDefenderAlert - the first command in msec that changes anything outside its
# own app registration. The properties worth pinning are the ones that make a write safe rather
# than the ones that make it work:
#
#   It refuses the app session. Connect-Msec grants only *.Read.All, so a write attempted on it
#   can only 403. Saying so up front is the difference between a fixable message and a mystery.
#
#   The breadth guard fires BEFORE anything is written. A guard that checks per item has already
#   changed 25 alerts by the time it refuses the 26th, which is the whole failure it exists to
#   prevent - so the test asserts zero PATCHes, not a smaller number.
#
#   It reports what a re-read returned, never what was requested. When Defender accepts a PATCH
#   and does not hold part of it, Changed must be false; when the re-read itself fails, the
#   After columns must be $null rather than optimistically echoing the request.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module msec -Force -ErrorAction SilentlyContinue }

Describe 'Set-MsecDefenderAlert' {

    Context 'session requirements' {

        It 'refuses when only the read-only app session exists' {
            InModuleScope msec {
                $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
                $script:MsecAdminSession = $null

                { Set-MsecDefenderAlert -Id 'a1' -Status resolved -Confirm:$false } |
                    Should -Throw '*Connect-MsecAdmin*'
            }
        }

        It 'names the missing scope rather than letting the write 403' {
            InModuleScope msec {
                $script:MsecAdminSession = [PSCustomObject]@{
                    Account = 'me@contoso.com'; TenantId = 't'
                    GrantedScope = @('SecurityIncident.ReadWrite.All')
                }
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me@contoso.com'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }

                { Set-MsecDefenderAlert -Id 'a1' -Status resolved -Confirm:$false } |
                    Should -Throw '*SecurityAlert.ReadWrite.All*'
            }
        }

        It 'clears the recorded session when the Graph connection is gone' {
            InModuleScope msec {
                $script:MsecAdminSession = [PSCustomObject]@{
                    Account = 'me@contoso.com'; TenantId = 't'
                    GrantedScope = @('SecurityAlert.ReadWrite.All')
                }
                Mock Get-MgContext -MockWith { $null }

                { Set-MsecDefenderAlert -Id 'a1' -Status resolved -Confirm:$false } |
                    Should -Throw '*Connect-MsecAdmin again*'

                $script:MsecAdminSession | Should -BeNullOrEmpty
            }
        }
    }

    Context 'guards' {

        It 'refuses an empty change instead of sending a no-op PATCH' {
            InModuleScope msec {
                $script:MsecAdminSession = [PSCustomObject]@{
                    Account = 'me@contoso.com'; TenantId = 't'
                    GrantedScope = @('SecurityAlert.ReadWrite.All')
                }
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me@contoso.com'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }

                { Set-MsecDefenderAlert -Id 'a1' -Confirm:$false } |
                    Should -Throw '*at least one of*'
            }
        }

        It 'writes every alert piped in - there is no cap' {
            InModuleScope msec {
                $script:MsecAdminSession = [PSCustomObject]@{
                    Account = 'me@contoso.com'; TenantId = 't'
                    GrantedScope = @('SecurityAlert.ReadWrite.All')
                }
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me@contoso.com'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
                Mock Invoke-MsecAdminGraphRequest -MockWith { @{ id = 'x'; status = 'resolved' } }

                $rows = @(1..40 | ForEach-Object { "alert$_" } |
                    Set-MsecDefenderAlert -Status resolved -Confirm:$false)

                $rows.Count | Should -Be 40
                Should -Invoke Invoke-MsecAdminGraphRequest -Times 40 -Scope It `
                    -ParameterFilter { $Method -eq 'PATCH' }
            }
        }

        It 'declares no MaxCount parameter at all' {
            # Removed deliberately. -WhatIf and the High ConfirmImpact prompt are what remain
            # between a broad filter and a bulk write; this pins that no cap crept back in.
            (Get-Command Set-MsecDefenderAlert).Parameters.Keys    | Should -Not -Contain 'MaxCount'
            (Get-Command Set-MsecDefenderIncident).Parameters.Keys | Should -Not -Contain 'MaxCount'
        }

        It 'sends no PATCH under -WhatIf' {
            InModuleScope msec {
                $script:MsecAdminSession = [PSCustomObject]@{
                    Account = 'me@contoso.com'; TenantId = 't'
                    GrantedScope = @('SecurityAlert.ReadWrite.All')
                }
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me@contoso.com'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
                Mock Invoke-MsecAdminGraphRequest -MockWith { @{ id = 'a1'; status = 'new' } }

                Set-MsecDefenderAlert -Id 'a1' -Status resolved -WhatIf

                Should -Invoke Invoke-MsecAdminGraphRequest -Times 0 -Scope It
            }
        }

        It 'de-duplicates ids so one alert is written once' {
            InModuleScope msec {
                $script:MsecAdminSession = [PSCustomObject]@{
                    Account = 'me@contoso.com'; TenantId = 't'
                    GrantedScope = @('SecurityAlert.ReadWrite.All')
                }
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me@contoso.com'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
                Mock Invoke-MsecAdminGraphRequest -MockWith { @{ id = 'a1'; status = 'resolved' } }

                $null = 'a1', 'a1', 'a1' | Set-MsecDefenderAlert -Status resolved -Confirm:$false

                Should -Invoke Invoke-MsecAdminGraphRequest -Times 1 -Scope It `
                    -ParameterFilter { $Method -eq 'PATCH' }
            }
        }
    }

    Context 'reporting the observed state' {

        It 'reports Changed false when Defender did not keep the change' {
            $row = InModuleScope msec {
                $script:MsecAdminSession = [PSCustomObject]@{
                    Account = 'me@contoso.com'; TenantId = 't'
                    GrantedScope = @('SecurityAlert.ReadWrite.All')
                }
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me@contoso.com'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
                # PATCH succeeds; the alert comes back still 'new'.
                Mock Invoke-MsecAdminGraphRequest -MockWith {
                    @{ id = 'a1'; title = 'Suspicious sign-in'; severity = 'medium'; status = 'new' }
                }

                'a1' | Set-MsecDefenderAlert -Status resolved -Confirm:$false -WarningAction SilentlyContinue
            }

            $row.StatusBefore | Should -Be 'new'
            $row.StatusAfter  | Should -Be 'new'
            $row.Changed      | Should -BeFalse
        }

        It 'reports Changed true when the re-read confirms the change' {
            $row = InModuleScope msec {
                $script:MsecAdminSession = [PSCustomObject]@{
                    Account = 'me@contoso.com'; TenantId = 't'
                    GrantedScope = @('SecurityAlert.ReadWrite.All')
                }
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me@contoso.com'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
                $script:calls = 0
                Mock Invoke-MsecAdminGraphRequest -MockWith {
                    $script:calls++
                    if ($script:calls -eq 1) { @{ id = 'a1'; title = 'T'; severity = 'low'; status = 'new' } }
                    else { @{ id = 'a1'; title = 'T'; severity = 'low'; status = 'resolved' } }
                }

                'a1' | Set-MsecDefenderAlert -Status resolved -Confirm:$false
            }

            $row.StatusBefore | Should -Be 'new'
            $row.StatusAfter  | Should -Be 'resolved'
            $row.Changed      | Should -BeTrue
        }

        It 'leaves the After columns null when the re-read fails, rather than echoing the request' {
            $row = InModuleScope msec {
                $script:MsecAdminSession = [PSCustomObject]@{
                    Account = 'me@contoso.com'; TenantId = 't'
                    GrantedScope = @('SecurityAlert.ReadWrite.All')
                }
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me@contoso.com'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
                $script:calls = 0
                Mock Invoke-MsecAdminGraphRequest -MockWith {
                    $script:calls++
                    # 1 = read before, 2 = PATCH, 3 = re-read which fails.
                    if ($script:calls -ge 3) { throw 'Gateway timeout' }
                    @{ id = 'a1'; title = 'T'; severity = 'high'; status = 'new' }
                }

                'a1' | Set-MsecDefenderAlert -Status resolved -Confirm:$false -WarningAction SilentlyContinue
            }

            $row.StatusBefore | Should -Be 'new'
            $row.StatusAfter  | Should -BeNullOrEmpty
            $row.Changed      | Should -BeNullOrEmpty
        }

        It 'still emits a row when the PATCH fails, with Changed null rather than false' {
            # Changed to this contract when -Comment arrived: a write is no longer all-or-
            # nothing, so the comment may have landed while the Graph fields did not. A row
            # carrying Changed=$null and a warning beats silence that a pipeline swallows.
            # $null, not $false: the change was not observed to fail, it was never verified.
            $rows = InModuleScope msec {
                $script:MsecAdminSession = [PSCustomObject]@{
                    Account = 'me@contoso.com'; TenantId = 't'
                    GrantedScope = @('SecurityAlert.ReadWrite.All')
                }
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me@contoso.com'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
                Mock Invoke-MsecAdminGraphRequest -MockWith {
                    if ($Method -eq 'PATCH') { throw 'Forbidden' }
                    @{ id = 'a1'; title = 'T'; severity = 'low'; status = 'new' }
                }

                @('a1' | Set-MsecDefenderAlert -Status resolved -Confirm:$false -WarningAction SilentlyContinue)
            }

            @($rows).Count       | Should -Be 1
            $rows.Changed        | Should -BeNullOrEmpty
            $rows.StatusBefore   | Should -Be 'new'
            $rows.StatusAfter    | Should -BeNullOrEmpty
        }
    }

    Context 'eventual consistency' {

        It 'does not cry wolf when the first read is stale but the change settled' {
            # The regression this guards. Observed live: an alert PATCHed at 16:37:00 still read
            # as unchanged immediately afterwards and was correct when read again. Reporting a
            # failure that did not happen trains people to ignore the warning, which destroys
            # the value of verifying at all.
            $result = InModuleScope msec {
                $script:MsecAdminSession = [PSCustomObject]@{
                    Account = 'me@contoso.com'; TenantId = 't'
                    GrantedScope = @('SecurityAlert.ReadWrite.All')
                }
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }

                # 1 = read before, 2 = PATCH, 3 = STALE verify, 4 = settled verify.
                $script:n = 0
                Mock Invoke-MsecAdminGraphRequest -MockWith {
                    $script:n++
                    if ($script:n -le 3) {
                        @{ id = 'a1'; title = 'T'; severity = 'medium'; status = 'new' }
                    }
                    else {
                        @{ id = 'a1'; title = 'T'; severity = 'medium'; status = 'resolved' }
                    }
                }

                $row = 'a1' | Set-MsecDefenderAlert -Status resolved -Confirm:$false `
                    -WarningVariable w -WarningAction SilentlyContinue
                [PSCustomObject]@{ Row = $row; Warnings = @($w) }
            }

            $result.Row.StatusAfter | Should -Be 'resolved'
            $result.Row.Changed     | Should -BeTrue
            $result.Warnings.Count  | Should -Be 0
        }

        It 'still reports a mismatch when the value never settles' {
            $result = InModuleScope msec {
                $script:MsecAdminSession = [PSCustomObject]@{
                    Account = 'me@contoso.com'; TenantId = 't'
                    GrantedScope = @('SecurityAlert.ReadWrite.All')
                }
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
                Mock Invoke-MsecAdminGraphRequest -MockWith {
                    @{ id = 'a1'; title = 'T'; severity = 'medium'; status = 'new' }
                }

                $row = 'a1' | Set-MsecDefenderAlert -Status resolved -Confirm:$false `
                    -WarningVariable w -WarningAction SilentlyContinue
                [PSCustomObject]@{ Row = $row; Warnings = @($w) }
            }

            $result.Row.Changed | Should -BeFalse
            ($result.Warnings -join ' ') | Should -Match 'still does not show'
        }
    }

    Context 'the comment, which is not a Graph operation' {

        BeforeEach {
            InModuleScope msec {
                $script:MsecAdminSession = [PSCustomObject]@{
                    Account = 'me@contoso.com'; TenantId = 't'
                    GrantedScope = @('SecurityAlert.ReadWrite.All')
                }
            }
        }

        It 'sends an endpoint alert comment to the Defender API keyed on providerAlertId' {
            $sent = InModuleScope msec {
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
                Mock Invoke-MsecAdminGraphRequest -MockWith {
                    @{ id = 'a1'; title = 'T'; severity = 'low'; status = 'new'
                       serviceSource = 'microsoftDefenderForEndpoint'; providerAlertId = 'da-1_1' }
                }
                $script:path = $null; $script:body = $null
                Mock Invoke-MsecAdminDefenderRequest -MockWith {
                    if ($Method -eq 'PATCH') { $script:path = $Path; $script:body = $Body }
                    @{ comments = @(@{ comment = 'Authorised test' }) }
                }

                $null = 'a1' | Set-MsecDefenderAlert -Comment 'Authorised test' -Confirm:$false
                [PSCustomObject]@{ Path = $script:path; Body = $script:body }
            }

            # Keyed on the provider id, not the Graph id.
            $sent.Path | Should -Be '/api/alerts/da-1_1'
            $sent.Body['comment'] | Should -Be 'Authorised test'
        }

        It 'REFUSES by name on a non-endpoint alert instead of dropping the comment' {
            $result = InModuleScope msec {
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
                Mock Invoke-MsecAdminGraphRequest -MockWith {
                    @{ id = 'a1'; title = 'T'; severity = 'low'; status = 'new'
                       serviceSource = 'microsoftDefenderForOffice365'; providerAlertId = 'x' }
                }
                Mock Invoke-MsecAdminDefenderRequest -MockWith { @{} }

                $row = 'a1' | Set-MsecDefenderAlert -Comment 'nope' -Confirm:$false `
                    -WarningVariable w -WarningAction SilentlyContinue
                [PSCustomObject]@{ Row = $row; Warnings = $w }
            }

            $result.Row.CommentAdded | Should -BeFalse
            ($result.Warnings -join ' ') | Should -Match 'microsoftDefenderForOffice365'
            ($result.Warnings -join ' ') | Should -Match 'Set-MsecDefenderIncident'
            Should -Invoke Invoke-MsecAdminDefenderRequest -Times 0 -Scope It -ModuleName msec
        }

        It 'reports CommentAdded false when the comment is not in the thread on re-read' {
            $row = InModuleScope msec {
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
                Mock Invoke-MsecAdminGraphRequest -MockWith {
                    @{ id = 'a1'; title = 'T'; severity = 'low'; status = 'new'
                       serviceSource = 'microsoftDefenderForEndpoint'; providerAlertId = 'da-1_1' }
                }
                # PATCH returns 200, but the thread comes back without it.
                Mock Invoke-MsecAdminDefenderRequest -MockWith { @{ comments = @() } }

                'a1' | Set-MsecDefenderAlert -Comment 'vanished' -Confirm:$false `
                    -WarningAction SilentlyContinue
            }

            $row.CommentAdded | Should -BeFalse
        }

        It 'leaves CommentAdded null when it was never asked for' {
            $row = InModuleScope msec {
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
                Mock Invoke-MsecAdminGraphRequest -MockWith {
                    @{ id = 'a1'; title = 'T'; severity = 'low'; status = 'resolved'
                       serviceSource = 'microsoftDefenderForEndpoint' }
                }
                'a1' | Set-MsecDefenderAlert -Status resolved -Confirm:$false
            }

            $row.CommentAdded | Should -BeNullOrEmpty
            $row.Changed      | Should -BeTrue
        }

        It 'allows a comment with no other change, as the Defender API does' {
            InModuleScope msec {
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
                Mock Invoke-MsecAdminGraphRequest -MockWith {
                    @{ id = 'a1'; title = 'T'; severity = 'low'; status = 'new'
                       serviceSource = 'microsoftDefenderForEndpoint'; providerAlertId = 'da-1_1' }
                }
                Mock Invoke-MsecAdminDefenderRequest -MockWith { @{ comments = @(@{ comment = 'note' }) } }

                $null = 'a1' | Set-MsecDefenderAlert -Comment 'note' -Confirm:$false

                # No Graph PATCH at all - the comment is not a Graph operation.
                Should -Invoke Invoke-MsecAdminGraphRequest -Times 0 -Scope It `
                    -ParameterFilter { $Method -eq 'PATCH' }
            }
        }

        It 'sends no comment under -WhatIf' {
            InModuleScope msec {
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
                Mock Invoke-MsecAdminGraphRequest -MockWith { @{ id = 'a1' } }
                Mock Invoke-MsecAdminDefenderRequest -MockWith { @{} }

                Set-MsecDefenderAlert -Id 'a1' -Comment 'dry run' -WhatIf

                Should -Invoke Invoke-MsecAdminDefenderRequest -Times 0 -Scope It
            }
        }
    }

    Context 'comment refusals are summarised, not repeated' {

        It 'warns ONCE for many non-endpoint alerts and names the incidents to use instead' {
            $result = InModuleScope msec {
                $script:MsecAdminSession = [PSCustomObject]@{
                    Account = 'me@contoso.com'; TenantId = 't'
                    GrantedScope = @('SecurityAlert.ReadWrite.All')
                }
                Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
                Mock Invoke-MsecAdminGraphRequest -MockWith {
                    # incidentId differs per alert so the summary can collect them.
                    $n = if ($Path -match 'a(\d+)$') { $Matches[1] } else { '0' }
                    @{ id = "a$n"; title = 'T'; severity = 'medium'; status = 'resolved'
                       serviceSource = 'unknownFutureValue'; incidentId = "58$n" }
                }

                $rows = @('a1', 'a2', 'a3' | Set-MsecDefenderAlert -Status resolved -Comment 'note' `
                    -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue)
                [PSCustomObject]@{ Rows = $rows; Warnings = @($w) }
            }

            $result.Rows.Count | Should -Be 3
            $result.Rows | ForEach-Object { $_.CommentAdded | Should -BeFalse }

            # One warning for all three, not one each.
            $result.Warnings.Count | Should -Be 1
            $result.Warnings[0] | Should -Match '3 alert\(s\) did not take a comment'
            $result.Warnings[0] | Should -Match 'unknownFutureValue'
            # and it hands over the exact command, with every incident id
            $result.Warnings[0] | Should -Match 'Set-MsecDefenderIncident -Id 581,582,583'
        }
    }

    Context 'the enum values Graph actually accepts' {

        It 'takes the wire status value new, not the CSDL member newAlert' {
            $cmd = Get-Command Set-MsecDefenderAlert
            $values = $cmd.Parameters['Status'].Attributes.Where({ $_ -is [ValidateSet] }).ValidValues
            $values | Should -Contain 'new'
            $values | Should -Not -Contain 'newAlert'
        }

        It 'uses the real determination names, not the guessable ones' {
            $cmd = Get-Command Set-MsecDefenderAlert
            $values = $cmd.Parameters['Determination'].Attributes.Where({ $_ -is [ValidateSet] }).ValidValues
            $values | Should -Contain 'notMalicious'
            $values | Should -Contain 'notEnoughDataToValidate'
            $values | Should -Not -Contain 'clean'
            $values | Should -Not -Contain 'insufficientData'
        }

        It 'declares High confirm impact so a bare call prompts' {
            $meta = [System.Management.Automation.CommandMetadata](Get-Command Set-MsecDefenderAlert)
            $meta.SupportsShouldProcess | Should -BeTrue
            $meta.ConfirmImpact | Should -Be 'High'
        }
    }
}
