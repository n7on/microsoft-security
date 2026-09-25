function Get-MsecEntraMfaRegistrationStats {
    <#
    .SYNOPSIS
        MFA registration coverage in a single summary row - overall, for admins, and by
        method - for a posture report or snapshot.

    .DESCRIPTION
        Internally calls Get-MsecEntraMfaRegistration and aggregates the per-user rows.
        Returns one PSCustomObject covering:

          - Population:  TotalUsers, Members, Guests
          - Coverage:    MfaRegistered / MfaCapable (+ percentages), NotMfaCapable
          - Admins:      AdminTotal, AdminMfaCapable (+ percentage), AdminsNotMfaCapable
                         and AdminsNotMfaCapableUpn - the actual account names, because
                         "3 admins without MFA" is not actionable but a list is
          - Strength:    PasswordlessCapable, PhoneOnlyMfaCapable
          - Members:     MembersMfaCapable / MembersSsprCapable and their percentages,
                         plus MembersPasswordlessCapablePercent - the coverage figures
                         scoped to members. READ THESE, not the all-user ones, in any
                         tenant that has guests
          - Recovery:    SsprCapable (+ percentage), GuestsSsprCapable
          - ByMethod:    count of users per registered method

        **AdminsNotMfaCapable is the headline number.** A privileged account that cannot
        perform MFA is the single most exploitable identity condition in a tenant, and it
        is invisible to Conditional Access reporting - CA shows MFA being demanded, not
        whether the account can satisfy it.

        **GUESTS DILUTE EVERY ALL-USER PERCENTAGE, AND FOR SSPR THEY DESTROY IT.**
        MfaCapablePercent, PasswordlessCapablePercent and SsprCapablePercent all divide by
        the WHOLE directory. Measured on a live tenant of 177 members and 202 guests:

            MfaCapablePercent           61.48   MembersMfaCapablePercent           95.48
            SsprCapablePercent          44.33   MembersSsprCapablePercent          94.92
            NotMfaCapable                  146   MembersNotMfaCapable                   8
            PasswordlessCapablePercent  33.51   MembersPasswordlessCapablePercent  71.75

        The MFA case is blunt: a guest CAN be MFA-capable and some are. The SSPR case is
        not - a guest resets their password in their HOME tenant, so they can essentially
        never be SSPR-capable here (0 of 202 on that tenant), and every guest is dead
        weight in the denominator. GuestsSsprCapable is reported so that is visible rather
        than asserted.

        Both sets are emitted. The all-user columns are unchanged so an existing posture
        workbook's history stays comparable; the Members* ones are what to report.

        Coverage uses IsMfaCapable, not IsMfaRegistered: a method registered but disabled
        by the tenant's authentication-methods policy will not work, so counting it would
        overstate coverage. See Get-MsecEntraMfaRegistration for the distinction.

        PhoneOnlyMfaCapable counts MFA-capable users whose registered methods are ALL
        phone-based (SMS / voice). Those are the phishable and SIM-swappable ones, so a
        tenant can be at 100% coverage and still be materially weak. The phone-method list
        is a best-effort match on Graph's method names (see .NOTES); MethodsRegistered on
        the per-user rows lets you reclassify if Microsoft renames them.

        Permission and licensing requirements are inherited from
        Get-MsecEntraMfaRegistration (AuditLog.Read.All, plus Entra ID P1/P2 - the report
        is premium-gated).

    .EXAMPLE
        Get-MsecEntraMfaRegistrationStats | Format-List

    .EXAMPLE
        # The finding you want to walk into a posture meeting with:
        $m = Get-MsecEntraMfaRegistrationStats
        if ($m.AdminsNotMfaCapable) {
            "$($m.AdminsNotMfaCapable) privileged account(s) cannot do MFA: " +
            ($m.AdminsNotMfaCapableUpn -join ', ')
        }

    .EXAMPLE
        # Slot it into the posture snapshot next to the other domains.
        $snapshot = [pscustomobject]@{
            CapturedAtUtc   = (Get-Date).ToUniversalTime().ToString('u')
            MfaRegistration = Get-MsecEntraMfaRegistrationStats
            CaStats         = Get-MsecEntraConditionalAccessStats -Days 7
        }

    .OUTPUTS
        One PSCustomObject. Percentages are rounded to 2 decimals and are $null when the
        relevant population is zero (never 0, which would read as "nobody is covered").

    .NOTES
        Phone-based methods, for PhoneOnlyMfaCapable: mobilePhone, alternateMobilePhone,
        officePhone, voiceCall, sms. Everything else - microsoftAuthenticatorPush,
        softwareOneTimePasscode, fido2SecurityKey, windowsHelloForBusiness,
        passKeyDeviceBound, certificate*, temporaryAccessPass - counts as stronger.
        Graph has renamed these before; the classification is deliberately kept in one
        place here so it is easy to adjust.
    #>
    [CmdletBinding()]
    param()

    Assert-MsecSession

    $users = @(Get-MsecEntraMfaRegistration)

    # Guard every percentage: an empty population must yield $null, not 0, which would
    # read as "measured, and nobody is covered".
    $pct = { param([int] $Part, [int] $Whole)
             if ($Whole -gt 0) { [math]::Round(100.0 * $Part / $Whole, 2) } else { $null } }

    $phoneMethods = @('mobilePhone', 'alternateMobilePhone', 'officePhone', 'voiceCall', 'sms')

    $members = @($users | Where-Object UserType -eq 'member')
    $guests  = @($users | Where-Object UserType -eq 'guest')

    $mfaRegistered = @($users | Where-Object IsMfaRegistered)
    $mfaCapable    = @($users | Where-Object IsMfaCapable)

    # MEMBER-SCOPED COVERAGE. The percentages above divide by EVERY user, guests included,
    # and guests distort them in two different ways. Measured on a live tenant with 177
    # members and 202 guests: MFA coverage read 61.48% against a true member figure of
    # 95.48%, and SSPR read 44.33% against 94.92%.
    #
    # The two are not the same kind of error. A guest CAN be MFA-capable and some are, so
    # the all-user MFA number is blunt rather than wrong. A guest can essentially never be
    # SSPR-capable, because they reset their password in their HOME tenant - measured live,
    # 0 of 202 - so every guest is dead weight in that denominator and the all-user SSPR
    # number understates recovery coverage by however many guests the tenant holds.
    #
    # Both sets are reported. The all-user columns are unchanged so an existing posture
    # workbook's history stays comparable; these are the ones to read.
    $membersMfaCapable  = @($members | Where-Object IsMfaCapable)
    $membersPwlCapable  = @($members | Where-Object IsPasswordlessCapable)
    $membersSsprCapable = @($members | Where-Object IsSsprCapable)
    $guestsSsprCapable  = @($guests  | Where-Object IsSsprCapable)

    $admins            = @($users  | Where-Object IsAdmin)
    $adminsCapable     = @($admins | Where-Object IsMfaCapable)
    $adminsNotCapable  = @($admins | Where-Object { -not $_.IsMfaCapable })

    # MFA-capable users with at least one method, all of which are phone-based. The
    # "at least one" guard matters: a user with an empty MethodsRegistered array would
    # otherwise satisfy "all methods are phone" vacuously.
    $phoneOnly = @($mfaCapable | Where-Object {
        $m = @($_.MethodsRegistered)
        $m.Count -gt 0 -and -not @($m | Where-Object { $_ -notin $phoneMethods }).Count
    })

    # Method -> number of users who registered it. Users appear under several methods.
    $byMethod = [ordered]@{}
    foreach ($g in ($users.MethodsRegistered | Group-Object | Sort-Object Count -Descending)) {
        $byMethod[$g.Name] = $g.Count
    }

    [PSCustomObject]@{
        # Population
        TotalUsers                = $users.Count
        Members                   = $members.Count
        Guests                    = $guests.Count

        # Coverage (IsMfaCapable is the honest measure - see .DESCRIPTION)
        MfaRegistered             = $mfaRegistered.Count
        MfaRegisteredPercent      = & $pct $mfaRegistered.Count $users.Count
        MfaCapable                = $mfaCapable.Count
        MfaCapablePercent         = & $pct $mfaCapable.Count $users.Count
        NotMfaCapable             = $users.Count - $mfaCapable.Count

        # Admins - the headline
        AdminTotal                = $admins.Count
        AdminMfaCapable           = $adminsCapable.Count
        AdminMfaCapablePercent    = & $pct $adminsCapable.Count $admins.Count
        AdminsNotMfaCapable       = $adminsNotCapable.Count
        AdminsNotMfaCapableUpn    = @($adminsNotCapable.UserPrincipalName | Sort-Object)

        # Member-scoped coverage - the honest measure in a tenant with guests. See the
        # comment above the computation for why these exist alongside the all-user ones.
        MembersMfaCapable                = $membersMfaCapable.Count
        # The one to quote out loud. NotMfaCapable counts the whole directory, so in a
        # guest-heavy tenant it states the problem as a sentence that is wrong by an order
        # of magnitude - measured live, 146 against a true member figure of 8.
        MembersNotMfaCapable             = $members.Count - $membersMfaCapable.Count
        MembersMfaCapablePercent         = & $pct $membersMfaCapable.Count $members.Count
        MembersPasswordlessCapablePercent = & $pct $membersPwlCapable.Count $members.Count
        MembersSsprCapable               = $membersSsprCapable.Count
        MembersSsprCapablePercent        = & $pct $membersSsprCapable.Count $members.Count

        # Guests
        GuestsMfaCapable          = @($guests | Where-Object IsMfaCapable).Count
        # Reported so a reader can SEE that guests contribute nothing to SSPR rather than
        # having to take it on trust: it is the whole reason the member figure exists.
        GuestsSsprCapable         = $guestsSsprCapable.Count

        # Strength of what is registered
        PasswordlessCapable       = @($users | Where-Object IsPasswordlessCapable).Count
        PasswordlessCapablePercent = & $pct @($users | Where-Object IsPasswordlessCapable).Count $users.Count
        PhoneOnlyMfaCapable       = $phoneOnly.Count
        PhoneOnlyMfaCapablePercent = & $pct $phoneOnly.Count $mfaCapable.Count

        # Self-service password reset
        SsprCapable               = @($users | Where-Object IsSsprCapable).Count
        SsprCapablePercent        = & $pct @($users | Where-Object IsSsprCapable).Count $users.Count

        ByMethod                  = $byMethod
    }
}
