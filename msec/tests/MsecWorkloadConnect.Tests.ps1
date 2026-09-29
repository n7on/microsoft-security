#Requires -Module Pester
#
# Tests for the Exchange and SharePoint bridges, and the two collection commands behind them.
#
# These reach products msec does NOT otherwise touch, and each has a trap the module's Graph
# commands do not:
#
#   * Exchange and PnP take -AccessToken as a plain STRING. Connect-MgGraph is the odd one out
#     in wanting a SecureString, so copying that call is wrong here.
#   * a SharePoint token's audience is the site HOST, not the tenant - a token for
#     contoso.sharepoint.com is rejected by contoso-admin.sharepoint.com.
#   * Exchange needs a DIRECTORY ROLE on top of the app role, and reports the difference as a
#     plain authorisation failure that names nothing.

$script:HasExo = $null -ne (Get-Module -ListAvailable ExchangeOnlineManagement)
$script:HasPnp = $null -ne (Get-Module -ListAvailable PnP.PowerShell)

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Connect-MsecExchangeOnline' -Skip:(-not $script:HasExo) {

    BeforeEach {
        InModuleScope Msec {
            $script:MsecSession = @{
                TenantId = 't'; ClientId = 'client-1'; KeyVaultName = 'kv'; KeyName = 'k'
                ThumbprintBytes = [byte[]](1..20)
                Endpoints = @{ GraphResource = 'https://graph.microsoft.com'; EnvironmentName = 'AzureCloud' }
                Tokens = @{}
            }
        }
    }

    It 'asks for an Exchange token, not a Graph one, and passes it as a plain string' {
        InModuleScope Msec {
            $script:MsecSession.Tokens['https://outlook.office365.com'] = @{
                Token = 'EXO.TOKEN'; ExpiresOn = [DateTimeOffset]::UtcNow.AddMinutes(50)
            }
            Mock Get-MsecAccessToken -MockWith { 'EXO.TOKEN' }
            Mock Connect-ExchangeOnline -MockWith { }

            Connect-MsecExchangeOnline -Organization 'contoso.onmicrosoft.com'

            # Exchange issues its own audience - a Graph token is rejected here.
            Should -Invoke Get-MsecAccessToken -Times 1 -Exactly -ParameterFilter {
                $Resource -eq 'https://outlook.office365.com'
            }
            Should -Invoke Connect-ExchangeOnline -Times 1 -Exactly -ParameterFilter {
                # A plain String, NOT a SecureString - the opposite of Connect-MgGraph.
                $AccessToken -is [string] -and $AccessToken -eq 'EXO.TOKEN' -and
                $Organization -eq 'contoso.onmicrosoft.com' -and $AppId -eq 'client-1'
            }
        }
    }

    It 'refuses a token too close to expiry rather than failing mid-enumeration' {
        InModuleScope Msec {
            $script:MsecSession.Tokens['https://outlook.office365.com'] = @{
                Token = 'x'; ExpiresOn = [DateTimeOffset]::UtcNow.AddMinutes(2)
            }
            Mock Get-MsecAccessToken -MockWith { 'x' }
            Mock Connect-ExchangeOnline -MockWith { }

            { Connect-MsecExchangeOnline -Organization 'c.com' -MinimumMinutes 30 } | Should -Throw '*cannot renew*'
            Should -Invoke Connect-ExchangeOnline -Times 0 -Exactly
        }
    }

    It 'warns when the session is in a cloud this endpoint is wrong for' {
        $warnings = @()
        InModuleScope Msec {
            $script:MsecSession.Endpoints.EnvironmentName = 'AzureChinaCloud'
            $script:MsecSession.Tokens['https://outlook.office365.com'] = @{
                Token = 'x'; ExpiresOn = [DateTimeOffset]::UtcNow.AddMinutes(50)
            }
            Mock Get-MsecAccessToken -MockWith { 'x' }
            Mock Connect-ExchangeOnline -MockWith { }
            Connect-MsecExchangeOnline -Organization 'c.cn'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        ($warnings -join ' ') | Should -Match 'commercial Exchange endpoint'
    }

    It 'throws a clear error when not connected' {
        InModuleScope Msec {
            $script:MsecSession = $null
            { Connect-MsecExchangeOnline -Organization 'c.com' } | Should -Throw '*Connect-Msec*'
        }
    }
}

