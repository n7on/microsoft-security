---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecEntraMfaEvidence

## SYNOPSIS
Per-user MFA evidence for an access review or audit: whether MFA was actually
demanded and met at sign-in, whether the user is excluded from the policies that
demand it, and where neither can be shown.

## SYNTAX

```
Get-MsecEntraMfaEvidence [[-Days] <Int32>] [-AdminsOnly] [-IncludeGuests]
 [<CommonParameters>]
```

## DESCRIPTION
Answers the question an auditor asks - "show me that MFA is enforced for your
users" - which none of the individual reports can answer alone:

  Get-MsecEntraMfaRegistration     proves CAPABILITY.
A user can be fully
                                   capable and never once be challenged.
  Get-MsecEntraConditionalAccessPolicy
                                   proves a policy EXISTS.
It does not show who
                                   slips through its exclusions.
  Get-MsecEntraConditionalAccessSignInLog
                                   proves what HAPPENED, but only for users who
                                   signed in during the window.

This joins all three into one row per user and assigns each user an
EvidenceStatus - the four buckets an audit response has to account for:

  MfaSatisfied         An interactive sign-in in the window had a Conditional
                       Access policy demand MFA, and it was met.
This is
                       evidence of the control OPERATING, which is what an
                       auditor wants over a screenshot of a policy.
  SingleFactorObserved An interactive sign-in SUCCEEDED with no MFA-requiring
                       policy applied.
The finding: somebody got in on one
                       factor.
See SingleFactorApps / SingleFactorClientApps /
                       SingleFactorLegacyAuth to triage it.
  NoSuccessfulSignIn   Interactive sign-ins were attempted but none succeeded -
                       rejected at the password, or challenged for MFA and
                       failed.
Nothing is evidenced either way, and a failed
                       MFA challenge is the control WORKING, not a bypass.
  NoSignInInWindow     No interactive sign-in at all.
NOT a pass: the fallback
                       statement is capability plus policy scope, and dormant
                       privileged accounts live here.
  NoEvidenceAvailable  Sign-in data could not be read at all (see the warning).

ExcludedFromMfaPolicies is reported separately from EvidenceStatus rather than
folded into it, because the two are orthogonal: a user can be excluded from the
tenant-wide policy and still have satisfied MFA via another one.
An exclusion is
a finding in its own right - a stale break-glass group is the classic audit
observation - so it must not be hidden behind a passing status.

WHAT THIS CANNOT PROVE.
Policy scope is INFERRED, not evaluated.
Only policies
that are enabled, require MFA, and include all users are treated as tenant-wide;
their user, group and role exclusions are resolved and applied per user.
Policies
with narrower conditions - specific apps, platforms, locations, risk levels, or
an include list rather than 'All' - are reported in OtherMfaPolicies and their
scope is NOT computed, because doing that properly means reimplementing
Conditional Access.
Graph's CA What-If evaluation API is the only authoritative
answer; until this uses it, treat inferred scope as a strong indicator and the
sign-in evidence as the proof.

Requires everything the three underlying commands require: 'AuditLog.Read.All',
'Policy.Read.All', 'User.Read.All', 'Group.Read.All', plus Entra ID P1/P2 for the
registration report and sign-in logs.
Role-based exclusions additionally read
role assignments ('RoleManagement.Read.Directory').

## EXAMPLES

### EXAMPLE 1
```
# Start here: the administrators, which is the fast path and the question an
# auditor asks first. Capture the rows once, then slice them - a tenant-wide
# run is minutes of paging and should not be repeated per question.
$evidence = Get-MsecEntraMfaEvidence -AdminsOnly
$evidence | Group-Object EvidenceStatus -NoElement
```

### EXAMPLE 2
```
# The headline for the whole tenant. Slow - it pages every sign-in in the window
# - and Group-Object shows nothing until it finishes, so run it with -Verbose the
# first time to watch the phases.
Get-MsecEntraMfaEvidence -Verbose | Group-Object EvidenceStatus -NoElement
```

