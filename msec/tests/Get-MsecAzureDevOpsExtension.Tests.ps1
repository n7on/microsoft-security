#Requires -Module Pester
#
# Tests for Get-MsecAzureDevOpsExtension.
#
# The shape below was captured from a live organization: publisherId/publisherName, a scopes
# array of vso.* strings, and installState.flags as a comma-separated string.
#
# What matters here is that the Access grouping is a CONVENIENCE and the scope list is the fact.
# A reader who disagrees with the grouping must still be able to see what was granted, so Scopes
# is always returned and a scope this command has never seen must not disappear.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureDevOpsExtension' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }

            function script:New-Extension {
                param(
                    [string] $Name = 'Thing', [string] $Publisher = 'Contoso',
                    [string] $PublisherId = 'contoso', [string[]] $Scopes = @(), [string] $Flags = 'none'
                )
                [pscustomobject]@{
                    extensionId = $Name.ToLower(); extensionName = $Name
                    publisherId = $PublisherId; publisherName = $Publisher
                    version = '1.0.0'; lastPublished = [datetime]'2026-01-10'
                    scopes = $Scopes
                    installState = [pscustomobject]@{ flags = $Flags }
                }
            }

            function script:Set-ExtMock {
                param($Extensions)
                Mock Invoke-MsecAzureDevOpsRequest -MockWith { $Extensions }
            }
        }
    }

    It 'ranks manage above write above read' {
        $rows = InModuleScope msec {
            . Set-ExtMock -Extensions @(
                (New-Extension -Name 'Manages'  -Scopes @('vso.build', 'vso.serviceendpoint_manage'))
                (New-Extension -Name 'Writes'   -Scopes @('vso.build', 'vso.code_write'))
                (New-Extension -Name 'Executes' -Scopes @('vso.build_execute'))
                (New-Extension -Name 'Reads'    -Scopes @('vso.build', 'vso.code'))
                (New-Extension -Name 'Nothing'))
            Get-MsecAzureDevOpsExtension -Organization 'contoso'
        }

        # A manage scope alongside read scopes is still manage - the highest grant decides.
        ($rows | Where-Object ExtensionName -eq 'Manages').Access  | Should -Be 'Manage'
        ($rows | Where-Object ExtensionName -eq 'Writes').Access   | Should -Be 'Write'
        # _execute runs code, so it groups with write rather than read.
        ($rows | Where-Object ExtensionName -eq 'Executes').Access | Should -Be 'Write'
        ($rows | Where-Object ExtensionName -eq 'Reads').Access    | Should -Be 'Read'
        ($rows | Where-Object ExtensionName -eq 'Nothing').Access  | Should -Be 'None'
    }

    It 'always returns the raw scopes, whatever the grouping says' {
        $rows = InModuleScope msec {
            . Set-ExtMock -Extensions @(New-Extension -Name 'Odd' -Scopes @('vso.something_nobody_modelled', 'vso.code'))
            Get-MsecAzureDevOpsExtension -Organization 'contoso'
        }

        # The grouping is this command's judgement; the scope list is the fact, and a scope it
        # has never seen must survive into the output.
        $rows.Scopes | Should -Match 'vso.something_nobody_modelled'
        $rows.Access | Should -Be 'Read'
    }

    It 'identifies Microsoft publishers, including DevLabs' {
        $rows = InModuleScope msec {
            . Set-ExtMock -Extensions @(
                (New-Extension -Name 'First'  -Publisher 'Microsoft' -PublisherId 'ms')
                (New-Extension -Name 'Labs'   -Publisher 'Microsoft DevLabs' -PublisherId 'ms-devlabs')
                (New-Extension -Name 'Other'  -Publisher 'Amazon Web Services' -PublisherId 'AmazonWebServices'))
            Get-MsecAzureDevOpsExtension -Organization 'contoso'
        }

        ($rows | Where-Object ExtensionName -eq 'First').IsMicrosoftPublisher | Should -BeTrue
        # DevLabs is Microsoft-published but experimental - counted as Microsoft, and the
        # publisher name is left visible so the reader can weigh it.
        ($rows | Where-Object ExtensionName -eq 'Labs').IsMicrosoftPublisher  | Should -BeTrue
        ($rows | Where-Object ExtensionName -eq 'Other').IsMicrosoftPublisher | Should -BeFalse
    }

    It 'keeps a disabled extension, because its grants survive' {
        $rows = InModuleScope msec {
            . Set-ExtMock -Extensions @(New-Extension -Name 'Off' -Scopes @('vso.code_manage') -Flags 'disabled')
            Get-MsecAzureDevOpsExtension -Organization 'contoso'
        }

        # Disabling does not revoke the scopes, and re-enabling asks nobody to consent again.
        @($rows).Count   | Should -Be 1
        $rows.IsDisabled | Should -BeTrue
        $rows.Access     | Should -Be 'Manage'
    }

    It 'filters to third-party publishers when asked' {
        $rows = InModuleScope msec {
            . Set-ExtMock -Extensions @(
                (New-Extension -Name 'Ours'  -Publisher 'Microsoft' -PublisherId 'ms')
                (New-Extension -Name 'Theirs' -Publisher 'Qameta Software' -PublisherId 'qameta'))
            Get-MsecAzureDevOpsExtension -Organization 'contoso' -ThirdPartyOnly
        }

        @($rows).Count      | Should -Be 1
        $rows.ExtensionName | Should -Be 'Theirs'
    }

    It 'warns rather than returning nothing when the list is empty' {
        $warnings = @()
        $rows = InModuleScope msec {
            . Set-ExtMock -Extensions @()
            Get-MsecAzureDevOpsExtension -Organization 'contoso'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        # Every organization has built-in extensions, so an empty list means nothing was read.
        @($rows).Count | Should -Be 0
        ($warnings -join ' ') | Should -Match 'nothing was read'
    }

    It 'throws a clear error when not connected' {
        InModuleScope msec {
            $script:MsecSession = $null
            { Get-MsecAzureDevOpsExtension -Organization 'contoso' } | Should -Throw '*Connect-Msec*'
        }
    }
}