Describe 'Connect-MsecSharePointOnline' -Skip:(-not $script:HasPnp) {

    BeforeEach {
        InModuleScope Msec {
            $script:MsecSession = @{
                TenantId = 't'; ClientId = 'client-1'; KeyVaultName = 'kv'; KeyName = 'k'
                ThumbprintBytes = [byte[]](1..20)
                Endpoints = @{ GraphResource = 'https://graph.microsoft.com'; EnvironmentName = 'AzureCloud' }
                Tokens = @{}
            }
        }
    }

    It 'derives the token audience from the site HOST, not the full url' {
        InModuleScope Msec {
            $script:MsecSession.Tokens['https://contoso.sharepoint.com'] = @{
                Token = 'SP.TOKEN'; ExpiresOn = [DateTimeOffset]::UtcNow.AddMinutes(50)
            }
            Mock Get-MsecAccessToken -MockWith { 'SP.TOKEN' }
            Mock Connect-PnPOnline -MockWith { }

            Connect-MsecSharePointOnline -Url 'https://contoso.sharepoint.com/sites/finance'

            # The path must not reach the audience, or SharePoint rejects the token.
            Should -Invoke Get-MsecAccessToken -Times 1 -Exactly -ParameterFilter {
                $Resource -eq 'https://contoso.sharepoint.com'
            }
            Should -Invoke Connect-PnPOnline -Times 1 -Exactly -ParameterFilter {
                $Url -eq 'https://contoso.sharepoint.com/sites/finance' -and
                $AccessToken -is [string] -and $AccessToken -eq 'SP.TOKEN'
            }
        }
    }

    It 'treats the admin host as a different audience' {
        InModuleScope Msec {
            $script:MsecSession.Tokens['https://contoso-admin.sharepoint.com'] = @{
                Token = 'ADMIN.TOKEN'; ExpiresOn = [DateTimeOffset]::UtcNow.AddMinutes(50)
            }
            Mock Get-MsecAccessToken -MockWith { 'ADMIN.TOKEN' }
            Mock Connect-PnPOnline -MockWith { }

            Connect-MsecSharePointOnline -Url 'https://contoso-admin.sharepoint.com'

            # A tenant-host token does not work against the admin host, and vice versa.
            Should -Invoke Get-MsecAccessToken -Times 1 -Exactly -ParameterFilter {
                $Resource -eq 'https://contoso-admin.sharepoint.com'
            }
        }
    }

    It 'rejects a url that is not absolute' {
        InModuleScope Msec {
            Mock Get-MsecAccessToken -MockWith { 'x' }
            Mock Connect-PnPOnline -MockWith { }
            { Connect-MsecSharePointOnline -Url 'contoso.sharepoint.com' } | Should -Throw '*absolute URL*'
        }
    }
}

Describe 'Get-MsecExchangeMailboxPermission' -Skip:(-not $script:HasExo) {

    It 'drops NT AUTHORITY\SELF, which every mailbox grants itself' {
        $rows = InModuleScope Msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith {
                [PSCustomObject]@{ ConnectionUri = 'https://outlook.office365.com'
                                   TenantID = 't'; AppId = 'c'; ConnectionId = 'x' }
            }
            Mock Get-EXOMailbox -MockWith {
                [pscustomobject]@{ DisplayName = 'Finance'; UserPrincipalName = 'finance@x.com'
                                   PrimarySmtpAddress = 'finance@x.com'; RecipientTypeDetails = 'SharedMailbox' }
            }
            Mock Get-EXOMailboxPermission -MockWith {
                [pscustomobject]@{ User = 'NT AUTHORITY\SELF'; AccessRights = @('FullAccess'); IsInherited = $false; Deny = $false }
                [pscustomobject]@{ User = 'ada@x.com';         AccessRights = @('FullAccess'); IsInherited = $false; Deny = $false }
            }
            Get-MsecExchangeMailboxPermission
        }

        # Including SELF would put a meaningless finding on every mailbox.
        @($rows).Count | Should -Be 1
        $rows.Grantee  | Should -Be 'ada@x.com'
    }

    It 'says "None" for a mailbox nobody else can open, and "Unreadable" when it could not look' {
        $rows = InModuleScope Msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith {
                [PSCustomObject]@{ ConnectionUri = 'https://outlook.office365.com'
                                   TenantID = 't'; AppId = 'c'; ConnectionId = 'x' }
            }
            Mock Get-EXOMailbox -MockWith {
                [pscustomobject]@{ DisplayName = 'Private'; UserPrincipalName = 'p@x.com'; PrimarySmtpAddress = 'p@x.com'; RecipientTypeDetails = 'SharedMailbox' }
                [pscustomobject]@{ DisplayName = 'Denied';  UserPrincipalName = 'd@x.com'; PrimarySmtpAddress = 'd@x.com'; RecipientTypeDetails = 'SharedMailbox' }
            }
            Mock Get-EXOMailboxPermission -ParameterFilter { $Identity -eq 'p@x.com' } -MockWith {
                [pscustomobject]@{ User = 'NT AUTHORITY\SELF'; AccessRights = @('FullAccess'); IsInherited = $false; Deny = $false }
            }
            Mock Get-EXOMailboxPermission -ParameterFilter { $Identity -eq 'd@x.com' } -MockWith { throw 'Access denied' }
            Get-MsecExchangeMailboxPermission -WarningAction SilentlyContinue
        }

        # Two different answers, and only one of them is good news.
        ($rows | Where-Object MailboxUserPrincipalName -eq 'p@x.com').Grantee | Should -Be 'None'
        ($rows | Where-Object MailboxUserPrincipalName -eq 'd@x.com').Grantee | Should -Be 'Unreadable'
    }

    It 'names the directory role requirement when listing mailboxes is refused' {
        InModuleScope Msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }
            Mock Get-ConnectionInformation -MockWith {
                [PSCustomObject]@{ ConnectionUri = 'https://outlook.office365.com'
                                   TenantID = 't'; AppId = 'c'; ConnectionId = 'x' }
            }
            Mock Get-EXOMailbox -MockWith { throw 'The term is not recognized as an authorized operation' }
            # Exchange.ManageAsApp alone is NOT enough, and Exchange does not say so.
            { Get-MsecExchangeMailboxPermission } | Should -Throw '*directory role*'
        }
    }
}

