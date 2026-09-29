#Requires -Module Pester
#
# Tests for Set-MsecDefenderIncident. The guards are the same family as Set-MsecDefenderAlert's,
# plus two that are specific to incidents:
#
#   -CustomTags REPLACES the tag array. Graph has no append for a collection property, so the
#   command must say so before dropping existing tags rather than after.
#
#   'redirected' must not be settable. Defender assigns it when it merges an incident into
#   another; offering it as a status would imply this command can merge incidents, which it
#   cannot.
#
# And the reason this command exists at all: the resolution comment lives on the incident,
# because Graph has no writable comment on an alert.

BeforeAll {
    $script:StubbedGraphCommands = @()
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop

    # Microsoft.Graph.Authentication is NOT a dependency of msec - only Connect-MsecAdmin needs
    # it, and it checks at run time. It is preinstalled on the Windows and Ubuntu GitHub images
    # but NOT on the macOS one, so these tests passed on two runners and failed on the third:
    # Pester's Mock requires the command to EXIST, and a missing one fails as "Could not find
    # Command Get-MgContext" rather than as anything pointing at the real cause.
    #
    # Stubbed only when absent, so a machine that has the real module still mocks the real
    # command and the two behave identically.
    # The stubs carry the REAL parameter names, not an empty param(). A -ParameterFilter is
    # evaluated against the mocked command's own signature, so a stub without -TenantId leaves
    # $TenantId unbound and the filter silently matches nothing - the mock is invoked, the
    # assertion counts zero calls, and the failure looks like the command was never called.
    $graphStubs = @{
        'Get-MgContext'      = { [CmdletBinding()] param() }
        'Disconnect-MgGraph' = { [CmdletBinding()] param() }
        'Connect-MgGraph'    = {
            [CmdletBinding()]
            param(
                [string[]] $Scopes,
                [string]   $TenantId,
                [switch]   $NoWelcome,
                           $AccessToken,
                [string]   $Environment
            )
        }
    }
    foreach ($graphCmd in $graphStubs.Keys) {
        if (-not (Get-Command $graphCmd -ErrorAction SilentlyContinue)) {
            Set-Item "function:global:$graphCmd" -Value $graphStubs[$graphCmd] -Force
            $script:StubbedGraphCommands += $graphCmd
        }
    }

    function New-AdminSession {
        [PSCustomObject]@{
            Account = 'me@contoso.com'; TenantId = 't'
            GrantedScope = @('SecurityIncident.ReadWrite.All')
        }
    }
}
AfterAll {
    foreach ($graphCmd in $script:StubbedGraphCommands) {
        Remove-Item "function:global:$graphCmd" -ErrorAction SilentlyContinue
    } Remove-Module msec -Force -ErrorAction SilentlyContinue }