### EXAMPLE 3
```
# The findings list. Anything here needs a sentence in the response.
Get-MsecEntraMfaEvidence |
    Where-Object { $_.EvidenceStatus -eq 'SingleFactorObserved' -or $_.ExcludedFromMfaPolicies } |
    Format-Table UserPrincipalName, EvidenceStatus, ExcludedFromMfaPolicies
```

### EXAMPLE 4
```
# Administrators, row by row - the evidence table to attach.
Get-MsecEntraMfaEvidence -AdminsOnly |
    Format-Table UserPrincipalName, EvidenceStatus, MfaSatisfiedSignIns,
                 SingleFactorSignIns, LastMfaSatisfiedUtc, DefaultMfaMethod
```

### EXAMPLE 5
```
# Triage the single-factor findings without leaving the evidence rows: what was
# reached, with which client, and when. Legacy auth is the row to read first.
Get-MsecEntraMfaEvidence -AdminsOnly |
    Where-Object EvidenceStatus -eq 'SingleFactorObserved' |
    Format-Table UserPrincipalName, SingleFactorSignIns, SingleFactorLegacyAuth,
                 @{ n = 'Clients'; e = { $_.SingleFactorClientApps -join ', ' } },
                 @{ n = 'Apps';    e = { $_.SingleFactorApps -join ', ' } }
```

### EXAMPLE 6
```
# The accounts that cannot be evidenced empirically - dormant or service-like.
# An unused admin account with no MFA is the finding auditors look for.
Get-MsecEntraMfaEvidence -AdminsOnly |
    Where-Object EvidenceStatus -eq 'NoSignInInWindow' |
    Format-Table UserPrincipalName, IsMfaCapable, InScopeOfMfaPolicies
```

## PARAMETERS

### -Days
Size of the evidence window in days, 1-30 (Graph's sign-in log retention limit
on this endpoint).
Default 30.
State this window in the audit response: the
evidence is only as good as the period it covers.

COST.
For 40 or fewer users the sign-in log is fetched with a server-side userId
filter, which is fast.
Above that it pages every sign-in in the window for the
whole tenant - tens of thousands of events per day on a real tenant, so a
30-day tenant-wide run takes minutes.
-AdminsOnly is usually both the question
being asked and the fast path.
Progress is reported throughout; note that piping
into Group-Object buffers everything, so no rows appear until it finishes.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: 30
Accept pipeline input: False
Accept wildcard characters: False
```

### -AdminsOnly
Restrict to users Graph flags as holding a privileged role.
The population an
auditor asks about first, and small enough to read row by row.

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

### -IncludeGuests
Include guest users.
Off by default: guests authenticate against their home
tenant, so this tenant's policies and their MFA registration state are not the
whole story for them, and mixing them into a coverage percentage misleads.

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
Each row is a \[PSCustomObject\] with PSTypeName 'MsecEntraMfaEvidence', whose
DefaultDisplayPropertySet (UserPrincipalName, EvidenceStatus, IsMfaCapable,
DefaultMfaMethod, IsAdmin) is registered in Msec.psm1.

Projection:
  UserPrincipalName, UserId, DisplayName, UserType, IsAdmin
  IsMfaCapable, IsMfaRegistered, DefaultMfaMethod   from the registration report
  EvidenceStatus              one of the four buckets above
  InteractiveSignIns          count in the window
  MfaSatisfiedSignIns         interactive sign-ins where a policy demanded MFA
                              and it was met
  SingleFactorSignIns         SUCCESSFUL interactive sign-ins where no
                              MFA-requiring policy applied.
Failed sign-ins are
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
authenticationRequirement or mfaDetail property.
Only INTERACTIVE sign-ins are
counted - non-interactive ones are token refreshes and service calls that
legitimately never prompt, and counting them would make every tenant look
uncovered.

A user with zero interactive sign-ins is NoSignInInWindow, never a pass.
Reading
that as compliant is the most common way this kind of report misleads.

## RELATED LINKS
