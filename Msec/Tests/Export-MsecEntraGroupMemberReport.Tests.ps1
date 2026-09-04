#Requires -Module Pester
#
# Tests for Export-MsecEntraGroupMemberReport.
#
# What is specific here is the sheet-per-group shape and the Summary that compares them. The
# things easy to get wrong:
#
#   * two groups can share a DISPLAY NAME, so sheets must be keyed on the group id - merging
#     them would put two different groups' members on one sheet under one heading
#   * an empty group must still get a sheet and a summary row: "nobody is in it" is a finding
#     that disappears if empty groups are skipped
#   * a group whose membership could not be read must count as Unreadable, never as 0 members
#   * a worksheet called 'Summary' or 'Dashboard' belongs to the report, so a group with that
#     name must be suffixed rather than overwrite it

$script:HasExcel = $null -ne (Get-Module -ListAvailable ImportExcel)

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Export-MsecEntraGroupMemberReport' -Skip:(-not $script:HasExcel) {
    BeforeEach {
        InModuleScope Msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId = 'tenant-1'; ClientId = 'client'; KeyVaultName = 'kv'
                KeyName = 'msec-app'; ThumbprintBytes = $Thumb; Tokens = @{}
            }
        }
        $script:Book = Join-Path ([System.IO.Path]::GetTempPath()) "msec-gm-$([guid]::NewGuid().Guid).xlsx"
    }
    AfterEach {
        if ($script:Book -and (Test-Path $script:Book)) { Remove-Item $script:Book -Force -ErrorAction SilentlyContinue }
    }

    It 'writes a worksheet per group and one Summary row each' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecEntraGroupMember -MockWith {
                [pscustomobject]@{ GroupName='sg-admins'; GroupId='g1'; GroupType='Security'; IsRoleAssignable=$true
                                   MemberName='Ada'; MemberUserPrincipalName='ada@x.com'; MemberType='user'; MemberId='u1'
                                   MembershipType='Active'; AccountEnabled=$true; UserType='Member' }
                [pscustomobject]@{ GroupName='sg-admins'; GroupId='g1'; GroupType='Security'; IsRoleAssignable=$true
                                   MemberName='Eve'; MemberUserPrincipalName='eve@x.com'; MemberType='user'; MemberId='u2'
                                   MembershipType='Eligible'; AccountEnabled=$true; UserType='Member' }
                [pscustomobject]@{ GroupName='sg-devops'; GroupId='g2'; GroupType='Security'; IsRoleAssignable=$false
                                   MemberName='ci-runner'; MemberType='servicePrincipal'; MemberId='sp1'
                                   MembershipType='Active'; AccountEnabled=$true }
                [pscustomobject]@{ GroupName='sg-devops'; GroupId='g2'; GroupType='Security'; IsRoleAssignable=$false
                                   MemberName='Guest User'; MemberUserPrincipalName='g@x.com'; MemberType='user'; MemberId='u3'
                                   MembershipType='Active'; AccountEnabled=$false; UserType='Guest' }
            }
            Export-MsecEntraGroupMemberReport -Path $Book -Name 'sg-*' -WarningAction SilentlyContinue | Out-Null
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $names = @($package.Workbook.Worksheets | ForEach-Object { $_.Name })
            $names[0] | Should -Be 'Dashboard'      # in front of the data
            $names | Should -Contain 'sg-admins'
            $names | Should -Contain 'sg-devops'
            $names | Should -Contain 'Summary'
        }
        finally { Close-ExcelPackage $package -NoSave }

        @(Import-Excel -Path $script:Book -WorksheetName 'sg-admins').Count | Should -Be 2
        @(Import-Excel -Path $script:Book -WorksheetName 'sg-devops').Count | Should -Be 2

        $summary = @(Import-Excel -Path $script:Book -WorksheetName 'Summary')
        @($summary).Count | Should -Be 2

        $admins = $summary | Where-Object GroupName -eq 'sg-admins'
        $admins.Members  | Should -Be 2
        $admins.Active   | Should -Be 1
        # Standing versus PIM-eligible is the distinction the Summary exists to show.
        $admins.Eligible | Should -Be 1

        $devops = $summary | Where-Object GroupName -eq 'sg-devops'
        $devops.ServicePrincipals | Should -Be 1
        $devops.Guests            | Should -Be 1
        # Disabled and still in an access group: cannot sign in today, membership survives.
        $devops.Disabled          | Should -Be 1
    }

    It 'charts groups against each other, not membership types within one' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecEntraGroupMember -MockWith {
                [pscustomobject]@{ GroupName='sg-a'; GroupId='g1'; MemberName='Ada'; MemberType='user'; MemberId='u1'; MembershipType='Active'; AccountEnabled=$true }
                [pscustomobject]@{ GroupName='sg-b'; GroupId='g2'; MemberName='Bob'; MemberType='user'; MemberId='u2'; MembershipType='Active'; AccountEnabled=$true }
            }
            Export-MsecEntraGroupMemberReport -Path $Book -Name 'sg-*' -WarningAction SilentlyContinue | Out-Null
        }

        $package = Open-ExcelPackage -Path $script:Book
        try {
            $charts = @($package.Workbook.Worksheets['Dashboard'].Drawings)
            # ONE chart comparing groups, not one per group.
            @($charts).Count | Should -Be 1
            $charts[0].Name  | Should -Be 'chartGroupMembership'
            @($charts[0].Series | ForEach-Object { $_.Header }) |
                Should -Be @('Members', 'Eligible', 'Guests', 'ServicePrincipals', 'Disabled')
        }
        finally { Close-ExcelPackage $package -NoSave }
    }

    It 'keeps two groups that share a display name on separate sheets' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            # Entra display names are not unique. Keying sheets on the NAME would merge these.
            Mock Get-MsecEntraGroupMember -MockWith {
                [pscustomobject]@{ GroupName='sg-dup'; GroupId='g1'; MemberName='Ada'; MemberType='user'; MemberId='u1'; MembershipType='Active'; AccountEnabled=$true }
                [pscustomobject]@{ GroupName='sg-dup'; GroupId='g2'; MemberName='Bob'; MemberType='user'; MemberId='u2'; MembershipType='Active'; AccountEnabled=$true }
            }
            Export-MsecEntraGroupMemberReport -Path $Book -Name 'sg-dup' -WarningAction SilentlyContinue | Out-Null
        }

        $summary = @(Import-Excel -Path $script:Book -WorksheetName 'Summary')
        @($summary).Count | Should -Be 2
        # Two distinct worksheets, and the ids that tell them apart.
        @($summary | ForEach-Object { $_.Worksheet } | Select-Object -Unique).Count | Should -Be 2
        @($summary | ForEach-Object { $_.GroupId } | Sort-Object) | Should -Be @('g1', 'g2')
    }

    It 'gives an empty group a sheet, and marks an unreadable one as such' {
        $warnings = @()
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecEntraGroupMember -MockWith {
                # Get-MsecEntraGroupMember emits a placeholder row for each of these.
                [pscustomobject]@{ GroupName='sg-empty';  GroupId='g1'; MemberName=$null; MemberType='None';       MemberId=$null; MembershipType=$null }
                [pscustomobject]@{ GroupName='sg-denied'; GroupId='g2'; MemberName=$null; MemberType='Unreadable'; MemberId=$null; MembershipType=$null }
            }
            Export-MsecEntraGroupMemberReport -Path $Book -Name 'sg-*'
        } -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

        $summary = @(Import-Excel -Path $script:Book -WorksheetName 'Summary')
        @($summary).Count | Should -Be 2

        # "Nobody is in it" is a finding, and it disappears if empty groups are skipped.
        ($summary | Where-Object GroupName -eq 'sg-empty').Members | Should -Be 0
        # A group nobody could read must never be reported as a clean zero.
        ($summary | Where-Object GroupName -eq 'sg-denied').Members    | Should -Be 0
        ($summary | Where-Object GroupName -eq 'sg-denied').Unreadable | Should -Be $true
        ($summary | Where-Object GroupName -eq 'sg-empty').Unreadable  | Should -Be $false

        ($warnings -join ' ') | Should -Match 'Unreadable'
        ($warnings -join ' ') | Should -Match 'no members at all'
    }

    It 'does not let a group called Summary overwrite the report sheet' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecEntraGroupMember -MockWith {
                [pscustomobject]@{ GroupName='Summary'; GroupId='g1'; MemberName='Ada'; MemberType='user'; MemberId='u1'; MembershipType='Active'; AccountEnabled=$true }
            }
            Export-MsecEntraGroupMemberReport -Path $Book -Name 'Summary' -WarningAction SilentlyContinue | Out-Null
        }

        $rows = @(Import-Excel -Path $script:Book -WorksheetName 'Summary')
        # The Summary sheet is still the report's, with one row about the group.
        $rows[0].GroupName | Should -Be 'Summary'
        $rows[0].Members   | Should -Be 1
        # ...and the group's members went somewhere else.
        $rows[0].Worksheet | Should -Not -Be 'Summary'
        @(Import-Excel -Path $script:Book -WorksheetName $rows[0].Worksheet).Count | Should -Be 1
    }

    It 'asks once for the whole run, however many groups are in it' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecEntraGroupMember -MockWith {
                [pscustomobject]@{ GroupName='sg-a'; GroupId='g1'; MemberName='Ada';  MemberType='user'; MemberId='u1'; MembershipType='Active'; AccountEnabled=$true }
                [pscustomobject]@{ GroupName='sg-b'; GroupId='g2'; MemberName='Bob';  MemberType='user'; MemberId='u2'; MembershipType='Active'; AccountEnabled=$true }
                [pscustomobject]@{ GroupName='sg-c'; GroupId='g3'; MemberName='Cleo'; MemberType='user'; MemberId='u3'; MembershipType='Active'; AccountEnabled=$true }
            }
            Export-MsecEntraGroupMemberReport -Path $Book -Name 'sg-*' -WarningAction SilentlyContinue | Out-Null

            # Second run, declining. Three groups must be ONE question - forty prompts is a
            # prompt nobody reads.
            Mock Get-MsecEntraGroupMember -MockWith {
                [pscustomobject]@{ GroupName='sg-a'; GroupId='g1'; MemberName='Changed'; MemberType='user'; MemberId='u9'; MembershipType='Active'; AccountEnabled=$true }
                [pscustomobject]@{ GroupName='sg-b'; GroupId='g2'; MemberName='Changed'; MemberType='user'; MemberId='u9'; MembershipType='Active'; AccountEnabled=$true }
                [pscustomobject]@{ GroupName='sg-c'; GroupId='g3'; MemberName='Changed'; MemberType='user'; MemberId='u9'; MembershipType='Active'; AccountEnabled=$true }
            }
            Mock Confirm-MsecEvidenceOverwrite -MockWith { $false }

            Export-MsecEntraGroupMemberReport -Path $Book -Name 'sg-*' -WarningAction SilentlyContinue | Out-Null

            # Asked once for the whole run, not once per group.
            Should -Invoke Confirm-MsecEvidenceOverwrite -Times 1 -Exactly
        }

        # Declining left every sheet exactly as it was.
        (Import-Excel -Path $script:Book -WorksheetName 'sg-a')[0].MemberName | Should -Be 'Ada'
        (Import-Excel -Path $script:Book -WorksheetName 'sg-c')[0].MemberName | Should -Be 'Cleo'
    }

    It '-Force replaces without asking at all' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecEntraGroupMember -MockWith {
                [pscustomobject]@{ GroupName='sg-a'; GroupId='g1'; MemberName='Ada'; MemberType='user'; MemberId='u1'; MembershipType='Active'; AccountEnabled=$true }
            }
            Export-MsecEntraGroupMemberReport -Path $Book -Name 'sg-a' -WarningAction SilentlyContinue | Out-Null

            Mock Get-MsecEntraGroupMember -MockWith {
                [pscustomobject]@{ GroupName='sg-a'; GroupId='g1'; MemberName='Forced'; MemberType='user'; MemberId='u9'; MembershipType='Active'; AccountEnabled=$true }
            }
            # No prompt mock: -Force must not reach ShouldContinue, which in a non-interactive
            # host like this one is an error rather than a default.
            Export-MsecEntraGroupMemberReport -Path $Book -Name 'sg-a' -Force -WarningAction SilentlyContinue | Out-Null
        }
        (Import-Excel -Path $script:Book -WorksheetName 'sg-a')[0].MemberName | Should -Be 'Forced'
    }

    It 'carries over groups written by an earlier run' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            Mock Get-MsecEntraGroupMember -MockWith {
                [pscustomobject]@{ GroupName='sg-a'; GroupId='g1'; MemberName='Ada'; MemberType='user'; MemberId='u1'; MembershipType='Active'; AccountEnabled=$true }
            }
            Export-MsecEntraGroupMemberReport -Path $Book -Name 'sg-a' -WarningAction SilentlyContinue | Out-Null

            Mock Get-MsecEntraGroupMember -MockWith {
                [pscustomobject]@{ GroupName='sg-b'; GroupId='g2'; MemberName='Bob'; MemberType='user'; MemberId='u2'; MembershipType='Active'; AccountEnabled=$true }
            }
            Export-MsecEntraGroupMemberReport -Path $Book -Name 'sg-b' -Force -WarningAction SilentlyContinue | Out-Null
        }

        # Groups collected in separate runs share one document, so the Summary keeps both.
        $summary = @(Import-Excel -Path $script:Book -WorksheetName 'Summary')
        @($summary | ForEach-Object { $_.GroupName } | Sort-Object) | Should -Be @('sg-a', 'sg-b')
    }

    It 'requires something to look up' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            { Export-MsecEntraGroupMemberReport -Path $Book } | Should -Throw '*at least one*'
        }
    }

    It 'throws a clear error when not connected' {
        InModuleScope Msec -Parameters @{ Book = $script:Book } {
            param($Book)
            $script:MsecSession = $null
            { Export-MsecEntraGroupMemberReport -Path $Book -Name 'x' } | Should -Throw '*Connect-Msec*'
        }
    }
}