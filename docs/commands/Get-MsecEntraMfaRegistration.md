---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecEntraMfaRegistration

## SYNOPSIS
Per-user authentication-method registration state as flat rows - who can actually
do MFA, with which methods, and who is an admin.

## SYNTAX

```
Get-MsecEntraMfaRegistration [-IncludePerUserMfaState]
 [<CommonParameters>]
```

## DESCRIPTION
Calls Microsoft Graph /v1.0/reports/authenticationMethods/userRegistrationDetails,
the data behind the Entra "Authentication methods - registration" report, and
projects one row per user.

This answers the question a Conditional Access policy cannot: CA proves MFA is
*demanded*, this proves it is *possessed*.
A tenant can have a flawless Require-MFA
policy and still hold admin accounts with nothing registered, which surfaces only
as a lockout or a bypass later.

WHAT THIS DOES NOT TELL YOU.
Registration is capability, not enforcement.
A user
can be IsMfaCapable and never once be challenged.
"Is MFA actually required for
this person" is a different question with three independent sources:

  Security defaults      tenant-wide on/off - Get-MsecEntraTenantSecuritySetting
  Conditional Access     per-policy conditions - Get-MsecEntraConditionalAccessPolicy
                         lists the policies, but does NOT evaluate which apply to
                         a given user; that needs the CA What-If evaluation API
  Legacy per-user MFA    the pre-CA Enabled/Enforced/Disabled flag, which sits
                         OUTSIDE Conditional Access entirely - an 'enforced' user
                         is challenged whatever CA says - and is invisible in
                         every other report here.
-IncludePerUserMfaState reads it

And the empirical answer - did they actually perform MFA - is in the sign-in
logs, via Get-MsecEntraConditionalAccessSignInLog.
When the three configuration
sources disagree with the logs, the logs are right.

IsMfaRegistered vs IsMfaCapable - the distinction that matters:
  IsMfaRegistered  the user has registered at least one MFA method.
  IsMfaCapable     the user has registered a method AND that method is enabled by
                   the tenant's authentication-methods policy, i.e.
it will
                   actually work.
Registered-but-not-capable means someone registered a method the tenant has since
disabled.
**Use IsMfaCapable for coverage reporting** - it is the honest number.

THE DEFAULT METHOD IS NOT ONE FIELD.
Entra stores the user's own choice
(UserPreferredMfaMethod) and its own computed choice (SystemPreferredMfaMethods)
side by side, and a tenant-level toggle (IsSystemPreferredMfaEnabled) decides
which is used at sign-in: with system-preferred on, Entra picks the most secure
registered method and the user's preference is ignored.
DefaultMfaMethod
resolves that - it is the method a sign-in would actually prompt for - and all
three inputs stay on the row so the derivation can be checked.

Method strength is the point of reading it: 'sms' and the 'voice*' values are
phishable and interceptable, 'push' and 'oath' materially less so.
A tenant
whose administrators default to SMS has MFA in name.

Requires the 'AuditLog.Read.All' application permission AND Microsoft Entra ID P1
or P2 on the tenant: this report is premium-gated independently of permissions.
A
403 is re-thrown with Graph's own message, distinguishing the two causes, because a
licensing 403 cannot be fixed by granting a permission.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraMfaRegistration | Where-Object { $_.IsAdmin -and -not $_.IsMfaCapable }
```

### EXAMPLE 2
```
# Method mix - how much of the estate rests on phishable phone-based MFA?
Get-MsecEntraMfaRegistration |
    Select-Object -ExpandProperty MethodsRegistered |
    Group-Object | Sort-Object Count -Descending
```

### EXAMPLE 3
```
Get-MsecEntraMfaRegistration | Group-Object UserType, IsMfaCapable -NoElement
```

### EXAMPLE 4
```
# Administrators whose second factor is phishable - SMS or a voice call to a
# phone number. This is the row an attacker with a SIM swap is looking for.
Get-MsecEntraMfaRegistration |
    Where-Object { $_.IsAdmin -and $_.DefaultMfaMethod -match '^(sms|voice)' } |
    Format-Table UserPrincipalName, DefaultMfaMethod, MethodsRegistered
```

### EXAMPLE 5
```
# Where the tenant's defaults actually come from: with system-preferred
# authentication off, every user's own choice stands unreviewed.
Get-MsecEntraMfaRegistration |
    Group-Object IsSystemPreferredMfaEnabled, DefaultMfaMethod -NoElement
```

### EXAMPLE 6
```
# Legacy per-user MFA across the whole tenant. 'enabled' and 'enforced' predate
# Conditional Access and override nothing - they simply also apply - so a tenant
# that thinks it moved to CA years ago can still be running on these.
Get-MsecEntraMfaRegistration -IncludePerUserMfaState |
    Group-Object PerUserMfaState -NoElement