Describe 'Get-MsecSharePointSiteUser' -Skip:(-not $script:HasPnp) {

    BeforeEach {
        InModuleScope Msec {
            $script:MsecSession = @{
                TenantId = 't'; ClientId = 'c'; KeyVaultName = 'kv'; KeyName = 'k'
                ThumbprintBytes = [byte[]](1..20)
                Endpoints = @{ GraphResource = 'https://graph.microsoft.com'; EnvironmentName = 'AzureCloud' }
                Tokens = @{}
            }
            # An ambient PnP connection, which the tests that omit -Url rely on. Individual
            # tests override it where the point is that there ISN'T one.
            Mock Get-PnPConnection -MockWith { [pscustomobject]@{ Url = 'https://x.sharepoint.com/sites/QA' } }
        }
    }


    It 'connects itself when given -Url, without moving the ambient session' {
        InModuleScope Msec {
            Mock Connect-MsecSharePointOnline -MockWith { [pscustomobject]@{ Url = 'https://x.sharepoint.com/sites/QA'; Tag = 'explicit-connection' } }
            Mock Get-PnPConnection -MockWith { [pscustomobject]@{ Url = 'https://x.sharepoint.com/sites/OTHER' } }
            Mock Get-PnPWeb -MockWith { [pscustomobject]@{ Url = 'https://x.sharepoint.com/sites/QA' } }
            Mock Get-PnPGroup -MockWith { $null }

            Get-MsecSharePointSiteUser -Url 'https://x.sharepoint.com/sites/QA' -WarningAction SilentlyContinue | Out-Null

            # It asked for a connection object rather than making one ambient - PnP keeps ONE
            # global connection, so connecting normally would leave the caller pointed at a
            # different site than they were on.
            Should -Invoke Connect-MsecSharePointOnline -Times 1 -Exactly -ParameterFilter { $PassThru }

            # THE REST OF THIS PATH IS NOT MOCKABLE, and pretending otherwise would be worse
            # than not testing it. PnP types -Connection as PnPConnection, so a stand-in
            # PSCustomObject fails PARAMETER BINDING before the mock is ever reached - which
            # this command then catches and turns into a warning. So a test asserting the PnP
            # calls happen would fail whether the code is right or wrong.
            #
            # Verified against a live tenant instead: Get-MsecSharePointSiteUser -Url <siteB>
            # returned siteB's members while Get-PnPConnection still pointed at siteA.
        }
    }

    It 'uses the ambient connection when no -Url is given' {
        InModuleScope Msec {
            Mock Connect-MsecSharePointOnline -MockWith { throw 'should not connect' }
            Mock Get-PnPConnection -MockWith { [pscustomobject]@{ Url = 'https://x.sharepoint.com/sites/QA' } }
            Mock Get-PnPWeb -MockWith { [pscustomobject]@{ Url = 'https://x.sharepoint.com/sites/QA' } }
            Mock Get-PnPGroup -MockWith { $null }

            Get-MsecSharePointSiteUser -WarningAction SilentlyContinue | Out-Null

            Should -Invoke Connect-MsecSharePointOnline -Times 0 -Exactly
            # No -Connection passed, so PnP falls back to the ambient one.
            Should -Invoke Get-PnPGroup -Times 1 -ParameterFilter { -not $Connection }
        }
    }

    It 'says what to do when there is neither a -Url nor a connection' {
        InModuleScope Msec {
            Mock Get-PnPConnection -MockWith { $null }
            Mock Connect-MsecSharePointOnline -MockWith { }
            { Get-MsecSharePointSiteUser } | Should -Throw '*pass -Url*'
        }
    }
    It 'types a direct member the same way as one reached through a group' {
        # The two paths are typed by different systems - SharePoint says 'User', Graph says
        # '#microsoft.graph.user'. Left alone the same person reads as 'User' or 'user'
        # depending on how they got access, and a filter on either silently misses the other.
        $rows = InModuleScope Msec {
            Mock Get-PnPWeb -MockWith { [pscustomobject]@{ Url = 'https://x.sharepoint.com/sites/QA' } }
            Mock Get-PnPGroup -ParameterFilter { $AssociatedOwnerGroup } -MockWith {
                [pscustomobject]@{ Title = 'QA Owners'; Users = @(
                    [pscustomobject]@{ Title = 'Direct Person'; Email = 'direct@x.com'; PrincipalType = 'User'; LoginName = 'i:0#.f|membership|direct@x.com' }
                    [pscustomobject]@{ Title = 'QA';            PrincipalType = 'SecurityGroup'; LoginName = 'c:0t.c|tenant|11111111-2222-3333-4444-555555555555' }
                ) }
            }
            Mock Get-PnPGroup -ParameterFilter { $AssociatedMemberGroup } -MockWith { $null }
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'u9'; displayName = 'Via Group'; userPrincipalName = 'via@x.com' }
            }
            Get-MsecSharePointSiteUser -WarningAction SilentlyContinue
        }

        @($rows).Count | Should -Be 2
        # Both lowercase 'user', whichever path produced them.
        @($rows | ForEach-Object { $_.PrincipalType } | Select-Object -Unique) | Should -Be @('user')

        # ViaGroup is what says where to remove the access.
        ($rows | Where-Object Name -eq 'Direct Person').ViaGroup | Should -BeNullOrEmpty
        ($rows | Where-Object Name -eq 'Via Group').ViaGroup     | Should -Be 'QA'
    }

    It 'does not claim a site has no group when the call simply failed' {
        $warnings = @()
        InModuleScope Msec {
            Mock Get-PnPWeb -MockWith { [pscustomobject]@{ Url = 'https://x.sharepoint.com/sites/QA' } }
            # A real splatting bug in this command produced exactly this shape, and the old
            # message asserted "this site has no associated Owner group" - which sent a code
            # defect undiagnosed as a property of the tenant.
            Mock Get-PnPGroup -MockWith { throw 'Cannot convert System.Object[] to GroupPipeBind' }
            Get-MsecSharePointSiteUser
        } -WarningVariable warnings -WarningAction SilentlyContinue

        ($warnings -join ' ') | Should -Match 'Could not read the associated'
        ($warnings -join ' ') | Should -Match 'may genuinely not have one, or the call failed'
    }

    It 'warns loudly when there is no msec session to expand groups with' {
        $warnings = @()
        $rows = InModuleScope Msec {
            # Without the second session every group is unresolved - which is exactly what a
            # DELETED group looks like. The output would read as a tenant full of orphans.
            $script:MsecSession = $null
            Mock Get-PnPWeb -MockWith { [pscustomobject]@{ Url = 'https://x.sharepoint.com/sites/QA' } }
            Mock Get-PnPGroup -ParameterFilter { $AssociatedOwnerGroup } -MockWith {
                [pscustomobject]@{ Title = 'QA Owners'; Users = @(
                    [pscustomobject]@{ Title = 'QA'; PrincipalType = 'SecurityGroup'; LoginName = 'c:0t.c|tenant|11111111-2222-3333-4444-555555555555' }
                ) }
            }
            Mock Get-PnPGroup -ParameterFilter { $AssociatedMemberGroup } -MockWith { $null }
            Get-MsecSharePointSiteUser
        } -WarningVariable warnings -WarningAction SilentlyContinue

        ($warnings -join ' ') | Should -Match 'will NOT be expanded'
        # And the row says which of the three reasons it is.
        ($rows | Where-Object PrincipalType -eq 'group').UnresolvedReason | Should -Be 'No msec session'
    }

    It 'keeps a group it could not read, rather than dropping the access' {
        $rows = InModuleScope Msec {
            Mock Get-PnPWeb -MockWith { [pscustomobject]@{ Url = 'https://x.sharepoint.com/sites/QA' } }
            Mock Get-PnPGroup -ParameterFilter { $AssociatedOwnerGroup } -MockWith {
                [pscustomobject]@{ Title = 'Deleted Group'; Users = @(
                    [pscustomobject]@{ Title = 'Deleted Group'; PrincipalType = 'SecurityGroup'; LoginName = 'c:0t.c|tenant|99999999-2222-3333-4444-555555555555' }
                ) }
            }
            Mock Get-PnPGroup -ParameterFilter { $AssociatedMemberGroup } -MockWith { $null }
            # SharePoint keeps granting access through a group Entra no longer has.
            Mock Invoke-MsecGraphRequest -MockWith { throw 'Request_ResourceNotFound' }
            Get-MsecSharePointSiteUser -WarningAction SilentlyContinue
        }

        @($rows).Count | Should -Be 1
        $rows.IsResolved       | Should -BeFalse
        $rows.UnresolvedReason | Should -Be 'Group could not be read from Entra'
        # Dropping it would report the site as having fewer owners than it does.
        $rows.Name             | Should -Be 'Deleted Group'
    }
}

