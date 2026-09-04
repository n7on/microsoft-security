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
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
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

    if ($u -match "servicePrincipals\(appId='00000003-") {
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
}