```

### EXAMPLE 7
```
# Capability and enforcement together, for administrators only - the population
# small enough to pay one Graph call each for.
Get-MsecEntraMfaRegistration -IncludePerUserMfaState |
    Where-Object IsAdmin |
    Format-Table UserPrincipalName, IsMfaCapable, DefaultMfaMethod, PerUserMfaState
```

## PARAMETERS

### -IncludePerUserMfaState
Also read each user's LEGACY per-user MFA state ('enabled', 'enforced',
'disabled') into PerUserMfaState.
Off by default because there is no bulk
endpoint: this costs ONE Graph call per user, and it uses the BETA endpoint
/beta/users/{id}/authentication/requirements, which Microsoft does not support
for production use.
Needs 'Policy.Read.All', which the msec app already has.

Filter before asking for it - piping only the admins through is the difference
between a dozen calls and several thousand.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per user. See .NOTES for the projection.
## NOTES
Each row is a \[PSCustomObject\] with PSTypeName 'MsecEntraMfaRegistration', whose
DefaultDisplayPropertySet (UserPrincipalName, IsAdmin, IsMfaCapable,
DefaultMfaMethod) is registered in Msec.psm1.

Projection (Graph field -\> output property):
  id                          -\> UserId
  userPrincipalName           -\> UserPrincipalName
  userDisplayName             -\> DisplayName
  userType                    -\> UserType        ('member' / 'guest')
  isAdmin                     -\> IsAdmin         (holds a privileged directory role)
  isMfaRegistered             -\> IsMfaRegistered
  isMfaCapable                -\> IsMfaCapable    \<- use this for coverage
  isPasswordlessCapable       -\> IsPasswordlessCapable
  isSsprRegistered/Enabled/Capable -\> IsSsprRegistered / IsSsprEnabled / IsSsprCapable
  methodsRegistered           -\> MethodsRegistered  (always an array)
  userPreferredMethodForSecondaryAuthentication
                              -\> UserPreferredMfaMethod
  systemPreferredAuthenticationMethods
                              -\> SystemPreferredMfaMethods (always an array)
  isSystemPreferredAuthenticationMethodEnabled
                              -\> IsSystemPreferredMfaEnabled
  (derived from those three)  -\> DefaultMfaMethod
  /beta .../authentication/requirements.perUserMfaState
                              -\> PerUserMfaState  (only with -IncludePerUserMfaState)
  lastUpdatedDateTime         -\> LastUpdatedDateTime
  \<entire object verbatim\>    -\> Raw

DefaultMfaMethod is derived, not a Graph field: the first
SystemPreferredMfaMethods entry when IsSystemPreferredMfaEnabled is $true and
that list is non-empty, otherwise UserPreferredMfaMethod.
The collection is
ranked, so its first entry is the one that would be used; it is empty for a user
with nothing registered, where the user's own value ('none') is the more
informative answer.

DO NOT USE DefaultMfaMethod AS A YES/NO.
Two ways it inverts the answer:

  'none' is a legitimate value, meaning the user has no default second factor -
  and it is a non-empty string, so \`Where-Object DefaultMfaMethod\` and
  \`if ($row.DefaultMfaMethod)\` are BOTH true for it.
A coverage count written
  that way reports users with no MFA as having MFA.

  It is a PREFERENCE, not a capability.
With IsSystemPreferredMfaEnabled $false
  it is whatever the user last chose, which can name a method the tenant has
  since disabled in its authentication-methods policy.

IsMfaCapable is the "can they actually do MFA" field: registered AND permitted
by policy.
DefaultMfaMethod answers "with WHICH method", which is a question
about strength, not about coverage.

TWO DIFFERENT VOCABULARIES, easily confused.
MethodsRegistered uses method
names ('mobilePhone', 'email', 'passKeyDeviceBound', ...).
The preference fields
use the second-factor enum: 'push', 'oath', 'voiceMobile',
'voiceAlternateMobile', 'voiceOffice', 'sms', 'none'.
Do not join the two on
equality; nothing will match.

There is NO defaultMfaMethod property on the v1.0 userRegistrationDetails
resource - an earlier version of this function read one, and produced an empty
column on every row for every tenant.
If a future Graph version adds one, prefer
it to this derivation and delete the note.

\`isAdmin\` is Graph's own flag for "holds a privileged directory role".
It uses
Microsoft's definition of privileged, which is not identical to the
IsHighlyPrivileged list in Get-MsecEntraRoleHolder - cross-reference the
two rather than assuming they agree.

## RELATED LINKS