Describe 'Set-MsecDefenderIncident' {

    It 'refuses when only the read-only app session exists' {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            $script:MsecAdminSession = $null

            { Set-MsecDefenderIncident -Id '1' -Status resolved -Confirm:$false } |
                Should -Throw '*Connect-MsecAdmin*'
        }
    }

    It 'writes every incident piped in - there is no cap' {
        InModuleScope msec {
            $script:MsecAdminSession = [PSCustomObject]@{
                Account = 'me@contoso.com'; TenantId = 't'
                GrantedScope = @('SecurityIncident.ReadWrite.All')
            }
            Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me'; TenantId = 't' } }
            Mock Start-Sleep -MockWith { }
            Mock Invoke-MsecAdminGraphRequest -MockWith { @{ id = '1'; status = 'resolved' } }

            $rows = @(1..40 | Set-MsecDefenderIncident -Status resolved -Confirm:$false)

            $rows.Count | Should -Be 40
        }
    }

    It 'sends the resolving comment as resolvingComment' {
        $sent = InModuleScope msec {
            $script:MsecAdminSession = [PSCustomObject]@{
                Account = 'me@contoso.com'; TenantId = 't'
                GrantedScope = @('SecurityIncident.ReadWrite.All')
            }
            Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
            $script:captured = $null
            Mock Invoke-MsecAdminGraphRequest -MockWith {
                if ($Method -eq 'PATCH') { $script:captured = $Body }
                @{ id = '1'; displayName = 'D'; severity = 'low'; status = 'resolved'
                   resolvingComment = 'Authorised pen test' }
            }

            $null = '1' | Set-MsecDefenderIncident -Status resolved `
                -ResolvingComment 'Authorised pen test' -Confirm:$false
            $script:captured
        }

        $sent['resolvingComment'] | Should -Be 'Authorised pen test'
        $sent['status']           | Should -Be 'resolved'
    }

    It 'reports the comment that came back on re-read' {
        $row = InModuleScope msec {
            $script:MsecAdminSession = [PSCustomObject]@{
                Account = 'me@contoso.com'; TenantId = 't'
                GrantedScope = @('SecurityIncident.ReadWrite.All')
            }
            Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
            $script:n = 0
            Mock Invoke-MsecAdminGraphRequest -MockWith {
                $script:n++
                if ($script:n -eq 1) { @{ id = '1'; displayName = 'D'; severity = 'high'; status = 'active' } }
                else { @{ id = '1'; displayName = 'D'; severity = 'high'; status = 'resolved'
                          resolvingComment = 'Closed - benign' } }
            }

            '1' | Set-MsecDefenderIncident -Status resolved -ResolvingComment 'Closed - benign' -Confirm:$false
        }

        $row.StatusBefore          | Should -Be 'active'
        $row.StatusAfter           | Should -Be 'resolved'
        $row.ResolvingCommentAfter | Should -Be 'Closed - benign'
        $row.Changed               | Should -BeTrue
    }

    It 'warns before -CustomTags drops the tags already on the incident' {
        $warnings = InModuleScope msec {
            $script:MsecAdminSession = [PSCustomObject]@{
                Account = 'me@contoso.com'; TenantId = 't'
                GrantedScope = @('SecurityIncident.ReadWrite.All')
            }
            Mock Get-MgContext -MockWith { [PSCustomObject]@{ Account = 'me'; TenantId = 't' } }
                Mock Start-Sleep -MockWith { }
            Mock Invoke-MsecAdminGraphRequest -MockWith {
                @{ id = '1'; displayName = 'D'; severity = 'low'; status = 'active'
                   customTags = @('KeepMe', 'AndMe') }
            }

            $null = '1' | Set-MsecDefenderIncident -CustomTags 'Replacement' -Confirm:$false `
                -WarningVariable w -WarningAction SilentlyContinue
            $w
        }

        ($warnings -join ' ') | Should -Match 'replaces rather than appends'
        ($warnings -join ' ') | Should -Match 'KeepMe'
    }

    It 'does not offer redirected as a settable status' {
        $values = (Get-Command Set-MsecDefenderIncident).Parameters['Status'].Attributes.
                    Where({ $_ -is [ValidateSet] }).ValidValues
        $values | Should -Not -Contain 'redirected'
        $values | Should -Contain 'resolved'
        $values | Should -Contain 'active'
    }

    It 'offers the statuses that are in $metadata but missing from the docs' {
        $values = (Get-Command Set-MsecDefenderIncident).Parameters['Status'].Attributes.
                    Where({ $_ -is [ValidateSet] }).ValidValues
        $values | Should -Contain 'inProgress'
        $values | Should -Contain 'awaitingAction'
    }

    It 'is the only place a note can be written - alerts have no comment at all' {
        # Graph has no writable comment on an alert. Set-MsecDefenderAlert briefly had a -Comment
        # that routed to the Defender for Endpoint API, which covered 29 of 569 alerts on the
        # measured tenant and put a second user identity inside one command. It was removed, so
        # resolvingComment on the incident is now the single route for a resolution note.
        (Get-Command Set-MsecDefenderIncident).Parameters.Keys | Should -Contain 'ResolvingComment'
        (Get-Command Set-MsecDefenderAlert).Parameters.Keys    | Should -Not -Contain 'Comment'
        (Get-Command Set-MsecDefenderAlert).Parameters.Keys    | Should -Not -Contain 'ResolvingComment'
    }
}