Describe 'Get-MsecSharePointSite' {

    BeforeEach {
        InModuleScope Msec {
            $script:MsecSession = @{
                TenantId = 't'; ClientId = 'c'; KeyVaultName = 'kv'; KeyName = 'k'
                ThumbprintBytes = [byte[]](1..20); Tokens = @{}
                Endpoints = @{ GraphResource = 'https://graph.microsoft.com'; EnvironmentName = 'AzureCloud' }
            }
        }
    }

    It 'excludes app containers, which are most of what Graph calls a site' {
        $sites = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ displayName = 'Developers'; webUrl = 'https://x.sharepoint.com/sites/Developers'; id = '1' }
                [pscustomobject]@{ displayName = 'Team chat';  webUrl = 'https://x.sharepoint.com/teams/Chat';       id = '2' }
                # Loop / Designer backing storage - one per artefact. On a real tenant these
                # were 286 of 432 results, and running a site access review across them is
                # hundreds of wasted calls.
                [pscustomobject]@{ displayName = 'Loop thing'; webUrl = 'https://x.sharepoint.com/contentstorage/abc'; id = '3' }
                [pscustomobject]@{ displayName = 'Jane';       webUrl = 'https://x-my.sharepoint.com/personal/jane_x_com'; id = '4' }
                [pscustomobject]@{ displayName = 'Root';       webUrl = 'https://x.sharepoint.com'; id = '5'; root = @{} }
            }
            Get-MsecSharePointSite
        }

        @($sites | ForEach-Object { $_.DisplayName } | Sort-Object) | Should -Be @('Developers', 'Root', 'Team chat')
        @($sites | Where-Object SiteType -eq 'AppContainer').Count | Should -Be 0
        @($sites | Where-Object SiteType -eq 'Personal').Count     | Should -Be 0
    }

    It 'classifies everything under -All, so the denominator is visible' {
        $sites = InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ displayName = 'A'; webUrl = 'https://x.sharepoint.com/sites/A'; id = '1' }
                [pscustomobject]@{ displayName = 'B'; webUrl = 'https://x.sharepoint.com/contentstorage/b'; id = '2' }
                [pscustomobject]@{ displayName = 'C'; webUrl = 'https://x-my.sharepoint.com/personal/c'; id = '3' }
            }
            Get-MsecSharePointSite -All
        }

        # "146 of 432 are real sites" is a finding; "146 sites" hides that the tenant holds
        # three times as many objects Graph is willing to call a site.
        @($sites).Count | Should -Be 3
        @($sites | ForEach-Object { $_.SiteType } | Sort-Object) | Should -Be @('AppContainer', 'Personal', 'SiteCollection')
    }

    It 'names the GRAPH permission on a 403, not the SharePoint one' {
        InModuleScope Msec {
            Mock Invoke-MsecGraphRequest -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            # Sites.Read.All exists on both resources with the same name, and having the
            # SharePoint one is exactly the state someone will be in when this fails.
            { Get-MsecSharePointSite } | Should -Throw '*MICROSOFT GRAPH*'
        }
    }

    It 'throws a clear error when not connected' {
        InModuleScope Msec {
            $script:MsecSession = $null
            { Get-MsecSharePointSite } | Should -Throw '*Connect-Msec*'
        }
    }
}
