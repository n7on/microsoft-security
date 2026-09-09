#Requires -Module Pester
#
# Tests for New-MsecApp. The behaviour that matters is idempotence: it is documented as safe
# to re-run, which means a re-run against an app holding only SOME of the permissions has to
# add the rest - to the app's requiredResourceAccess AND as appRoleAssignments, which are
# what actually grant them.
#
# It also has to SAY so. This step used to report only through Write-Verbose, so a re-run
# that added a dozen permissions printed one line about finding the app and nothing about
# the grants - which is indistinguishable from having done nothing, and was reported as
# exactly that.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    # Passed as TEXT and rebuilt inside InModuleScope - a scriptblock stays bound to the
    # session state it was written in and could not resolve Mock's private targets there.
    $script:MockText = @'
Mock Get-AzContext -MockWith { [pscustomobject]@{ Tenant = @{ Id = 'tenant-1' } } }
Mock Get-AzAccessToken -MockWith { [pscustomobject]@{ Token = 'user-token' } }
Mock Get-MsecEnvironment -MockWith {
    [pscustomobject]@{
        EnvironmentName  = 'AzureCloud'
        GraphResource    = 'https://graph.microsoft.com'
        DefenderResource = 'https://api.securitycenter.microsoft.com'
    }
}

# The certificate already exists and matches, so the run reaches the consent step. Every
# Key Vault cmdlet the function can touch is mocked - Update-AzKeyVaultCertificate runs
# unconditionally, and an unmocked one reaches real Azure from a test run.
Mock Get-AzKeyVaultCertificate -MockWith {
    [pscustomobject]@{ Thumbprint = 'AABB'; Certificate = [pscustomobject]@{ RawData = [byte[]](1..10) } }
}
Mock Update-AzKeyVaultCertificate       -MockWith { }
Mock Add-AzKeyVaultCertificate          -MockWith { }
Mock New-AzKeyVaultCertificatePolicy    -MockWith { [pscustomobject]@{} }
Mock Get-AzKeyVaultCertificateOperation -MockWith { [pscustomobject]@{ Status = 'completed' } }

$script:Calls = [System.Collections.Generic.List[object]]::new()

