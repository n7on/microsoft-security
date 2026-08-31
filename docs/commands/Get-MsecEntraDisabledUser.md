---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecEntraDisabledUser

## SYNOPSIS
Every disabled ("archived") user in the tenant, with how long each has been disabled
where that is knowable, and what it is still costing in licences.

## SYNTAX

```
Get-MsecEntraDisabledUser [[-Days] <Int32>] [[-UserType] <String>] [-ExcludeSignInActivity] [<CommonParameters>]
```

## DESCRIPTION
Lists users with accountEnabled = false, then works out when each was disabled.

HOW LONG IS THE HARD PART, AND IT IS NOT ALWAYS ANSWERABLE
----------------------------------------------------------
Entra stores no 'disabledDateTime'.
A user object records when it was created and
when it last signed in, but nothing about when somebody switched it off.
The only
record of the act is in the directory audit log - an 'Update user' event whose
modifiedProperties show AccountEnabled going from \[true\] to \[false\].

Those logs retain 30 days on Entra ID P1/P2 and 7 days on the free tier.
So:

  * disabled recently  -\> DisabledSince and DisabledDays are EXACT, and DisabledBy
                          names who did it.
  * disabled long ago  -\> the event has aged out.
DisabledSince is $null, and the
                          row instead carries a BRACKET: DisabledAtLeastDays (the
                          window searched, since nothing was found inside it) and
                          DisabledAtMostDays (days since the last SUCCESSFUL sign-in,
                          because a disabled account cannot sign in successfully).

The upper bound comes from signInActivity, which is a property Entra persists on the
user object rather than a log query - so unlike DisabledSince it is NOT capped at the
audit retention window and happily reaches back years.
It does need Entra ID P1.

It rests specifically on lastSuccessfulSignInDateTime, and the distinction matters:
lastSignInDateTime records the last interactive ATTEMPT, and a disabled account still
gets attempted - by an ex-employee, a stale client, a password spray.
Computing the
bound from an attempt would report "disabled at most 7 days" for an account switched
off three years ago.
Where no successful sign-in is recorded, DisabledAtMostDays is
left blank rather than guessed.

That bracket is the honest answer and is usually enough to act on - "between 30 and
400 days" tells you it is long dead.
A single invented number would not be.

LICENCES ARE THE REASON THIS IS WORTH RUNNING.
A disabled account still holding
assigned licences is both spend and attack surface, so LicenseCount is projected and
the examples sort by it.

"LAST UPDATED" IS THREE DIFFERENT COLUMNS, BECAUSE IT IS THREE DIFFERENT QUESTIONS
----------------------------------------------------------------------------------
Graph exposes no lastModifiedDateTime on a user, so there is no single answer.
What
exists is:

  LastDirectoryChange  newest audit event against the object, plus
  (+ ...What)          LastDirectoryChangeWhat naming which properties moved.
The
                       closest thing to "last edited", and bounded by the same audit
                       retention as DisabledSince - so $null here means "nothing in
                       the last -Days days", NOT "never touched".

  LastPasswordChange   unbounded and always present, straight off the user object.
                       On a disabled account this is usually the best marker of when
                       it was genuinely last in use.

  OnPremisesLastSync   synced accounts only.
Worth watching for the case where sync
                       is still enabled but this stopped advancing: the on-premises
                       source object is gone and what is left in Entra is an orphan
                       nothing will ever update or clean up again.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraDisabledUser | Where-Object LicenseCount -gt 0 |
    Sort-Object LicenseCount -Descending |
    Format-Table UserPrincipalName, LicenseCount, DisabledDays, DisabledAtLeastDays
```

Disabled accounts still consuming licences, worst first.

### EXAMPLE 2
```
# Who has been switched off in the last week, and by whom.
Get-MsecEntraDisabledUser -Days 7 | Where-Object DisabledSince |
    Sort-Object DisabledSince -Descending |
    Format-Table UserPrincipalName, DisabledSince, DisabledBy
```

### EXAMPLE 3
```
# Long-dead accounts: nothing in the audit window, and no sign-in for over a year.
Get-MsecEntraDisabledUser |
    Where-Object { -not $_.DisabledSince -and $_.DisabledAtMostDays -gt 365 }
```

## PARAMETERS

### -Days
How far back to search the audit log for the disable event.
Default 30, which is the
P1/P2 retention ceiling - asking for more cannot find more, it just takes longer.
Drop
to 7 on a free-tier tenant.

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

### -UserType
'Member', 'Guest' or 'All'.
Default All.
Disabled guests are worth separating: a guest
left disabled is usually a finished engagement nobody cleaned up.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: All
Accept pipeline input: False
Accept wildcard characters: False
```

### -ExcludeSignInActivity
Skip the last-sign-in lookup.
That property is what makes DisabledAtMostDays possible,
so skipping it leaves the upper half of the bracket blank - but it is premium-only, and
on a tenant without Entra ID P1 it costs a round trip to learn nothing.

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

### PSCustomObject per disabled user, PSTypeName 'MsecEntraDisabledUser'.
## NOTES
Needs User.Read.All and AuditLog.Read.All, both of which New-MsecApp already grants -
no re-run required.

DisabledSince comes from the audit log, so it reflects the last time the account was
disabled.
An account switched off, back on, and off again reports the most recent
event, which is the one you want.

On-premises-synced accounts (OnPremisesSyncEnabled) are disabled in Active Directory
and the state syncs down.
The audit event still appears, attributed to the sync
account rather than to a person, so DisabledBy will name the directory synchronisation
service - that is correct, not a lookup failure.

## RELATED LINKS
