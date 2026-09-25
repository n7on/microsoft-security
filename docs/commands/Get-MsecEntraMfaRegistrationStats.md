---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecEntraMfaRegistrationStats

## SYNOPSIS
MFA registration coverage in a single summary row - overall, for admins, and by
method - for a posture report or snapshot.

## SYNTAX

```
Get-MsecEntraMfaRegistrationStats [<CommonParameters>]
```

## DESCRIPTION
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
                 scoped to members.
READ THESE, not the all-user ones, in any
                 tenant that has guests
  - Recovery:    SsprCapable (+ percentage), GuestsSsprCapable
  - ByMethod:    count of users per registered method

**AdminsNotMfaCapable is the headline number.** A privileged account that cannot
perform MFA is the single most exploitable identity condition in a tenant, and it
is invisible to Conditional Access reporting - CA shows MFA being demanded, not
whether the account can satisfy it.

**GUESTS DILUTE EVERY ALL-USER PERCENTAGE, AND FOR SSPR THEY DESTROY IT.**
MfaCapablePercent, PasswordlessCapablePercent and SsprCapablePercent all divide by
the WHOLE directory.
Measured on a live tenant of 177 members and 202 guests:

    MfaCapablePercent           61.48   MembersMfaCapablePercent           95.48
    SsprCapablePercent          44.33   MembersSsprCapablePercent          94.92
    NotMfaCapable                  146   MembersNotMfaCapable                   8
    PasswordlessCapablePercent  33.51   MembersPasswordlessCapablePercent  71.75

The MFA case is blunt: a guest CAN be MFA-capable and some are.
The SSPR case is
not - a guest resets their password in their HOME tenant, so they can essentially
never be SSPR-capable here (0 of 202 on that tenant), and every guest is dead
weight in the denominator.
GuestsSsprCapable is reported so that is visible rather
than asserted.

Both sets are emitted.
The all-user columns are unchanged so an existing posture
workbook's history stays comparable; the Members* ones are what to report.

Coverage uses IsMfaCapable, not IsMfaRegistered: a method registered but disabled
by the tenant's authentication-methods policy will not work, so counting it would
overstate coverage.
See Get-MsecEntraMfaRegistration for the distinction.

PhoneOnlyMfaCapable counts MFA-capable users whose registered methods are ALL
phone-based (SMS / voice).
Those are the phishable and SIM-swappable ones, so a
tenant can be at 100% coverage and still be materially weak.
The phone-method list
is a best-effort match on Graph's method names (see .NOTES); MethodsRegistered on
the per-user rows lets you reclassify if Microsoft renames them.

Permission and licensing requirements are inherited from
Get-MsecEntraMfaRegistration (AuditLog.Read.All, plus Entra ID P1/P2 - the report
is premium-gated).

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraMfaRegistrationStats | Format-List
```

### EXAMPLE 2
```
# The finding you want to walk into a posture meeting with:
$m = Get-MsecEntraMfaRegistrationStats
if ($m.AdminsNotMfaCapable) {
    "$($m.AdminsNotMfaCapable) privileged account(s) cannot do MFA: " +
    ($m.AdminsNotMfaCapableUpn -join ', ')
}
```

### EXAMPLE 3
```
# Slot it into the posture snapshot next to the other domains.
$snapshot = [pscustomobject]@{
    CapturedAtUtc   = (Get-Date).ToUniversalTime().ToString('u')
    MfaRegistration = Get-MsecEntraMfaRegistrationStats
    CaStats         = Get-MsecEntraConditionalAccessStats -Days 7
}
```

## PARAMETERS

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### One PSCustomObject. Percentages are rounded to 2 decimals and are $null when the
### relevant population is zero (never 0, which would read as "nobody is covered").
## NOTES
Phone-based methods, for PhoneOnlyMfaCapable: mobilePhone, alternateMobilePhone,
officePhone, voiceCall, sms.
Everything else - microsoftAuthenticatorPush,
softwareOneTimePasscode, fido2SecurityKey, windowsHelloForBusiness,
passKeyDeviceBound, certificate*, temporaryAccessPass - counts as stronger.
Graph has renamed these before; the classification is deliberately kept in one
place here so it is easy to adjust.

## RELATED LINKS
