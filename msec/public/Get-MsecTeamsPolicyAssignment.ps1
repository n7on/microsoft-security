function Get-MsecTeamsPolicyAssignment {
    <#
    .SYNOPSIS
        How many users each Teams policy actually applies to - including the ones that apply
        to nobody.

    .DESCRIPTION
        Get-MsecTeamsPolicy says what each policy CONTAINS. This says who GETS it, which is
        the other half of the question and the half that decides whether a setting matters.

        A tenant can hold a carefully restrictive meeting policy and still be wide open,
        because the restrictive policy is assigned to three people and everyone else falls
        through to a permissive Global. From the policy list alone those two tenants are
        indistinguishable. This command is what tells them apart.

        POLICIES WITH ZERO USERS ARE RETURNED, NOT OMITTED. That is the finding, not an empty
        result - a policy nobody holds is configuration someone wrote and believes is in
        force. The policy list is read separately from the user list precisely so a policy
        with no holders still appears.

        ONLY PER-USER POLICY TYPES ARE COVERED. Federation and Client are tenant-wide
        configurations with no assignment at all, so asking who holds them is meaningless -
        they are in Get-MsecTeamsPolicy and deliberately absent here.

        A USER WITH NO EXPLICIT ASSIGNMENT GETS GLOBAL. Teams reports that as a null property
        rather than as the string 'Global', so those users are counted toward Global here.
        This is why UserCount for Global is usually the whole tenant.

        UNREADABLE IS NOT ZERO. If the user list cannot be read, UserCount is $null on every
        row and a warning says so, rather than reporting every policy as applying to nobody -
        which is both wrong and the most alarming possible reading.

    .PARAMETER PolicyType
        Which per-user policy areas to report. Default is all of them.

    .PARAMETER IncludeUser
        Return one row per user holding an EXPLICIT (non-Global) assignment instead of the
        per-policy counts. Use it to see who the exceptions actually are.

    .EXAMPLE
        Get-MsecTeamsPolicyAssignment

        Every per-user policy with the number of users it applies to.

    .EXAMPLE
        Get-MsecTeamsPolicyAssignment | Where-Object UserCount -eq 0

        The policies that apply to nobody.

    .EXAMPLE
        Get-MsecTeamsPolicyAssignment -PolicyType Meeting -IncludeUser

        Who holds a meeting policy other than Global.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateSet('Meeting', 'Messaging', 'AppPermission', 'Files')]
        [string[]] $PolicyType = @('Meeting', 'Messaging', 'AppPermission', 'Files'),

        [switch] $IncludeUser
    )

    # Same self-connect contract as Get-MsecTeamsPolicy - see the note there for why this is
    # not a Get-Command check, and why a deliberate -AsCurrentUser session is left alone.
    if ($script:MsecSession -and -not $script:MsecTeamsAsCurrentUser) {
        Connect-MsecTeams
    }
    elseif (-not (Get-Command Get-CsOnlineUser -ErrorAction SilentlyContinue)) {
        throw 'Not connected to Teams and no msec session to connect with. Run Connect-Msec, or Connect-MicrosoftTeams yourself.'
    }

    # The policy-listing cmdlet and the Get-CsOnlineUser property that records the assignment.
    # They are not derivable from each other: the property is 'Teams<X>Policy' for some areas
    # and not for others, so both are written down.
    $areas = @{
        Meeting       = @{ Cmdlet = 'Get-CsTeamsMeetingPolicy';       UserProperty = 'TeamsMeetingPolicy' }
        Messaging     = @{ Cmdlet = 'Get-CsTeamsMessagingPolicy';     UserProperty = 'TeamsMessagingPolicy' }
        AppPermission = @{ Cmdlet = 'Get-CsTeamsAppPermissionPolicy'; UserProperty = 'TeamsAppPermissionPolicy' }
        Files         = @{ Cmdlet = 'Get-CsTeamsFilesPolicy';         UserProperty = 'TeamsFilesPolicy' }
    }

    # -ResultSize is a 32-bit integer on this cmdlet, NOT the 'Unlimited' keyword the rest of
    # the Exchange-family cmdlets take. Passing 'Unlimited' throws a transformation error, and
    # passing [uint32]::MaxValue overflows the Int32 it actually binds to.
    $users = $null
    try {
        $users = @(Get-CsOnlineUser -ResultSize ([int]::MaxValue) -ErrorAction Stop)
    }
    catch {
        # Counts are reported as $null below rather than 0. A failed read that prints zero
        # users on every policy reads as a tenant where no policy applies to anyone.
        Write-Warning "Could not read the Teams user list via Get-CsOnlineUser, so UserCount is reported as null rather than as 0 on every row. The policies themselves are still listed. Teams said: $($_.Exception.Message)"
    }

    # Get-CsOnlineUser returns guests and resource accounts alongside staff. They are counted,
    # not filtered: deciding which account "really" holds a policy is a judgement this command
    # should not make silently. -IncludeUser shows exactly who is behind a count.
    $totalUsers = if ($null -eq $users) { $null } else { $users.Count }

    foreach ($type in $PolicyType) {
        $spec = $areas[$type]

        $policies = $null
        try {
            $policies = @(& $spec.Cmdlet -ErrorAction Stop)
        }
        catch {
            $hint = if ($_.Exception.Message -match 'unauthor|forbidden|denied|privilege|access') {
                ' The likeliest cause is the missing DIRECTORY ROLE: app permissions alone are not enough for Teams, and the app also needs Teams Administrator, Teams Communications Administrator or Global Reader.'
            }
            else { '' }
            Write-Warning "Could not list $type policies via $($spec.Cmdlet), so they are NOT covered by this output.$hint Teams said: $($_.Exception.Message)"
            [PSCustomObject]@{
                PSTypeName     = 'MsecTeamsPolicyAssignment'
                PolicyType     = $type
                PolicyName     = 'Unreadable'
                IsGlobal       = $null
                UserCount      = $null
                PercentOfUsers = $null
                TotalUsers     = $totalUsers
            }
            continue
        }

        # Explicit assignments, by policy name. A null or empty property means the user was
        # never assigned anything and therefore gets Global - counted against Global below,
        # not dropped.
        $explicit = @{}
        $noAssignment = 0
        if ($null -ne $users) {
            foreach ($u in $users) {
                $raw = $u.($spec.UserProperty)
                # An assigned policy arrives as a UserPolicyDefinition carrying .Name;
                # older module versions hand back a plain string. Both are accepted.
                $name = if ($null -eq $raw) { '' }
                        elseif ($raw.PSObject.Properties.Name -contains 'Name') { [string] $raw.Name }
                        else { [string] $raw }

                if ([string]::IsNullOrWhiteSpace($name)) { $noAssignment++; continue }

                $name = $name -replace '^Tag:', ''
                if ($explicit.ContainsKey($name)) { $explicit[$name]++ } else { $explicit[$name] = 1 }
            }
        }

        if ($IncludeUser) {
            if ($null -eq $users) { continue }
            foreach ($u in $users) {
                $raw = $u.($spec.UserProperty)
                $name = if ($null -eq $raw) { '' }
                        elseif ($raw.PSObject.Properties.Name -contains 'Name') { [string] $raw.Name }
                        else { [string] $raw }
                if ([string]::IsNullOrWhiteSpace($name)) { continue }

                [PSCustomObject]@{
                    PSTypeName        = 'MsecTeamsPolicyAssignmentUser'
                    PolicyType        = $type
                    PolicyName        = ($name -replace '^Tag:', '')
                    UserPrincipalName = $u.UserPrincipalName
                    AccountType       = $u.AccountType
                }
            }
            continue
        }

        foreach ($policy in $policies) {
            $identity = [string] $policy.Identity
            if (-not $identity) { $identity = 'Global' }
            $display = $identity -replace '^Tag:', ''
            $isGlobal = ($display -eq 'Global')

            $count = if ($null -eq $users) { $null }
                     elseif ($isGlobal) {
                         # Everyone who was never assigned anything, plus anyone pinned to
                         # Global explicitly.
                         $noAssignment + $(if ($explicit.ContainsKey('Global')) { $explicit['Global'] } else { 0 })
                     }
                     else {
                         if ($explicit.ContainsKey($display)) { $explicit[$display] } else { 0 }
                     }

            [PSCustomObject]@{
                PSTypeName     = 'MsecTeamsPolicyAssignment'
                PolicyType     = $type
                PolicyName     = $display
                IsGlobal       = $isGlobal
                UserCount      = $count
                PercentOfUsers = if ($null -eq $count -or -not $totalUsers) { $null }
                                 else { [math]::Round(($count / $totalUsers) * 100, 2) }
                TotalUsers     = $totalUsers
            }
        }
    }
}
