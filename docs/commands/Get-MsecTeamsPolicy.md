---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecTeamsPolicy

## SYNOPSIS
The Teams settings that decide who can reach your people - external access, guest
access, meeting lobby and recording, app installation - as one row per setting.

## SYNTAX

```
Get-MsecTeamsPolicy [[-PolicyType] <String[]>] [-All] [<CommonParameters>]
```

## DESCRIPTION
Teams policy is where a tenant quietly becomes reachable from the outside.
Anonymous
meeting join, open federation, guest access and unrestricted app installation are all
defaults-on or defaults-permissive, none of them appear in a Secure Score or a
Conditional Access review, and each is a real path in.

ONE ROW PER SETTING, NOT PER POLICY.
A meeting policy object carries roughly eighty
properties, most of them about layout and captions.
Returning whole objects makes the
handful that matter impossible to see, and impossible to compare between two policies
or two tenants.
Flattened to (PolicyType, PolicyName, Setting, Value), the output
sorts, filters and diffs.

ONLY THE SECURITY-RELEVANT SETTINGS ARE PROJECTED, and which ones is a judgement this
command makes on your behalf - so it is written down in the source rather than hidden.
-All returns every property of every policy instead, for when you need to see what was
left out.

A POLICY TYPE THAT CANNOT BE READ IS REPORTED, NOT SKIPPED.
Teams cmdlets fail
individually when a role is missing or a feature is not licensed, and a report that
silently omitted federation configuration would read as a tenant with none.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Get-MsecTeamsPolicy
```

### EXAMPLE 2
```
# The settings that let people in from outside.
Get-MsecTeamsPolicy -PolicyType Federation, Client |
    Where-Object Value -in 'True', 'Everyone', 'EveryoneInCompanyExcludingGuests'
```

### EXAMPLE 3
```
# Compare the Global policy against the custom ones - drift is where exceptions hide.
Get-MsecTeamsPolicy -PolicyType Meeting |
    Group-Object Setting | Where-Object { @($_.Group.Value | Select-Object -Unique).Count -gt 1 }
```

## PARAMETERS

### -PolicyType
Which policy areas to read.
Default is all of them:
  Federation      external access - who outside the tenant can chat with your people
  Meeting         anonymous join, lobby, recording, external control
  Messaging       message deletion, read receipts
  AppPermission   which apps users may install
  Client          guest access, channel email, third-party storage providers
  Files           file sharing in chats with external users, and where uploads land

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: @('Federation', 'Meeting', 'Messaging', 'AppPermission', 'Client', 'Files')
Accept pipeline input: False
Accept wildcard characters: False
```

### -All
Return every property of every policy, not just the security-relevant projection.

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

### PSCustomObject per setting, PSTypeName 'MsecTeamsPolicy'.
## NOTES
Needs Connect-Msec; the Teams sign-in is done for you by calling Connect-MsecTeams,
which replaces any Teams session already open in this shell.
See that command for why
Teams requires a DIRECTORY ROLE on top of app permissions.

Policies apply per user, and the Global policy is what a user gets unless they are
assigned another.
A permissive custom policy assigned to nobody is not a finding; one
assigned to everyone is.
This command reads the policies, not their assignments.

## RELATED LINKS
