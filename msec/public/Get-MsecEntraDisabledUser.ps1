function Get-MsecEntraDisabledUser {
    <#
    .SYNOPSIS
        Every disabled ("archived") user in the tenant, with how long each has been disabled
        where that is knowable, and what it is still costing in licences.

    .DESCRIPTION
        Lists users with accountEnabled = false, then works out when each was disabled.

        HOW LONG IS THE HARD PART, AND IT IS NOT ALWAYS ANSWERABLE
        ----------------------------------------------------------
        Entra stores no 'disabledDateTime'. A user object records when it was created and
        when it last signed in, but nothing about when somebody switched it off. The only
        record of the act is in the directory audit log - an 'Update user' event whose
        modifiedProperties show AccountEnabled going from [true] to [false].

        Those logs retain 30 days on Entra ID P1/P2 and 7 days on the free tier. So:

          * disabled recently  -> DisabledSince and DisabledDays are EXACT, and DisabledBy
                                  names who did it.
          * disabled long ago  -> the event has aged out. DisabledSince is $null, and the
                                  row instead carries a BRACKET: DisabledAtLeastDays (the
                                  window searched, since nothing was found inside it) and
                                  DisabledAtMostDays (days since the last SUCCESSFUL sign-in,
                                  because a disabled account cannot sign in successfully).

        The upper bound comes from signInActivity, which is a property Entra persists on the
        user object rather than a log query - so unlike DisabledSince it is NOT capped at the
        audit retention window and happily reaches back years. It does need Entra ID P1.

        It rests specifically on lastSuccessfulSignInDateTime, and the distinction matters:
        lastSignInDateTime records the last interactive ATTEMPT, and a disabled account still
        gets attempted - by an ex-employee, a stale client, a password spray. Computing the
        bound from an attempt would report "disabled at most 7 days" for an account switched
        off three years ago. Where no successful sign-in is recorded, DisabledAtMostDays is
        left blank rather than guessed.

        That bracket is the honest answer and is usually enough to act on - "between 30 and
        400 days" tells you it is long dead. A single invented number would not be.

        LICENCES ARE THE REASON THIS IS WORTH RUNNING. A disabled account still holding
        assigned licences is both spend and attack surface, so LicenseCount is projected and
        the examples sort by it.

        "LAST UPDATED" IS THREE DIFFERENT COLUMNS, BECAUSE IT IS THREE DIFFERENT QUESTIONS
        ----------------------------------------------------------------------------------
        Graph exposes no lastModifiedDateTime on a user, so there is no single answer. What
        exists is:

          LastDirectoryChange  newest audit event against the object, plus
          (+ ...What)          LastDirectoryChangeWhat naming which properties moved. The
                               closest thing to "last edited", and bounded by the same audit
                               retention as DisabledSince - so $null here means "nothing in
                               the last -Days days", NOT "never touched".

          LastPasswordChange   unbounded and always present, straight off the user object.
                               On a disabled account this is usually the best marker of when
                               it was genuinely last in use.

          OnPremisesLastSync   synced accounts only. Worth watching for the case where sync
                               is still enabled but this stopped advancing: the on-premises
                               source object is gone and what is left in Entra is an orphan
                               nothing will ever update or clean up again.

    .PARAMETER Days
        How far back to search the audit log for the disable event. Default 30, which is the
        P1/P2 retention ceiling - asking for more cannot find more, it just takes longer. Drop
        to 7 on a free-tier tenant.

    .PARAMETER UserType
        'Member', 'Guest' or 'All'. Default All. Disabled guests are worth separating: a guest
        left disabled is usually a finished engagement nobody cleaned up.

    .PARAMETER ExcludeSignInActivity
        Skip the last-sign-in lookup. That property is what makes DisabledAtMostDays possible,
        so skipping it leaves the upper half of the bracket blank - but it is premium-only, and
        on a tenant without Entra ID P1 it costs a round trip to learn nothing.

    .EXAMPLE
        Get-MsecEntraDisabledUser | Where-Object LicenseCount -gt 0 |
            Sort-Object LicenseCount -Descending |
            Format-Table UserPrincipalName, LicenseCount, DisabledDays, DisabledAtLeastDays

        Disabled accounts still consuming licences, worst first.

    .EXAMPLE
        # Who has been switched off in the last week, and by whom.
        Get-MsecEntraDisabledUser -Days 7 | Where-Object DisabledSince |
            Sort-Object DisabledSince -Descending |
            Format-Table UserPrincipalName, DisabledSince, DisabledBy

    .EXAMPLE
        # Long-dead accounts: nothing in the audit window, and no sign-in for over a year.
        Get-MsecEntraDisabledUser |
            Where-Object { -not $_.DisabledSince -and $_.DisabledAtMostDays -gt 365 }

    .OUTPUTS
        PSCustomObject per disabled user, PSTypeName 'MsecEntraDisabledUser'.

    .NOTES
        Needs User.Read.All and AuditLog.Read.All, both of which New-MsecApp already grants -
        no re-run required.

        DisabledSince comes from the audit log, so it reflects the last time the account was
        disabled. An account switched off, back on, and off again reports the most recent
        event, which is the one you want.

        On-premises-synced accounts (OnPremisesSyncEnabled) are disabled in Active Directory
        and the state syncs down. The audit event still appears, attributed to the sync
        account rather than to a person, so DisabledBy will name the directory synchronisation
        service - that is correct, not a lookup failure.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateRange(1, 30)]
        [int] $Days = 30,

        [ValidateSet('Member', 'Guest', 'All')]
        [string] $UserType = 'All',

        [switch] $ExcludeSignInActivity
    )

    Assert-MsecSession

    $now = [DateTime]::UtcNow

    # ---- the disabled users -----------------------------------------------------------------

    $select = @(
        'id', 'displayName', 'userPrincipalName', 'userType', 'accountEnabled'
        'createdDateTime', 'onPremisesSyncEnabled', 'onPremisesLastSyncDateTime'
        'lastPasswordChangeDateTime', 'department', 'jobTitle'
        'assignedLicenses'
    )

    $filter = 'accountEnabled eq false'
    if ($UserType -ne 'All') { $filter += " and userType eq '$UserType'" }

    # signInActivity is a premium property and is rejected outright on some tenants rather
    # than returned null, so it is requested separately and the whole call retried without it.
    # Losing the last-sign-in column is a smaller loss than losing the list.
    $withActivity = -not $ExcludeSignInActivity
    $users = $null

    foreach ($attempt in 1, 2) {
        $fields = if ($withActivity) { $select + 'signInActivity' } else { $select }
        $path = "/v1.0/users?`$filter=$([uri]::EscapeDataString($filter))&`$select=$($fields -join ',')&`$top=999"

        try {
            $users = @(Invoke-MsecGraphRequest -Path $path -All)
            break
        }
        catch {
            $detail = Get-MsecGraphErrorMessage -ErrorRecord $_
            if ($withActivity -and $attempt -eq 1) {
                Write-Warning "Could not read signInActivity (usually means no Entra ID P1 on this tenant); retrying without it, so DisabledAtMostDays will be blank. Graph said: $detail"
                $withActivity = $false
                continue
            }
            throw "Could not list disabled users: $detail"
        }
    }

    if (-not $users.Count) {
        Write-Verbose 'No disabled users found.'
        return
    }

    # ---- when was each one disabled ----------------------------------------------------------

    # Filtered server-side to 'Update user', which is what switching accountEnabled off
    # produces and is a small fraction of all audit traffic. The AccountEnabled test itself
    # has to happen client-side: modifiedProperties is a nested collection and Graph will not
    # filter inside it.
    $cutoff = $now.AddDays(-$Days).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $auditFilter = "activityDateTime ge $cutoff and activityDisplayName eq 'Update user'"

    $disabledAt  = @{}
    $lastUpdated = @{}
    try {
        $events = @(Invoke-MsecGraphRequest -All `
            -Path "/v1.0/auditLogs/directoryAudits?`$filter=$([uri]::EscapeDataString($auditFilter))")

        foreach ($event in $events) {
            foreach ($target in @($event.targetResources)) {
                if (-not $target.id) { continue }

                $when = [datetime] $event.activityDateTime

                # Newest change of ANY kind, recorded before the AccountEnabled test below -
                # a department move or a licence change is still the object being touched,
                # and this comes free from events already fetched.
                if (-not $lastUpdated.ContainsKey($target.id) -or $when -gt $lastUpdated[$target.id].When) {
                    $lastUpdated[$target.id] = [pscustomobject]@{
                        When = $when
                        What = (@($target.modifiedProperties) | ForEach-Object { $_.displayName } |
                                    Where-Object { $_ } | Select-Object -Unique) -join ', '
                    }
                }

                # Values arrive as JSON-ish text - '[true]' / '[false]' - not as booleans.
                $turnedOff = @($target.modifiedProperties) | Where-Object {
                    $_.displayName -eq 'AccountEnabled' -and $_.newValue -match 'false'
                }
                if (-not $turnedOff) { continue }

                # Keep the MOST RECENT event per user: an account disabled, re-enabled and
                # disabled again should report the disable that is currently in force.
                if (-not $disabledAt.ContainsKey($target.id) -or $when -gt $disabledAt[$target.id].When) {
                    $disabledAt[$target.id] = [pscustomobject]@{
                        When = $when
                        By   = $event.initiatedBy.user.userPrincipalName ??
                               $event.initiatedBy.app.displayName ??
                               $event.initiatedBy.user.displayName
                    }
                }
            }
        }
    }
    catch {
        # An audit-log failure costs the timestamps, not the list. Every row still says the
        # user is disabled; only the "how long" columns go blank, and the warning says why.
        Write-Warning "Could not read the directory audit log, so no disable dates are available this run (the user list is unaffected). Graph said: $(Get-MsecGraphErrorMessage -ErrorRecord $_)"
    }

    # ---- project ------------------------------------------------------------------------------

    foreach ($user in $users) {
        $event = $disabledAt[$user.id]

        # signInActivity carries several timestamps and they do NOT mean the same thing.
        $activity = $user.signInActivity
        $asDate = { param($v) if ($v) { [datetime] $v } else { $null } }

        $lastSuccessful     = & $asDate $activity.lastSuccessfulSignInDateTime
        $lastInteractive    = & $asDate $activity.lastSignInDateTime
        $lastNonInteractive = & $asDate $activity.lastNonInteractiveSignInDateTime

        # "Last seen" for the reader: the newest of any kind.
        $lastSignIn = @($lastInteractive, $lastNonInteractive, $lastSuccessful) |
            Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1

        # The bracket for a user whose disable event has aged out of the log:
        #   at least - nothing was found in the window searched, so it happened before that.
        #   at most  - an account cannot sign in successfully after being disabled, so the
        #              last sign-in is the earliest the disable can have happened.
        # The upper bound rests on one fact: a disabled account cannot sign in SUCCESSFULLY.
        # So it must come from lastSuccessfulSignInDateTime and from nothing else.
        #
        # lastSignInDateTime is the tempting substitute and it is wrong for this. It records
        # the last interactive sign-in ATTEMPT, and a disabled account still gets attempted -
        # by the ex-employee, by a stale client, by a password spray. One attempt last week
        # against an account switched off three years ago would compute "disabled at most 7
        # days", which is not merely imprecise but confidently backwards. Better to leave the
        # bound blank and say so.
        $atLeast = $null
        $atMost  = $null
        if (-not $event) {
            $atLeast = $Days
            if ($lastSuccessful) { $atMost = [int] ($now - $lastSuccessful).TotalDays }
        }

        [pscustomobject]@{
            PSTypeName            = 'MsecEntraDisabledUser'
            DisplayName           = $user.displayName
            UserPrincipalName     = $user.userPrincipalName
            UserType              = $user.userType
            Department            = $user.department
            JobTitle              = $user.jobTitle

            DisabledSince         = $event.When
            DisabledDays          = $(if ($event) { [int] ($now - $event.When).TotalDays } else { $null })
            DisabledBy            = $event.By
            DisabledAtLeastDays   = $atLeast
            DisabledAtMostDays    = $atMost
            # 'AuditLog' = exact. 'Beyond audit retention' = the bracket columns are the
            # answer. Named rather than left to be inferred from a null.
            DisabledSource        = $(if ($event) { 'AuditLog' } else { "Beyond audit retention ($Days d)" })

            # A disabled account holding licences is spend and attack surface both.
            LicenseCount          = @($user.assignedLicenses).Count

            # LastSignIn is the newest of any kind - what you want for "when was this last
            # seen". The three underneath are kept because they answer different questions:
            # LastSuccessfulSignIn is the only one that proves the account WORKED (and so the
            # only one DisabledAtMostDays can rest on); LastInteractiveSignIn may be a failed
            # attempt; LastNonInteractiveSignIn is how a service account looks alive while
            # showing nothing interactive for years.
            LastSignIn               = $lastSignIn
            LastSuccessfulSignIn     = $lastSuccessful
            LastInteractiveSignIn    = $lastInteractive
            LastNonInteractiveSignIn = $lastNonInteractive

            # ---- three separate answers to "when was this last touched" ----
            # Graph has no lastModifiedDateTime on a user, so there is no single one. These
            # are the three real signals, and they mean different things:
            #
            #   LastDirectoryChange - newest audit event against the object, and the closest
            #                         thing to "last edited". Bounded by audit retention, so
            #                         $null means "not in the last $Days days", NOT "never".
            #   LastPasswordChange  - unbounded and always present. On a disabled account it
            #                         is usually the last time the account was really in use.
            #   OnPremisesLastSync  - synced accounts only. If this has stopped advancing
            #                         while sync is still enabled, the object is orphaned in
            #                         Entra and the on-prem source is gone.
            LastDirectoryChange   = $lastUpdated[$user.id].When
            LastDirectoryChangeWhat = $lastUpdated[$user.id].What
            LastPasswordChange    = $(if ($user.lastPasswordChangeDateTime) { [datetime] $user.lastPasswordChangeDateTime } else { $null })
            OnPremisesLastSync    = $(if ($user.onPremisesLastSyncDateTime) { [datetime] $user.onPremisesLastSyncDateTime } else { $null })

            OnPremisesSyncEnabled = $user.onPremisesSyncEnabled
            CreatedDateTime       = $(if ($user.createdDateTime) { [datetime] $user.createdDateTime } else { $null })
            Id                    = $user.id
            Raw                   = $user
        }
    }
}
