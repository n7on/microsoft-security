---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecIntuneAuditEvent

## SYNOPSIS
The Intune audit log - who changed which policy, when, and what the setting was
before and after.
Retains far longer than the Entra audit log, and is the only
durable record of a configuration change that was later rolled back.

## SYNTAX

```
Get-MsecIntuneAuditEvent [[-Days] <Int32>] [[-Category] <String>] [[-Activity] <String>] [[-Resource] <String>]
 [[-ResourceType] <String>] [[-Actor] <String>] [-FailedOnly]
 [<CommonParameters>]
```

## DESCRIPTION
Reads /deviceManagement/auditEvents.
One row per change, with the before and after
values of each property that moved.

THIS IS A DIFFERENT STORE FROM THE ENTRA AUDIT LOG, WITH A DIFFERENT RETENTION.
The
Entra directory audit log keeps 30 days on P1/P2 and 7 on the free tier, and
Get-MsecEntraDisabledUser is built around that ceiling.
Intune keeps its own audit
separately and for much longer, so a policy change that is long gone from Entra is
usually still here.
Nothing in the endpoint path hints at this: both are "the audit
log" in conversation, and reaching for the wrong one returns an empty result rather
than an error.

THE PERMISSION IS THE LEAST GUESSABLE IN THE MODULE.
This endpoint is gated by
DeviceManagementApps.Read.All - the Intune APPS scope.
It is NOT covered by
DeviceManagementConfiguration.Read.All, which reads the very policies whose changes
are logged here, nor by DeviceManagementManagedDevices.Read.All, nor by
AuditLog.Read.All, which is Entra's.
Without it the endpoint returns a bare 403 that
names nothing, so the 403 is caught and rewritten.

THE WINDOW ACTUALLY RETURNED IS REPORTED, NOT ASSUMED.
Microsoft does not state the
retention on the API reference, and it is not worth guessing in a module anyone can
run against any tenant.
So -Days sets what is ASKED FOR, and the verbose stream
reports the oldest event that actually came back.
If you ask for 365 days and the
oldest row is 200 days old, that is the real floor of what this tenant can tell you,
and it is a different answer from "nothing happened before then".

AN EMPTY RESULT IS WARNED ABOUT, NEVER RETURNED SILENTLY.
"No changes in the window"
and "the window does not reach back far enough" look identical in an empty array, and
the second one is the answer that matters when you are trying to date a change that
somebody rolled back.

A FILTER THAT MATCHES NOTHING SAYS WHAT WAS THERE INSTEAD.
Resource names are whatever
somebody typed into Intune, so a reasonable-looking -Resource finds nothing and reads
as "that policy was never touched".
Measured: searching a real tenant for 'Attack
Surface' returned zero against 2,798 events, because the policy is called 'Block use of
copied or impersonated system tools'.
When a filter eliminates every row, the values
actually present are named on the warning stream rather than left to be guessed.

ACTIVITY FALLS BACK TO DISPLAYNAME.
Graph returns the \`activity\` property EMPTY on every
row of some tenants - measured 2,798 of 2,798 - while \`displayName\` carries the verb
('Create device configuration 2.0 (beta)').
Activity is therefore the first of the two
that is non-empty, so the column is never blank when the information exists.

CHANGEDPROPERTIES IS THE POINT.
An audit event names the policy that was touched;
ChangedProperties names the settings inside it and carries old -\> new for each.
That
is what tells an ASR rule moving from Audit to Block apart from someone renaming the
policy.
It is a string\[\] so it can be searched with -match without parsing a blob,
and the structured originals stay in Raw.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecIntuneAuditEvent -Days 365 -Resource 'Attack Surface' -Verbose
```

Every change to an ASR policy in the last year, with the window actually available
reported on the verbose stream.
This is the query that dates a rule that was enabled
and later rolled back.

### EXAMPLE 2
```
Get-MsecIntuneAuditEvent -Days 365 |
    Where-Object { $_.ChangedProperties -match 'Block|Audit|Warn' } |
    Select-Object ActivityDateTime, Actor, Resource, ChangedProperties
```

Changes that moved an enforcement mode, whichever policy they were in.

### EXAMPLE 3
```
Get-MsecIntuneAuditEvent -Days 90 | Group-Object Actor | Sort-Object Count -Descending
```

Who is changing Intune.
A service principal near the top is worth knowing about.

### EXAMPLE 4
```
Get-MsecIntuneAuditEvent -Days 365 -ResourceType DeviceManagementConfigurationPolicy |
    Group-Object { $_.Resource } | Sort-Object Count -Descending
```

Every policy touched in the year, busiest first.
Run this BEFORE guessing at -Resource:
the names are whatever somebody typed, and a policy enforcing an ASR rule is as likely
to be called 'Block use of copied or impersonated system tools' as anything with 'ASR'
in it.

### EXAMPLE 5
```
Get-MsecIntuneAuditEvent -Days 90 -FailedOnly
```

Attempted changes that did not succeed.

## PARAMETERS

### -Days
How far back to ask for, counted from now.
Default 30.
This sets the REQUEST, not
the retention - see the description.
Use -Verbose to see what actually came back.

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

### -Category
Only events in this category, for example 'DeviceConfiguration', 'Enrollment',
'Compliance', 'Application'.
Completed from the categories this tenant has actually
produced rather than a fixed list, because the set is not documented and differs
between tenants.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Activity
Substring match on the activity and its display name, case-insensitive.
'Patch' finds
every update; 'Delete' every removal.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Resource
Substring match on the name of the thing that was changed - the policy, profile or
app.
This is usually how you find a specific policy's history.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ResourceType
Only events against this kind of thing - 'DeviceManagementConfigurationPolicy' for
Settings Catalog and endpoint security policies, 'ManagedDevice', 'MobileApp' and so on.
Completed from the types Intune actually emits.
Unlike -Resource, these are Microsoft's
own type names rather than whatever a policy was called, so they are stable to filter on.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Actor
Substring match on who did it: user principal name, application display name, or
service principal name.
Covers changes made by an app as well as by a person.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 6
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -FailedOnly
Only events whose activityResult is not a success.
A failed change attempt is its own
signal - somebody tried and lacked the rights.

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

### PSCustomObject per audit event, PSTypeName 'MsecIntuneAuditEvent'.
## NOTES
Needs the 'DeviceManagementApps.Read.All' application permission, which New-MsecApp
grants.
An app created before that was added must re-run New-MsecApp.

Also needs an active Intune licence on the tenant - the Graph API for Intune returns
an error rather than an empty list without one.

## RELATED LINKS
