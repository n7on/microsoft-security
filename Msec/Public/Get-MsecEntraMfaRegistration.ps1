function Get-MsecEntraMfaRegistration {
    <#
    .SYNOPSIS
        Per-user authentication-method registration state as flat rows - who can actually
        do MFA, with which methods, and who is an admin.

    .DESCRIPTION
        Calls Microsoft Graph /v1.0/reports/authenticationMethods/userRegistrationDetails,
        the data behind the Entra "Authentication methods - registration" report, and
        projects one row per user.

        This answers the question a Conditional Access policy cannot: CA proves MFA is
        *demanded*, this proves it is *possessed*. A tenant can have a flawless Require-MFA
        policy and still hold admin accounts with nothing registered, which surfaces only
        as a lockout or a bypass later.

        WHAT THIS DOES NOT TELL YOU. Registration is capability, not enforcement. A user
        can be IsMfaCapable and never once be challenged. "Is MFA actually required for
        this person" is a different question with three independent sources:

          Security defaults      tenant-wide on/off - Get-MsecEntraTenantSecuritySetting
          Conditional Access     per-policy conditions - Get-MsecEntraConditionalAccessPolicy
                                 lists the policies, but does NOT evaluate which apply to
                                 a given user; that needs the CA What-If evaluation API
          Legacy per-user MFA    the pre-CA Enabled/Enforced/Disabled flag, which sits
                                 OUTSIDE Conditional Access entirely - an 'enforced' user
                                 is challenged whatever CA says - and is invisible in
                                 every other report here. -IncludePerUserMfaState reads it

        And the empirical answer - did they actually perform MFA - is in the sign-in
        logs, via Get-MsecEntraConditionalAccessSignInLog. When the three configuration
        sources disagree with the logs, the logs are right.

        IsMfaRegistered vs IsMfaCapable - the distinction that matters:
          IsMfaRegistered  the user has registered at least one MFA method.
          IsMfaCapable     the user has registered a method AND that method is enabled by
                           the tenant's authentication-methods policy, i.e. it will
                           actually work.
        Registered-but-not-capable means someone registered a method the tenant has since
        disabled. **Use IsMfaCapable for coverage reporting** - it is the honest number.

        THE DEFAULT METHOD IS NOT ONE FIELD. Entra stores the user's own choice
        (UserPreferredMfaMethod) and its own computed choice (SystemPreferredMfaMethods)
        side by side, and a tenant-level toggle (IsSystemPreferredMfaEnabled) decides
        which is used at sign-in: with system-preferred on, Entra picks the most secure
        registered method and the user's preference is ignored. DefaultMfaMethod
        resolves that - it is the method a sign-in would actually prompt for - and all
        three inputs stay on the row so the derivation can be checked.

        Method strength is the point of reading it: 'sms' and the 'voice*' values are
        phishable and interceptable, 'push' and 'oath' materially less so. A tenant
        whose administrators default to SMS has MFA in name.

        Requires the 'AuditLog.Read.All' application permission AND Microsoft Entra ID P1
        or P2 on the tenant: this report is premium-gated independently of permissions. A
        403 is re-thrown with Graph's own message, distinguishing the two causes, because a
        licensing 403 cannot be fixed by granting a permission.

    .PARAMETER IncludePerUserMfaState
        Also read each user's LEGACY per-user MFA state ('enabled', 'enforced',
        'disabled') into PerUserMfaState. Off by default because there is no bulk
        endpoint: this costs ONE Graph call per user, and it uses the BETA endpoint
        /beta/users/{id}/authentication/requirements, which Microsoft does not support
        for production use. Needs 'Policy.Read.All', which the msec app already has.

        Filter before asking for it - piping only the admins through is the difference
        between a dozen calls and several thousand.

    .EXAMPLE
        Get-MsecEntraMfaRegistration | Where-Object { $_.IsAdmin -and -not $_.IsMfaCapable }

    .EXAMPLE
        # Method mix - how much of the estate rests on phishable phone-based MFA?
        Get-MsecEntraMfaRegistration |
            Select-Object -ExpandProperty MethodsRegistered |
            Group-Object | Sort-Object Count -Descending

    .EXAMPLE
        Get-MsecEntraMfaRegistration | Group-Object UserType, IsMfaCapable -NoElement

    .EXAMPLE
        # Administrators whose second factor is phishable - SMS or a voice call to a
        # phone number. This is the row an attacker with a SIM swap is looking for.
        Get-MsecEntraMfaRegistration |
            Where-Object { $_.IsAdmin -and $_.DefaultMfaMethod -match '^(sms|voice)' } |
            Format-Table UserPrincipalName, DefaultMfaMethod, MethodsRegistered

    .EXAMPLE
        # Where the tenant's defaults actually come from: with system-preferred
        # authentication off, every user's own choice stands unreviewed.
        Get-MsecEntraMfaRegistration |
            Group-Object IsSystemPreferredMfaEnabled, DefaultMfaMethod -NoElement

    .EXAMPLE
        # Legacy per-user MFA across the whole tenant. 'enabled' and 'enforced' predate
        # Conditional Access and override nothing - they simply also apply - so a tenant
        # that thinks it moved to CA years ago can still be running on these.
        Get-MsecEntraMfaRegistration -IncludePerUserMfaState |
            Group-Object PerUserMfaState -NoElement

    .EXAMPLE
        # Capability and enforcement together, for administrators only - the population
        # small enough to pay one Graph call each for.
        Get-MsecEntraMfaRegistration -IncludePerUserMfaState |
            Where-Object IsAdmin |
            Format-Table UserPrincipalName, IsMfaCapable, DefaultMfaMethod, PerUserMfaState

    .OUTPUTS
        PSCustomObject per user. See .NOTES for the projection.

    .NOTES
        Each row is a [PSCustomObject] with PSTypeName 'MsecEntraMfaRegistration', whose
        DefaultDisplayPropertySet (UserPrincipalName, IsAdmin, IsMfaCapable,
        DefaultMfaMethod) is registered in msec.psm1.

        Projection (Graph field -> output property):
          id                          -> UserId
          userPrincipalName           -> UserPrincipalName
          userDisplayName             -> DisplayName
          userType                    -> UserType        ('member' / 'guest')
          isAdmin                     -> IsAdmin         (holds a privileged directory role)
          isMfaRegistered             -> IsMfaRegistered
          isMfaCapable                -> IsMfaCapable    <- use this for coverage
          isPasswordlessCapable       -> IsPasswordlessCapable
          isSsprRegistered/Enabled/Capable -> IsSsprRegistered / IsSsprEnabled / IsSsprCapable
          methodsRegistered           -> MethodsRegistered  (always an array)
          userPreferredMethodForSecondaryAuthentication
                                      -> UserPreferredMfaMethod
          systemPreferredAuthenticationMethods
                                      -> SystemPreferredMfaMethods (always an array)
          isSystemPreferredAuthenticationMethodEnabled
                                      -> IsSystemPreferredMfaEnabled
          (derived from those three)  -> DefaultMfaMethod
          /beta .../authentication/requirements.perUserMfaState
                                      -> PerUserMfaState  (only with -IncludePerUserMfaState)
          lastUpdatedDateTime         -> LastUpdatedDateTime
          <entire object verbatim>    -> Raw

        DefaultMfaMethod is derived, not a Graph field: the first
        SystemPreferredMfaMethods entry when IsSystemPreferredMfaEnabled is $true and
        that list is non-empty, otherwise UserPreferredMfaMethod. The collection is
        ranked, so its first entry is the one that would be used; it is empty for a user
        with nothing registered, where the user's own value ('none') is the more
        informative answer.

        DO NOT USE DefaultMfaMethod AS A YES/NO. Two ways it inverts the answer:

          'none' is a legitimate value, meaning the user has no default second factor -
          and it is a non-empty string, so `Where-Object DefaultMfaMethod` and
          `if ($row.DefaultMfaMethod)` are BOTH true for it. A coverage count written
          that way reports users with no MFA as having MFA.

          It is a PREFERENCE, not a capability. With IsSystemPreferredMfaEnabled $false
          it is whatever the user last chose, which can name a method the tenant has
          since disabled in its authentication-methods policy.

        IsMfaCapable is the "can they actually do MFA" field: registered AND permitted
        by policy. DefaultMfaMethod answers "with WHICH method", which is a question
        about strength, not about coverage.

        TWO DIFFERENT VOCABULARIES, easily confused. MethodsRegistered uses method
        names ('mobilePhone', 'email', 'passKeyDeviceBound', ...). The preference fields
        use the second-factor enum: 'push', 'oath', 'voiceMobile',
        'voiceAlternateMobile', 'voiceOffice', 'sms', 'none'. Do not join the two on
        equality; nothing will match.

        There is NO defaultMfaMethod property on the v1.0 userRegistrationDetails
        resource - an earlier version of this function read one, and produced an empty
        column on every row for every tenant. If a future Graph version adds one, prefer
        it to this derivation and delete the note.

        `isAdmin` is Graph's own flag for "holds a privileged directory role". It uses
        Microsoft's definition of privileged, which is not identical to the
        IsHighlyPrivileged list in Get-MsecEntraRoleHolder - cross-reference the
        two rather than assuming they agree.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch] $IncludePerUserMfaState
    )

    Assert-MsecSession

    $path = '/v1.0/reports/authenticationMethods/userRegistrationDetails'

    try {
        $rows = @(Invoke-MsecGraphRequest -Path $path -All)
    }
    catch {
        $err = $_
        if ($err.Exception.Message -notmatch '403|Forbidden') { throw }

        # Same two-causes-one-status-code problem as /auditLogs/signIns - see
        # Get-MsecGraphErrorMessage for why the response body has to be read.
        $detail = Get-MsecGraphErrorMessage $err

        if ($detail -match 'premium|B2C') {
            throw "The authentication-methods registration report is not available in this tenant. Microsoft Graph reports: '$detail'. This report requires Microsoft Entra ID P1 or P2 - a LICENSING limit, not a permission problem, so granting 'AuditLog.Read.All' will not change it. Treat MFA registration coverage as not measurable in this tenant."
        }

        throw "Forbidden when calling /reports/authenticationMethods/userRegistrationDetails. Microsoft Graph reports: '$detail'. The usual cause is the msec app missing the 'AuditLog.Read.All' application permission (admin consent required) - re-run New-MsecApp to add and consent it. If that permission is already consented, check licensing instead: this report also requires Entra ID P1/P2."
    }

    # @($null) yields a one-element array containing $null rather than an empty array,
    # which then breaks downstream -contains and .Count checks.
    #
    # Both branches are comma-wrapped because PowerShell UNROLLS a collection returned
    # from a scriptblock: plain `@()` emits zero objects, so the caller's property lands
    # as $null - the very thing this helper exists to prevent - and `@($v)` on a
    # single-element array would hand back the bare element. `,@(...)` emits the array
    # itself as one object, which survives the pipeline intact.
    $arr = { param($v) if ($null -eq $v) { , @() } else { , @($v) } }

    # Legacy per-user MFA has no bulk endpoint - it is one call per user. That cost is
    # reported through Write-Progress rather than a warning: a long run needs to look
    # like it is working, and a warning that cannot be acted on mid-pipeline is noise.
    if ($IncludePerUserMfaState) {
        Write-Verbose "Reading per-user MFA state for $($rows.Count) user(s) - one Graph call each."
    }
    $perUserFailures = 0
    $perUserDone = 0

    foreach ($r in $rows) {
        # The EFFECTIVE default second factor - the method a sign-in would actually
        # prompt for. When the tenant has system-preferred authentication enabled,
        # Entra picks the most secure registered method and the user's own preference
        # is ignored; otherwise the user's choice stands. Reporting either field alone
        # would be wrong in half of all tenants.
        #
        # systemPreferredAuthenticationMethods is a collection but is ranked, so the
        # first entry is what would be used; the whole list stays on the row. It is
        # empty for a user with nothing registered, and the user's preference ('none'
        # in that case) is the more informative answer, so that is the fallback.
        # Legacy per-user MFA: 'enabled', 'enforced' or 'disabled'. It sits OUTSIDE
        # Conditional Access - an enforced user is challenged whatever CA says - which
        # is why registration state alone cannot answer "is MFA required for them".
        # $null means not asked for, or asked for and failed; the warning below counts
        # the failures so the two are distinguishable.
        $perUserMfaState = $null
        if ($IncludePerUserMfaState -and $r.id) {
            $perUserDone++
            if ($rows.Count -gt 25) {
                Write-Progress -Activity 'Reading legacy per-user MFA state' `
                    -Status "$perUserDone of $($rows.Count): $($r.userPrincipalName)" `
                    -PercentComplete ([Math]::Min(100, 100 * $perUserDone / $rows.Count))
            }
            try {
                # Beta only. Microsoft has not shipped this in v1.0, and there is no
                # collection form - the state is reachable one user at a time.
                $req = Invoke-MsecGraphRequest -Path "/beta/users/$($r.id)/authentication/requirements"
                $perUserMfaState = $req.perUserMfaState
            }
            catch {
                $perUserFailures++
                Write-Verbose "Could not read per-user MFA state for $($r.userPrincipalName): $(Get-MsecGraphErrorMessage $_)"
            }
        }

        $systemPreferred = & $arr $r.systemPreferredAuthenticationMethods
        $defaultMethod = if ($r.isSystemPreferredAuthenticationMethodEnabled -and $systemPreferred.Count) {
            $systemPreferred[0]
        }
        else {
            $r.userPreferredMethodForSecondaryAuthentication
        }

        [PSCustomObject]@{
            PSTypeName            = 'MsecEntraMfaRegistration'

            UserId                = $r.id
            UserPrincipalName     = $r.userPrincipalName
            DisplayName           = $r.userDisplayName
            UserType              = $r.userType
            IsAdmin               = [bool] $r.isAdmin

            IsMfaRegistered       = [bool] $r.isMfaRegistered
            IsMfaCapable          = [bool] $r.isMfaCapable
            IsPasswordlessCapable = [bool] $r.isPasswordlessCapable

            IsSsprRegistered      = [bool] $r.isSsprRegistered
            IsSsprEnabled         = [bool] $r.isSsprEnabled
            IsSsprCapable         = [bool] $r.isSsprCapable

            MethodsRegistered     = & $arr $r.methodsRegistered

            # Which method is "the default" is not one field. Entra holds the user's own
            # choice and its own computed choice side by side, and a tenant-level toggle
            # decides which of the two is actually used at sign-in.
            UserPreferredMfaMethod      = $r.userPreferredMethodForSecondaryAuthentication
            SystemPreferredMfaMethods   = & $arr $r.systemPreferredAuthenticationMethods
            IsSystemPreferredMfaEnabled = [bool] $r.isSystemPreferredAuthenticationMethodEnabled
            DefaultMfaMethod            = $defaultMethod

            PerUserMfaState             = $perUserMfaState

            LastUpdatedDateTime   = if ($r.lastUpdatedDateTime) { [datetime]$r.lastUpdatedDateTime } else { $null }

            Raw                   = $r
        }
    }

    if ($IncludePerUserMfaState -and $rows.Count -gt 25) {
        Write-Progress -Activity 'Reading legacy per-user MFA state' -Completed
    }

    if ($perUserFailures -gt 0) {
        Write-Warning "Per-user MFA state could not be read for $perUserFailures user(s), so their PerUserMfaState is `$null and indistinguishable from 'not requested'. This uses the BETA endpoint /beta/users/{id}/authentication/requirements and the 'Policy.Read.All' application permission; re-run with -Verbose to see Graph's message for each."
    }
}
