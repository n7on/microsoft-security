function Get-MsecTeamsPolicy {
    <#
    .SYNOPSIS
        The Teams settings that decide who can reach your people - external access, guest
        access, meeting lobby and recording, app installation - as one row per setting.

    .DESCRIPTION
        Teams policy is where a tenant quietly becomes reachable from the outside. Anonymous
        meeting join, open federation, guest access and unrestricted app installation are all
        defaults-on or defaults-permissive, none of them appear in a Secure Score or a
        Conditional Access review, and each is a real path in.

        ONE ROW PER SETTING, NOT PER POLICY. A meeting policy object carries roughly eighty
        properties, most of them about layout and captions. Returning whole objects makes the
        handful that matter impossible to see, and impossible to compare between two policies
        or two tenants. Flattened to (PolicyType, PolicyName, Setting, Value), the output
        sorts, filters and diffs.

        ONLY THE SECURITY-RELEVANT SETTINGS ARE PROJECTED, and which ones is a judgement this
        command makes on your behalf - so it is written down in the source rather than hidden.
        -All returns every property of every policy instead, for when you need to see what was
        left out.

        A POLICY TYPE THAT CANNOT BE READ IS REPORTED, NOT SKIPPED. Teams cmdlets fail
        individually when a role is missing or a feature is not licensed, and a report that
        silently omitted federation configuration would read as a tenant with none.

    .PARAMETER PolicyType
        Which policy areas to read. Default is all of them:
          Federation      external access - who outside the tenant can chat with your people
          Meeting         anonymous join, lobby, recording, external control
          Messaging       message deletion, read receipts
          AppPermission   which apps users may install
          Client          guest access, channel email, third-party storage providers
          Files           file sharing in chats with external users, and where uploads land

    .PARAMETER All
        Return every property of every policy, not just the security-relevant projection.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Get-MsecTeamsPolicy

    .EXAMPLE
        # The settings that let people in from outside.
        Get-MsecTeamsPolicy -PolicyType Federation, Client |
            Where-Object Value -in 'True', 'Everyone', 'EveryoneInCompanyExcludingGuests'

    .EXAMPLE
        # Compare the Global policy against the custom ones - drift is where exceptions hide.
        Get-MsecTeamsPolicy -PolicyType Meeting |
            Group-Object Setting | Where-Object { @($_.Group.Value | Select-Object -Unique).Count -gt 1 }

    .OUTPUTS
        PSCustomObject per setting, PSTypeName 'MsecTeamsPolicy'.

    .NOTES
        Needs Connect-Msec; the Teams sign-in is done for you by calling Connect-MsecTeams,
        which replaces any Teams session already open in this shell. See that command for why
        Teams requires a DIRECTORY ROLE on top of app permissions.

        Policies apply per user, and the Global policy is what a user gets unless they are
        assigned another. A permissive custom policy assigned to nobody is not a finding; one
        assigned to everyone is. This command reads the policies, not their assignments.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateSet('Federation', 'Meeting', 'Messaging', 'AppPermission', 'Client', 'Files')]
        [string[]] $PolicyType = @('Federation', 'Meeting', 'Messaging', 'AppPermission', 'Client', 'Files'),

        [switch] $All
    )

    # CONNECTS ITSELF, like Get-MsecSharePointSiteUser -Url does: every other command in this
    # module is one call after Connect-Msec, and needing a second connect step for this one is
    # a trap rather than a feature.
    #
    # NOT a Get-Command check for Get-Cs*: that succeeds as soon as MicrosoftTeams is
    # INSTALLED, connected or not, so it let an unconnected run through to fail five times with
    # a warning blaming a directory role. The module exposes no "am I connected" cmdlet, so the
    # honest move is to establish the session rather than to guess at it.
    # ...unless the caller deliberately signed in as themselves. Reconnecting as the app there
    # would swap a session that can write for one that cannot, and the next Set-Cs* would fail
    # on rights the caller does have.
    if ($script:MsecSession -and -not $script:MsecTeamsAsCurrentUser) {
        Connect-MsecTeams
    }
    elseif (-not (Get-Command Get-CsTenantFederationConfiguration -ErrorAction SilentlyContinue)) {
        throw 'Not connected to Teams and no msec session to connect with. Run Connect-Msec, or Connect-MicrosoftTeams yourself.'
    }

    # The settings worth reporting, per policy area. Written out rather than derived, because
    # "which of these eighty properties is a security control" is exactly the judgement a
    # reader needs to be able to check and argue with.
    $projection = @{
        Federation = @{
            Cmdlet   = 'Get-CsTenantFederationConfiguration'
            Settings = @(
                'AllowFederatedUsers'          # any other Teams tenant can reach your people
                'AllowPublicUsers'             # consumer Skype
                'AllowTeamsConsumer'           # personal Teams accounts
                'AllowTeamsConsumerInbound'
                'RestrictTeamsConsumerToExternalUserProfiles'
                'AllowedDomains'               # an allow-list is far stronger than a block-list
                'BlockedDomains'
                'SharedSipAddressSpace'
            )
        }
        Meeting = @{
            Cmdlet   = 'Get-CsTeamsMeetingPolicy'
            Settings = @(
                'AllowAnonymousUsersToJoinMeeting'   # no account needed at all
                'AllowAnonymousUsersToStartMeeting'  # and no host present to admit them
                'AutoAdmittedUsers'                  # who bypasses the lobby
                'AllowPSTNUsersToBypassLobby'
                'AllowExternalParticipantGiveRequestControl'  # screen control to an outsider
                'AllowCloudRecording'
                'AllowTranscription'
                'MeetingChatEnabledType'
                'DesignatedPresenterRoleMode'
                'AllowedUsersForMeetingContext'
            )
        }
        Messaging = @{
            Cmdlet   = 'Get-CsTeamsMessagingPolicy'
            Settings = @(
                'AllowUserDeleteMessage'       # deletion by the author defeats retention
                'AllowOwnerDeleteMessage'
                'AllowUserEditMessage'
                'ReadReceiptsEnabledType'
                'AllowSecurityEndUserReporting'
            )
        }
        AppPermission = @{
            Cmdlet   = 'Get-CsTeamsAppPermissionPolicy'
            Settings = @(
                'DefaultCatalogAppsType'       # 'AllowedAppList' is control; 'BlockedAppList' is not
                'GlobalCatalogAppsType'
                'PrivateCatalogAppsType'
                'DefaultCatalogApps'
                'GlobalCatalogApps'
                'PrivateCatalogApps'
            )
        }
        # Files policy is NOT the same surface as the third-party storage switches under
        # Client. Those say which storage providers appear in Teams; this says whether a file
        # can leave the tenant through a chat with someone outside it, and where uploads land
        # by default. A tenant can have every third-party provider off and still allow that.
        Files = @{
            Cmdlet   = 'Get-CsTeamsFilesPolicy'
            Settings = @(
                'FileSharingInChatswithExternalUsers'  # files out of the tenant, via chat
                'DefaultFileUploadAppId'               # where uploads land - a non-default app
                                                       # means files leave SharePoint/OneDrive
                'NativeFileEntryPoints'                # uploading from the local device at all
            )
        }

        Client = @{
            Cmdlet   = 'Get-CsTeamsClientConfiguration'
            Settings = @(
                'AllowGuestUser'               # guests in teams at all
                'AllowEmailIntoChannel'        # anyone who learns the address can post
                'AllowDropBox'; 'AllowBox'; 'AllowGoogleDrive'; 'AllowShareFile'; 'AllowEgnyte'
                'AllowOrganizationTab'
                'AllowScopedPeopleSearchandAccess'
            )
        }
    }

    foreach ($type in $PolicyType) {
        $spec = $projection[$type]

        $policies = $null
        try {
            $policies = @(& $spec.Cmdlet -ErrorAction Stop)
        }
        catch {
            # Named, not skipped: a missing federation configuration reads as a tenant with no
            # external access, which is the opposite of the truth.
            # The hint is a GUESS, so it is only offered where it fits. An authorisation
            # failure against a connected session really is a directory role most of the time;
            # anything else - no session, a transient error - is its own problem, and pointing
            # at role assignment there sends the reader to look for something already correct.
            $hint = if ($_.Exception.Message -match 'unauthor|forbidden|denied|privilege|access') {
                " The likeliest cause is the missing DIRECTORY ROLE: app permissions alone are not enough for Teams, and the app also needs Teams Administrator, Teams Communications Administrator or Global Reader."
            }
            else { '' }
            Write-Warning "Could not read $type policy via $($spec.Cmdlet), so it is NOT covered by this output.$hint Teams said: $($_.Exception.Message)"
            [PSCustomObject]@{
                PSTypeName = 'MsecTeamsPolicy'
                PolicyType = $type
                PolicyName = 'Unreadable'
                Setting    = $null
                Value      = $null
                IsGlobal   = $null
            }
            continue
        }

        foreach ($policy in $policies) {
            # Identity is 'Global' for the tenant-wide policy and 'Tag:<name>' for a custom
            # one. Trimmed, because the prefix is noise in a table.
            $name = [string] $policy.Identity
            if (-not $name) { $name = 'Global' }
            $display = $name -replace '^Tag:', ''

            $settings = if ($All) {
                @($policy.PSObject.Properties.Name | Where-Object { $_ -notin 'Identity' })
            }
            else {
                # Only what this policy object actually carries - the set differs between
                # module versions, and asking for an absent property would emit a row of nulls
                # that reads as "configured off".
                @($spec.Settings | Where-Object { $_ -in $policy.PSObject.Properties.Name })
            }

            foreach ($setting in $settings) {
                $value = $policy.$setting
                if ($null -ne $value -and $value -isnot [string] -and $value -is [System.Collections.IEnumerable]) {
                    $value = (@($value) | ForEach-Object { "$_" }) -join '; '
                }

                [PSCustomObject]@{
                    PSTypeName = 'MsecTeamsPolicy'
                    PolicyType = $type
                    PolicyName = $display
                    Setting    = $setting
                    Value      = [string] $value
                    # The one a user gets unless assigned another - so a permissive Global is a
                    # tenant-wide finding, where a permissive custom policy may apply to nobody.
                    IsGlobal   = ($display -eq 'Global')
                }
            }
        }
    }
}