Mock Invoke-RestMethod -MockWith {
    # The function's Graph helper serialises to JSON before calling Invoke-RestMethod, so
    # $Body here is a STRING. Parsed back so assertions can address its properties -
    # reading .appRoleId off the raw JSON silently yields $null and every assertion passes
    # vacuously.
    $parsed = if ($Body) { $Body | ConvertFrom-Json } else { $null }
    $script:Calls.Add([pscustomobject]@{ Method = [string]$Method; Uri = [string]$Uri; Body = $parsed })
    $u = [string]$Uri

    if ($u -match "servicePrincipals\(appId='00000003-0000-0000-c000-") {
        # Graph exposes every application role msec asks for.
        return [pscustomobject]@{
            id = 'sp-graph'
            appRoles = @($script:GraphRoleValues | ForEach-Object {
                [pscustomobject]@{ value = $_; id = "role-$_"; allowedMemberTypes = @('Application') }
            })
        }
    }
    if ($u -match "servicePrincipals\(appId='fc780465-") {
        return [pscustomobject]@{ id = 'sp-mdatp'; appRoles = @(
            [pscustomobject]@{ value = 'Score.Read.All';         id = 'role-score'; allowedMemberTypes = @('Application') }
            [pscustomobject]@{ value = 'Machine.Read.All';       id = 'role-machine'; allowedMemberTypes = @('Application') }
            [pscustomobject]@{ value = 'Vulnerability.Read.All'; id = 'role-vuln'; allowedMemberTypes = @('Application') }) }
    }
    # Office 365 Exchange Online and SharePoint - only reached with -Workload.
    if ($u -match "servicePrincipals\(appId='00000002-0000-0ff1-ce00-") {
        if ($script:ExchangeSpMissing) { throw 'Request_ResourceNotFound' }
        return [pscustomobject]@{ id = 'sp-exo'; appRoles = @(
            [pscustomobject]@{ value = 'Exchange.ManageAsApp'; id = 'role-exo'; allowedMemberTypes = @('Application') }) }
    }
    if ($u -match "servicePrincipals\(appId='48ac35b8-9aa8-4d74-927d-1f4a14a0b239") {
        return [pscustomobject]@{ id = 'sp-teams'; appRoles = @(
            [pscustomobject]@{ value = 'application_access'; id = 'role-teams'; allowedMemberTypes = @('Application') }) }
    }
    if ($u -match "servicePrincipals\(appId='00000003-0000-0ff1-ce00-") {
        return [pscustomobject]@{ id = 'sp-spo'; appRoles = @(
            [pscustomobject]@{ value = 'Sites.Read.All'; id = 'role-spo-sites'; allowedMemberTypes = @('Application') }) }
    }
    if ($u -match '/roleManagement/directory/roleDefinitions') {
        if ($script:RoleDefinitionMissing) { return [pscustomobject]@{ value = @() } }
        return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'roledef-globalreader'; displayName = 'Global Reader' }) }
    }
    if ($u -match '/roleManagement/directory/roleAssignments') {
        if ($Method -eq 'POST') {
            if ($script:RoleAssignDenied) { throw 'Authorization_RequestDenied' }
            return [pscustomobject]@{ id = 'assignment-1' }
        }
        return [pscustomobject]@{ value = @($script:ExistingRoleAssignments) }
    }
    if ($u -match '/applications\?\$filter=') {
        return [pscustomobject]@{ value = @([pscustomobject]@{
            id = 'app-obj-1'; appId = 'client-1'; displayName = 'msec'
            requiredResourceAccess = $script:ExistingRRA
            keyCredentials = @()
        }) }
    }
    if ($u -match '/servicePrincipals\?\$filter=appId') {
        return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'sp-app-1' }) }
    }
    if ($u -match '/appRoleAssignments' -and $Method -eq 'GET') {
        return [pscustomobject]@{ value = $script:ExistingGrants }
    }
    [pscustomobject]@{ id = 'generic' }
}
'@
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'New-MsecApp' {

    Context 're-run against an app missing most permissions' {

        BeforeEach {
            InModuleScope Msec {
                $script:GraphRoleValues = @(
                    'SecurityEvents.Read.All', 'DeviceManagementConfiguration.Read.All',
                    'DeviceManagementManagedDevices.Read.All', 'DeviceManagementScripts.Read.All',
                    'ThreatHunting.Read.All',
                    'SecurityIncident.Read.All', 'Policy.Read.All', 'AuditLog.Read.All',
                    'Organization.Read.All', 'RoleManagement.Read.Directory', 'User.Read.All',
                    'Group.Read.All', 'Application.Read.All',
                    'PrivilegedEligibilitySchedule.Read.AzureADGroup'
                )
                # The app requests, and has consent for, only two of them.
                $script:ExistingRRA = @(
                    [pscustomobject]@{
                        resourceAppId  = '00000003-0000-0000-c000-000000000000'
                        resourceAccess = @(
                            [pscustomobject]@{ id = 'role-SecurityEvents.Read.All'; type = 'Role' }
                            [pscustomobject]@{ id = 'role-Policy.Read.All';         type = 'Role' }
                        )
                    }
                )
                $script:ExistingGrants = @(
                    [pscustomobject]@{ resourceId = 'sp-graph'; appRoleId = 'role-SecurityEvents.Read.All' }
                    [pscustomobject]@{ resourceId = 'sp-graph'; appRoleId = 'role-Policy.Read.All' }
                )
            }
        }

        It 'grants every missing permission and leaves the present ones alone' {
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                $result = New-MsecApp -KeyVaultName 'kv-test' -InformationAction SilentlyContinue 6>$null
                [pscustomobject]@{ Result = $result; Calls = @($script:Calls) }
            }

            # 14 Graph roles + 3 Defender roles = 17 desired, 2 already consented.
            @($out.Result.GrantedNow).Count     | Should -Be 15
            @($out.Result.AlreadyGranted).Count | Should -Be 2

            # One POST per newly granted pair, and none for the two that were already there.
            $posts = @($out.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/appRoleAssignments' })
            @($posts).Count | Should -Be 15
            $posts.Body.appRoleId | Should -Not -Contain 'role-SecurityEvents.Read.All'
            $posts.Body.appRoleId | Should -Contain 'role-DeviceManagementManagedDevices.Read.All'
            $posts.Body.appRoleId | Should -Contain 'role-score'
            $posts.Body.appRoleId | Should -Contain 'role-machine'
            $posts.Body.appRoleId | Should -Contain 'role-vuln'

            # Every grant targets the app's own SP as principal, and the resource's SP as
            # resource - transposing those two silently grants nothing useful.
            ($posts.Body.principalId | Sort-Object -Unique) | Should -Be 'sp-app-1'
        }

        It 'merges requiredResourceAccess instead of clobbering it' {
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                New-MsecApp -KeyVaultName 'kv-test' 6>$null | Out-Null
                [pscustomobject]@{ Calls = @($script:Calls) }
            }

            $patch = @($out.Calls | Where-Object { $_.Method -eq 'PATCH' -and $_.Body.requiredResourceAccess }) |
                        Select-Object -First 1
            $patch | Should -Not -BeNullOrEmpty

            $graphEntry = $patch.Body.requiredResourceAccess |
                Where-Object { $_.resourceAppId -eq '00000003-0000-0000-c000-000000000000' }
            $ids = @($graphEntry.resourceAccess | ForEach-Object { $_.id })

            @($ids).Count | Should -Be 14
            # The two it already had survive...
            $ids | Should -Contain 'role-SecurityEvents.Read.All'
            $ids | Should -Contain 'role-Policy.Read.All'
            # ...and the missing ones are added.
            $ids | Should -Contain 'role-Group.Read.All'
            # No duplicates - re-running must not grow the collection every time.
            @($ids | Sort-Object -Unique).Count | Should -Be 14
        }

        It 'reports the grants on stdout, not only through -Verbose' {
            # THE regression. Silence here was reported as "it does not add the grants".
            $text = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                New-MsecApp -KeyVaultName 'kv-test' 6>&1 | Out-String
            }

            $text | Should -Match '15 granted now'
            $text | Should -Match '2 already present'
            $text | Should -Match 'Group\.Read\.All'
            # And the instruction without which a caller re-runs this, retries, gets the same
            # 403, and concludes the grant failed.
            $text | Should -Match 'Disconnect-Msec'
        }
    }

    Context 'a fully consented app' {

        BeforeEach {
            InModuleScope Msec {
                $script:GraphRoleValues = @('SecurityEvents.Read.All')
                $script:ExistingRRA = @(
                    [pscustomobject]@{
                        resourceAppId  = '00000003-0000-0000-c000-000000000000'
                        resourceAccess = @([pscustomobject]@{ id = 'role-SecurityEvents.Read.All'; type = 'Role' })
                    }
                    [pscustomobject]@{
                        resourceAppId  = 'fc780465-2017-40d4-a0c5-307022471b92'
                        resourceAccess = @(
                            [pscustomobject]@{ id = 'role-score';   type = 'Role' }
                            [pscustomobject]@{ id = 'role-machine'; type = 'Role' }
                            [pscustomobject]@{ id = 'role-vuln';    type = 'Role' }
                        )
                    }
                )
                $script:ExistingGrants = @(
                    [pscustomobject]@{ resourceId = 'sp-graph'; appRoleId = 'role-SecurityEvents.Read.All' }
                    [pscustomobject]@{ resourceId = 'sp-mdatp'; appRoleId = 'role-score' }
                    [pscustomobject]@{ resourceId = 'sp-mdatp'; appRoleId = 'role-machine' }
                    [pscustomobject]@{ resourceId = 'sp-mdatp'; appRoleId = 'role-vuln' }
                )
            }
        }

        It 'grants nothing and does not tell you to reconnect' {
            # Idempotence: a no-op re-run must be visibly a no-op, or the reconnect notice
            # becomes noise that gets ignored on the run where it matters.
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                $text = New-MsecApp -KeyVaultName 'kv-test' 6>&1 | Out-String
                [pscustomobject]@{ Text = $text; Calls = @($script:Calls) }
            }

            @($out.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/appRoleAssignments' }).Count |
                Should -Be 0
            $out.Text | Should -Match '0 granted now'
            $out.Text | Should -Not -Match 'Disconnect-Msec'
        }
    }

    Context 'a cloud that does not offer every role' {

        BeforeEach {
            InModuleScope Msec {
                # Azure China exposes a reduced set of Graph app roles.
                $script:GraphRoleValues = @('SecurityEvents.Read.All', 'Policy.Read.All')
                $script:ExistingRRA = @()
                $script:ExistingGrants = @()
            }
        }

        It 'skips unavailable roles, reports them, and still configures the rest' {
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                $result = New-MsecApp -KeyVaultName 'kv-test' -WarningVariable w -WarningAction SilentlyContinue 6>$null
                [pscustomobject]@{ Result = $result; Warnings = @($w) }
            }

            # Two Graph roles exist here, plus the three Defender ones - the reduced set this
            # context stands for is a GRAPH reduction; a cloud with no Defender at all skips
            # that resource entirely rather than finding its roles missing.
            @($out.Result.GrantedNow).Count | Should -Be 5
            # The twelve Graph roles that do not exist in this cloud are named rather than
            # silently lost.
            # This count is deliberately literal: it has to be updated by hand whenever a
            # permission is added to $resources, which is the point - a role that vanishes
            # from the list should fail a test rather than quietly stop being requested.
            @($out.Result.UnavailableRoles).Count | Should -Be 12
            ($out.Warnings -join "`n") | Should -Match 'not available'
            ($out.Warnings -join "`n") | Should -Match 'Group\.Read\.All'
        }
    }

    Context 'workloads beyond Graph and Defender' {

        BeforeEach {
            InModuleScope Msec {
                $script:GraphRoleValues = @('SecurityEvents.Read.All', 'Policy.Read.All',
                                            'Sites.Read.All', 'SharePointTenantSettings.Read.All')
                $script:ExistingRRA = @()
                $script:ExistingGrants = @()
                $script:ExistingRoleAssignments = @()
                $script:RoleAssignDenied = $false
                $script:RoleDefinitionMissing = $false
                $script:ExchangeSpMissing = $false
                # Shared across the whole file and never cleared otherwise, so "no calls of
                # this kind were made" would be answered by an earlier test's calls.
                $script:Calls = [System.Collections.Generic.List[object]]::new()
            }
        }

        It 'grants nothing extra unless a workload is asked for' {
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                New-MsecApp -KeyVaultName 'kv-test' -WarningAction SilentlyContinue 6>$null
                [pscustomobject]@{ Calls = @($script:Calls) }
            }

            # Exchange needs a directory role and SharePoint needs fresh consent, so neither is
            # a side effect of an ordinary bootstrap.
            @($out.Calls | Where-Object Uri -match '0ff1-ce00').Count | Should -Be 0
            # The DIRECTORY role path specifically. Matching bare 'roleAssignments' also
            # catches '/appRoleAssignments', which every ordinary grant uses - so the loose
            # pattern counts six routine calls and reads as a failure.
            @($out.Calls | Where-Object Uri -match '/roleManagement/directory/roleAssignments').Count | Should -Be 0
        }

        It 'grants SharePoint on the SharePoint service principal, not on Graph' {
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                $result = New-MsecApp -KeyVaultName 'kv-test' -Workload SharePoint -WarningAction SilentlyContinue 6>$null
                [pscustomobject]@{ Result = $result; Calls = @($script:Calls) }
            }

            # Sites.Read.All exists on BOTH Microsoft Graph and SharePoint with the same name.
            # PnP presents a SharePoint-audience token, so the grant must target sp-spo -
            # granting the Graph one looks right in the portal and still fails.
            $grant = @($out.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/appRoleAssignments' -and $_.Body.appRoleId -eq 'role-spo-sites' })
            @($grant).Count | Should -Be 1
            $grant[0].Body.resourceId | Should -Be 'sp-spo'

            $out.Result.GrantedNow | Should -Contain 'Office 365 SharePoint Online: Sites.Read.All'

            # The tenant-wide sharing posture - SharingCapability, the domain allow-list, the
            # restriction mode - lives at /admin/sharepoint/settings and needs a permission of
            # its own. Sites.Read.All reads SITES, not tenant settings, and the call 403s with
            # 'Caller does not have required permissions for this API', naming nothing.
            $tenantGrant = @($out.Calls | Where-Object {
                $_.Method -eq 'POST' -and $_.Uri -match '/appRoleAssignments' -and
                $_.Body.appRoleId -eq 'role-SharePointTenantSettings.Read.All'
            })
            @($tenantGrant).Count | Should -Be 1
            $tenantGrant[0].Body.resourceId | Should -Be 'sp-graph'

            # SharePoint needs no directory role - that is Exchange's problem alone.
            $out.Result.DirectoryRole | Should -BeNullOrEmpty
        }

        It 'assigns the directory role for Exchange, because the app role alone is not enough' {
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                $result = New-MsecApp -KeyVaultName 'kv-test' -Workload Exchange -WarningAction SilentlyContinue 6>$null
                [pscustomobject]@{ Result = $result; Calls = @($script:Calls) }
            }

            # The app role...
            @($out.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Body.appRoleId -eq 'role-exo' }).Count | Should -Be 1

            # ...AND the directory role. Without the second, every Get-EXO* fails with an
            # authorisation error that names no missing permission.
            $assign = @($out.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/roleManagement/directory/roleAssignments' })
            @($assign).Count | Should -Be 1
            $assign[0].Body.roleDefinitionId | Should -Be 'roledef-globalreader'
            $assign[0].Body.principalId      | Should -Be 'sp-app-1'
            $assign[0].Body.directoryScopeId | Should -Be '/'

            $out.Result.DirectoryRole | Should -Be 'Global Reader'
        }

        It 'grants Teams on the Teams admin API and assigns the directory role' {
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                $result = New-MsecApp -KeyVaultName 'kv-test' -Workload Teams -WarningAction SilentlyContinue 6>$null
                [pscustomobject]@{ Result = $result; Calls = @($script:Calls) }
            }

            # Teams is a SEPARATE audience from Graph. Connect-MicrosoftTeams presents a token
            # for the Skype and Teams Tenant Admin API, which carries only the roles granted on
            # THAT resource - so Graph permissions, however broad, buy nothing here.
            $grant = @($out.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/appRoleAssignments' -and $_.Body.appRoleId -eq 'role-teams' })
            @($grant).Count | Should -Be 1
            $grant[0].Body.resourceId | Should -Be 'sp-teams'

            # And the directory role, for the same reason Exchange needs one: without it
            # Connect-MicrosoftTeams succeeds and every Get-Cs* call then fails.
            $assign = @($out.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/roleManagement/directory/roleAssignments' })
            @($assign).Count | Should -Be 1
            $out.Result.DirectoryRole | Should -Be 'Global Reader'
        }

        It 'takes the directory role under its old Exchange-specific name' {
            # -ExchangeDirectoryRole shipped in 0.2.0. Renaming it outright would break every
            # caller that already passes it, and silently: a bootstrap script would fail at the
            # parameter binder rather than at anything to do with permissions.
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                New-MsecApp -KeyVaultName 'kv-test' -Workload Exchange `
                    -ExchangeDirectoryRole 'Exchange Administrator' -WarningAction SilentlyContinue 6>$null
            }

            $out.DirectoryRole | Should -Be 'Exchange Administrator'
        }

        It 'does not re-assign a directory role the app already holds' {
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                $script:ExistingRoleAssignments = @([pscustomobject]@{ id = 'existing'; principalId = 'sp-app-1'; roleDefinitionId = 'roledef-globalreader' })
                $result = New-MsecApp -KeyVaultName 'kv-test' -Workload Exchange -WarningAction SilentlyContinue 6>$null
                [pscustomobject]@{ Result = $result; Calls = @($script:Calls) }
            }

            # Re-running must be a no-op, like the rest of this command.
            @($out.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/roleManagement/directory/roleAssignments' }).Count | Should -Be 0
            $out.Result.DirectoryRole | Should -Match 'already assigned'
        }

        It 'configures everything else when the caller cannot assign a directory role' {
            $warnings = @()
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                # Creating a role assignment needs Privileged Role Administrator - a higher bar
                # than the rest of this command, so a caller may legitimately not have it.
                $script:RoleAssignDenied = $true
                New-MsecApp -KeyVaultName 'kv-test' -Workload Exchange 6>$null
            } -WarningVariable warnings -WarningAction SilentlyContinue

            # The app roles still landed; only the role assignment failed.
            $out.GrantedNow | Should -Contain 'Office 365 Exchange Online: Exchange.ManageAsApp'
            $out.DirectoryRole | Should -BeNullOrEmpty
            ($warnings -join ' ') | Should -Match 'Privileged Role Administrator'
            ($warnings -join ' ') | Should -Match 'NOT enough'
        }

        It 'skips a workload whose service principal does not exist in the tenant' {
            $warnings = @()
            $out = InModuleScope Msec -Parameters @{ MockText = $script:MockText } {
                param($MockText)
                & ([scriptblock]::Create($MockText))
                # A tenant with no Exchange Online. Must not abort the whole bootstrap.
                $script:ExchangeSpMissing = $true
                New-MsecApp -KeyVaultName 'kv-test' -Workload Exchange 6>$null
            } -WarningVariable warnings -WarningAction SilentlyContinue

            $out.UnavailableRoles -join ' ' | Should -Match 'service principal not found'
            ($warnings -join ' ') | Should -Match 'could not be resolved'
            # The Graph roles were still configured.
            @($out.GrantedNow).Count | Should -BeGreaterThan 0
        }
    }
}