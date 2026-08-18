function Get-MsecEntraMfaEvidence {
    <#
    .SYNOPSIS
        Per-user MFA evidence for an access review or audit: whether MFA was actually
        demanded and met at sign-in, whether the user is excluded from the policies that
        demand it, and where neither can be shown.

    .DESCRIPTION
        Answers the question an auditor asks - "show me that MFA is enforced for your
        users" - which none of the individual reports can answer alone:

          Get-MsecEntraMfaRegistration     proves CAPABILITY. A user can be fully
                                           capable and never once be challenged.
          Get-MsecEntraConditionalAccessPolicy
                                           proves a policy EXISTS. It does not show who
                                           slips through its exclusions.
          Get-MsecEntraConditionalAccessSignInLog
                                           proves what HAPPENED, but only for users who
                                           signed in during the window.

        This joins all three into one row per user and assigns each user an
        EvidenceStatus - the four buckets an audit response has to account for:

          MfaSatisfied         An interactive sign-in in the window had a Conditional
                               Access policy demand MFA, and it was met. This is
                               evidence of the control OPERATING, which is what an
                               auditor wants over a screenshot of a policy.
          SingleFactorObserved An interactive sign-in SUCCEEDED with no MFA-requiring
                               policy applied. The finding: somebody got in on one
                               factor. See SingleFactorApps / SingleFactorClientApps /
                               SingleFactorLegacyAuth to triage it.
          NoSuccessfulSignIn   Interactive sign-ins were attempted but none succeeded -
                               rejected at the password, or challenged for MFA and
                               failed. Nothing is evidenced either way, and a failed
                               MFA challenge is the control WORKING, not a bypass.
          NoSignInInWindow     No interactive sign-in at all. NOT a pass: the fallback
                               statement is capability plus policy scope, and dormant
                               privileged accounts live here.
          NoEvidenceAvailable  Sign-in data could not be read at all (see the warning).

        ExcludedFromMfaPolicies is reported separately from EvidenceStatus rather than
        folded into it, because the two are orthogonal: a user can be excluded from the
        tenant-wide policy and still have satisfied MFA via another one. An exclusion is
        a finding in its own right - a stale break-glass group is the classic audit
        observation - so it must not be hidden behind a passing status.

        WHAT THIS CANNOT PROVE. Policy scope is INFERRED, not evaluated. Only policies
        that are enabled, require MFA, and include all users are treated as tenant-wide;
        their user, group and role exclusions are resolved and applied per user. Policies
        with narrower conditions - specific apps, platforms, locations, risk levels, or
        an include list rather than 'All' - are reported in OtherMfaPolicies and their
        scope is NOT computed, because doing that properly means reimplementing
        Conditional Access. Graph's CA What-If evaluation API is the only authoritative
        answer; until this uses it, treat inferred scope as a strong indicator and the
        sign-in evidence as the proof.

        Requires everything the three underlying commands require: 'AuditLog.Read.All',
        'Policy.Read.All', 'User.Read.All', 'Group.Read.All', plus Entra ID P1/P2 for the
        registration report and sign-in logs. Role-based exclusions additionally read
        role assignments ('RoleManagement.Read.Directory').

    .PARAMETER Days
        Size of the evidence window in days, 1-30 (Graph's sign-in log retention limit
        on this endpoint). Default 30. State this window in the audit response: the
        evidence is only as good as the period it covers.

        COST. For 40 or fewer users the sign-in log is fetched with a server-side userId
        filter, which is fast. Above that it pages every sign-in in the window for the
        whole tenant - tens of thousands of events per day on a real tenant, so a
        30-day tenant-wide run takes minutes. -AdminsOnly is usually both the question
        being asked and the fast path. Progress is reported throughout; note that piping
        into Group-Object buffers everything, so no rows appear until it finishes.

    .PARAMETER AdminsOnly
        Restrict to users Graph flags as holding a privileged role. The population an
        auditor asks about first, and small enough to read row by row.

    .PARAMETER IncludeGuests
        Include guest users. Off by default: guests authenticate against their home
        tenant, so this tenant's policies and their MFA registration state are not the
        whole story for them, and mixing them into a coverage percentage misleads.

    .EXAMPLE
        # Start here: the administrators, which is the fast path and the question an
        # auditor asks first. Capture the rows once, then slice them - a tenant-wide
        # run is minutes of paging and should not be repeated per question.
        $evidence = Get-MsecEntraMfaEvidence -AdminsOnly
        $evidence | Group-Object EvidenceStatus -NoElement

    .EXAMPLE
        # The headline for the whole tenant. Slow - it pages every sign-in in the window
        # - and Group-Object shows nothing until it finishes, so run it with -Verbose the
        # first time to watch the phases.
        Get-MsecEntraMfaEvidence -Verbose | Group-Object EvidenceStatus -NoElement

    .EXAMPLE
        # The findings list. Anything here needs a sentence in the response.
        Get-MsecEntraMfaEvidence |
            Where-Object { $_.EvidenceStatus -eq 'SingleFactorObserved' -or $_.ExcludedFromMfaPolicies } |
            Format-Table UserPrincipalName, EvidenceStatus, ExcludedFromMfaPolicies

    .EXAMPLE
        # Administrators, row by row - the evidence table to attach.
        Get-MsecEntraMfaEvidence -AdminsOnly |
            Format-Table UserPrincipalName, EvidenceStatus, MfaSatisfiedSignIns,
                         SingleFactorSignIns, LastMfaSatisfiedUtc, DefaultMfaMethod

    .EXAMPLE
        # Triage the single-factor findings without leaving the evidence rows: what was
        # reached, with which client, and when. Legacy auth is the row to read first.
        Get-MsecEntraMfaEvidence -AdminsOnly |
            Where-Object EvidenceStatus -eq 'SingleFactorObserved' |
            Format-Table UserPrincipalName, SingleFactorSignIns, SingleFactorLegacyAuth,
                         @{ n = 'Clients'; e = { $_.SingleFactorClientApps -join ', ' } },
                         @{ n = 'Apps';    e = { $_.SingleFactorApps -join ', ' } }

    .EXAMPLE
        # The accounts that cannot be evidenced empirically - dormant or service-like.
        # An unused admin account with no MFA is the finding auditors look for.
        Get-MsecEntraMfaEvidence -AdminsOnly |
            Where-Object EvidenceStatus -eq 'NoSignInInWindow' |
            Format-Table UserPrincipalName, IsMfaCapable, InScopeOfMfaPolicies

    .OUTPUTS
        PSCustomObject per user. See .NOTES for the projection.

    .NOTES
        Each row is a [PSCustomObject] with PSTypeName 'MsecEntraMfaEvidence', whose
        DefaultDisplayPropertySet (UserPrincipalName, EvidenceStatus, IsMfaCapable,
        DefaultMfaMethod, IsAdmin) is registered in msec.psm1.

        Projection:
          UserPrincipalName, UserId, DisplayName, UserType, IsAdmin
          IsMfaCapable, IsMfaRegistered, DefaultMfaMethod   from the registration report
          EvidenceStatus              one of the four buckets above
          InteractiveSignIns          count in the window
          MfaSatisfiedSignIns         interactive sign-ins where a policy demanded MFA
                                      and it was met
          SingleFactorSignIns         SUCCESSFUL interactive sign-ins where no
                                      MFA-requiring policy applied. Failed sign-ins are
                                      excluded: a rejected password is not access
          SingleFactorApps            distinct resources reached that way
          SingleFactorClientApps      distinct clients used - 'Browser' and
                                      'Mobile Apps and Desktop clients' are modern auth;
                                      ActiveSync / IMAP / POP / SMTP / MAPI /
                                      'Other clients' are LEGACY, which Conditional
                                      Access cannot challenge, only block
          SingleFactorLegacyAuth      how many of them used a legacy client
          LastSingleFactorUtc         most recent one, for the investigation timeline
          LastMfaSatisfiedUtc         most recent satisfied sign-in, or $null
          EnforcingPolicies           policy names observed demanding MFA of this user
          InScopeOfMfaPolicies        tenant-wide MFA policies this user is NOT excluded
                                      from (inferred - see the caveat above)
          ExcludedFromMfaPolicies     tenant-wide MFA policies that exclude this user,
                                      with the reason: 'name (user)', 'name (group X)',
                                      'name (role Y)'
          OtherMfaPolicies            enabled MFA policies whose scope was not computed
          WindowDays, WindowStartUtc  the evidence period, for the audit response

        MFA satisfaction is read from appliedConditionalAccessPolicies on each sign-in,
        not from a per-sign-in MFA field: the v1.0 signIn resource has no
        authenticationRequirement or mfaDetail property. Only INTERACTIVE sign-ins are
        counted - non-interactive ones are token refreshes and service calls that
        legitimately never prompt, and counting them would make every tenant look
        uncovered.

        A user with zero interactive sign-ins is NoSignInInWindow, never a pass. Reading
        that as compliant is the most common way this kind of report misleads.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(1, 30)]
        [int] $Days = 30,

        [Parameter()]
        [switch] $AdminsOnly,

        [Parameter()]
        [switch] $IncludeGuests
    )

    Assert-MsecSession

    $windowStart = (Get-Date).ToUniversalTime().AddDays(-$Days)

    # This command joins three separate reports, one of which pages the tenant's whole
    # sign-in log. That is slow enough that silence reads as a hang - and because callers
    # usually pipe into Group-Object, which buffers everything, nothing at all appears
    # until the last row is built. So every phase announces itself.
    $progress = @{ Activity = 'Collecting MFA evidence' }
    Write-Progress @progress -Status 'Reading authentication-method registration' -PercentComplete 5

    # ---- Population: every user and whether they COULD do MFA ---------------------
    # This is the denominator. Sign-in logs cannot provide it - a user who never signed
    # in has no events, and would silently vanish from a log-only report.
    $users = @(Get-MsecEntraMfaRegistration)
    if (-not $IncludeGuests) { $users = @($users | Where-Object { $_.UserType -ne 'guest' }) }
    if ($AdminsOnly)         { $users = @($users | Where-Object IsAdmin) }

    if (-not $users.Count) {
        Write-Progress @progress -Completed
        Write-Warning 'No users matched, so there is nothing to evidence. With -AdminsOnly this means Graph reported no privileged users, which is itself worth checking.'
        return
    }
    Write-Verbose "$($users.Count) user(s) in the evidence population."

    # ---- Configuration: which policies demand MFA, and who escapes them -----------
    Write-Progress @progress -Status 'Reading Conditional Access policies' -PercentComplete 20
    $policies = @(Get-MsecEntraConditionalAccessPolicy)

    $mfaPolicies = @($policies | Where-Object {
        $_.State -eq 'enabled' -and @($_.Requires) -contains 'mfa'
    })

    # 'All' on the include side is what makes a policy tenant-wide, and only those can
    # support an "all users" claim. Anything narrower needs real CA evaluation.
    $tenantWide = @($mfaPolicies | Where-Object { @($_.IncludedUsers) -contains 'All' })
    $otherMfaPolicies = @($mfaPolicies | Where-Object { @($_.IncludedUsers) -notcontains 'All' } |
        ForEach-Object { $_.DisplayName })

    if (-not $mfaPolicies.Count) {
        Write-Warning "No ENABLED Conditional Access policy requires MFA in this tenant. That is the finding, not a gap in this report - check Get-MsecEntraTenantSecuritySetting for security defaults, which enforce MFA without appearing as a CA policy."
    }
    elseif (-not $tenantWide.Count) {
        Write-Warning "$($mfaPolicies.Count) enabled policy/policies require MFA, but none includes ALL users, so no tenant-wide claim can be inferred from configuration. Their names are in OtherMfaPolicies and their scope is NOT computed; the sign-in evidence below is what stands."
    }

    # Resolve each tenant-wide policy's exclusions to user ids, once per policy. Group
    # and role exclusions are where users actually escape a policy, and both are
    # indirections that a policy listing shows only as GUIDs.
    $exclusionsByPolicy = @{}
    $roleHolderCache = $null

    foreach ($p in $tenantWide) {
        $excludedUserIds = @{}

        foreach ($u in @($p.ExcludedUsers)) {
            if ($u -and $u -ne 'None') { $excludedUserIds[[string]$u] = 'user' }
        }

        foreach ($g in @($p.ExcludedGroups)) {
            if (-not $g) { continue }
            try {
                $members = @(Invoke-MsecGraphRequest -All `
                    -Path "/v1.0/groups/$g/transitiveMembers/microsoft.graph.user?`$select=id")
                foreach ($m in $members) { $excludedUserIds[[string]$m.id] = "group $g" }
            }
            catch {
                Write-Warning "Could not expand exclusion group '$g' on policy '$($p.DisplayName)' - anyone inside it will be reported as IN SCOPE when they are actually EXCLUDED, which overstates coverage. Graph said: $(Get-MsecGraphErrorMessage $_)"
            }
        }

        $excludedRoles = @(@($p.ExcludedRoles) | Where-Object { $_ })
        if ($excludedRoles.Count) {
            # Only pay for the role inventory if some policy actually excludes a role.
            # A role-based exclusion can quietly remove every Global Administrator from
            # an MFA policy, so this must not be skipped when present.
            if ($null -eq $roleHolderCache) {
                try {
                    $roleHolderCache = @(Get-MsecEntraPrivilegedPrincipal -ErrorAction Stop)
                }
                catch {
                    $roleHolderCache = @()
                    Write-Warning "A tenant-wide MFA policy excludes directory roles, but role assignments could not be read, so role-based exclusions are NOT applied and coverage is overstated. Graph said: $($_.Exception.Message)"
                }
            }
            foreach ($roleId in $excludedRoles) {
                foreach ($holder in @($roleHolderCache | Where-Object RoleTemplateId -eq $roleId)) {
                    if ($holder.EffectiveId) { $excludedUserIds[[string]$holder.EffectiveId] = "role $roleId" }
                }
            }
        }

        $exclusionsByPolicy[$p.DisplayName] = $excludedUserIds
    }

    # ---- Operation: what actually happened at sign-in ------------------------------
    # The expensive phase by far. For a small population Graph can filter server-side on
    # userId, which turns "page every sign-in in the tenant for 30 days" into a handful
    # of scoped queries; past that the per-user filter batching costs more requests than
    # one unfiltered sweep, so the sweep wins.
    $targeted = $users.Count -le 40
    $signInParams = @{ Days = $Days }
    if ($targeted) { $signInParams['UserId'] = @($users.UserId | Where-Object { $_ }) }

    Write-Progress @progress -PercentComplete 40 -Status $(
        if ($targeted) { "Reading $Days days of sign-ins for $($users.Count) user(s)" }
        else { "Reading $Days days of sign-ins for the whole tenant - this is the slow part" }
    )
    if (-not $targeted) {
        Write-Verbose "$($users.Count) users is above the targeted-query threshold, so the full $Days-day sign-in log is being paged. -AdminsOnly makes this dramatically faster."
    }

    $signInsByUser = @{}
    $signInDataAvailable = $true
    $interactiveCount = 0
    try {
        foreach ($s in (Get-MsecEntraConditionalAccessSignInLog @signInParams)) {
            # Only interactive sign-ins can evidence a prompt. Token refreshes and
            # service-to-service calls never prompt, and treating them as single-factor
            # would manufacture findings in every tenant.
            if (-not $s.IsInteractive) { continue }
            $key = [string]$s.UserId
            if (-not $key) { continue }
            if (-not $signInsByUser.ContainsKey($key)) {
                $signInsByUser[$key] = [System.Collections.Generic.List[object]]::new()
            }
            $signInsByUser[$key].Add($s)
            $interactiveCount++
        }
        Write-Verbose "$interactiveCount interactive sign-in(s) across $($signInsByUser.Count) user(s) in the window."
        if ($interactiveCount -eq 0) {
            Write-Warning "No INTERACTIVE sign-ins were found in the last $Days day(s), so no user can be evidenced empirically and every row will read 'NoSignInInWindow'. On a tenant with real activity that points at the query rather than the tenant - check that sign-in logs are readable and that the window is long enough."
        }
    }
    catch {
        $signInDataAvailable = $false
        Write-Warning "Sign-in logs could not be read, so NO user can be evidenced empirically and every row is 'NoEvidenceAvailable'. Capability and policy scope are still reported, but neither shows the control operating. Original error: $($_.Exception.Message)"
    }

    # ---- Join ----------------------------------------------------------------------
    Write-Progress @progress -Status 'Joining evidence' -PercentComplete 90
    Write-Progress @progress -Completed

    foreach ($u in $users) {
        $userId = [string]$u.UserId

        $inScope = [System.Collections.Generic.List[string]]::new()
        $excluded = [System.Collections.Generic.List[string]]::new()
        foreach ($policyName in $exclusionsByPolicy.Keys) {
            $reason = $exclusionsByPolicy[$policyName][$userId]
            if ($reason) { $excluded.Add("$policyName ($reason)") } else { $inScope.Add($policyName) }
        }

        $mine = if ($signInsByUser.ContainsKey($userId)) { @($signInsByUser[$userId]) } else { @() }
        $satisfied = @($mine | Where-Object MfaSatisfied)

        # A single-factor row is a claim that somebody GOT IN on one factor, so all
        # three of these have to hold:
        #   no MFA-requiring policy succeeded  - otherwise MFA was met
        #   no MFA-requiring policy failed     - a failed challenge is the control
        #                                        working, not a bypass
        #   the sign-in carries no error code  - a rejected password proves nothing, and
        #                                        counting it turns every mistyped
        #                                        credential into an audit finding
        #
        # The last test is "no error code" rather than "error code is 0" on purpose. Both
        # $null and 0 mean nothing went wrong, and requiring a literal 0 would silently
        # drop a finding if the field were ever absent - understating findings is the one
        # direction a security report must not fail in quietly.
        $singleFactor = @($mine | Where-Object {
            -not $_.MfaSatisfied -and -not $_.MfaFailed -and -not $_.ResultCode
        })

        # Each status means exactly one thing. There is deliberately no catch-all: a
        # user whose only sign-ins FAILED - at the password or at an MFA challenge -
        # belongs in neither of the evidence buckets, and lumping them under
        # SingleFactorObserved would report a blocked sign-in as a bypass.
        $status = if (-not $signInDataAvailable) { 'NoEvidenceAvailable' }
                  elseif ($satisfied.Count)      { 'MfaSatisfied' }
                  elseif ($singleFactor.Count)   { 'SingleFactorObserved' }
                  elseif ($mine.Count)           { 'NoSuccessfulSignIn' }
                  else                           { 'NoSignInInWindow' }

        $lastSatisfied = if ($satisfied.Count) {
            ($satisfied | Sort-Object CreatedDateTime -Descending)[0].CreatedDateTime
        } else { $null }

        [PSCustomObject]@{
            PSTypeName              = 'MsecEntraMfaEvidence'

            UserPrincipalName       = $u.UserPrincipalName
            UserId                  = $u.UserId
            DisplayName             = $u.DisplayName
            UserType                = $u.UserType
            IsAdmin                 = $u.IsAdmin

            EvidenceStatus          = $status

            IsMfaCapable            = $u.IsMfaCapable
            IsMfaRegistered         = $u.IsMfaRegistered
            DefaultMfaMethod        = $u.DefaultMfaMethod

            InteractiveSignIns      = $mine.Count
            MfaSatisfiedSignIns     = $satisfied.Count
            SingleFactorSignIns     = $singleFactor.Count
            LastMfaSatisfiedUtc     = $lastSatisfied
            EnforcingPolicies       = @($satisfied.MfaRequiredByPolicies | Sort-Object -Unique)

            # The first questions asked of a single-factor finding: what did they reach,
            # and how. A legacy client here is the serious answer - Conditional Access
            # cannot challenge basic authentication, only block it, so an MFA policy is
            # simply not in the path.
            SingleFactorApps        = @($singleFactor.AppDisplayName | Where-Object { $_ } | Sort-Object -Unique)
            SingleFactorClientApps  = @($singleFactor.ClientAppUsed  | Where-Object { $_ } | Sort-Object -Unique)
            SingleFactorLegacyAuth  = @($singleFactor | Where-Object {
                                          $_.ClientAppUsed -match 'ActiveSync|IMAP|POP|SMTP|MAPI|Other clients'
                                      }).Count
            LastSingleFactorUtc     = if ($singleFactor.Count) {
                                          ($singleFactor | Sort-Object CreatedDateTime -Descending)[0].CreatedDateTime
                                      } else { $null }

            InScopeOfMfaPolicies    = @($inScope)
            ExcludedFromMfaPolicies = @($excluded)
            OtherMfaPolicies        = @($otherMfaPolicies)

            WindowDays              = $Days
            WindowStartUtc          = $windowStart
        }
    }
}
