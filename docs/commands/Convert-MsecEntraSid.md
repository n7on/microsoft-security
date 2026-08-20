---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Convert-MsecEntraSid

## SYNOPSIS
Converts an Entra ID SID (S-1-12-1-...) to the object's GUID objectId, and
back again.

## SYNTAX

### FromSid (Default)
```
Convert-MsecEntraSid [-Sid] <String[]> [-Resolve] [<CommonParameters>]
```

### FromObjectId
```
Convert-MsecEntraSid [-ObjectId] <Guid[]> [-Resolve] [<CommonParameters>]
```

## DESCRIPTION
Cloud-only Entra accounts get a synthetic SID of the form

    S-1-12-1-\<a\>-\<b\>-\<c\>-\<d\>

where a..d are four unsigned 32-bit integers holding, little-endian, the
16 bytes of the object's Entra objectId.
The mapping is pure arithmetic:
no directory lookup is involved, and it is exactly reversible.
This is the
SID that shows up in Windows event logs, \`whoami /user\`, local group
membership, Intune detection scripts and NTFS ACLs on Entra-joined
devices - where the objectId you can actually search for in Entra is
nowhere in sight.

Both directions are supported: -Sid yields the objectId, -ObjectId yields
the SID.
Both parameters accept arrays and pipeline input, so a column of
SIDs from a log export can be piped straight in.

-Resolve additionally asks Graph what the object is (display name, UPN,
type), which turns the objectId into something human-readable.
That is
the only part of this command that needs a session and network access;
without -Resolve it works fully offline.

Expect roles, not just people.
Every directory object gets a SID of this
shape, including directoryRole objects - and on an Entra-joined device
that is how role-based local admin works: the local Administrators group
contains the SIDs of the Global Administrator and Azure AD Joined Device
Local Administrator roles rather than the SIDs of the people holding
them.
So a SID harvested from local group membership resolving to
ObjectType 'directoryRole' is the normal case, not a conversion error,
and it means "everyone currently in that role" - a set that changes
without the device changing.
Raw.roleTemplateId is the stable, tenant-
independent identifier for such a row; join on it to expand the role to
its actual holders with Get-MsecEntraRoleHolder.

Two caveats on role identity, both of which make roleTemplateId the only
field worth branching on:

First, the objectId a role SID decodes to is the per-tenant directoryRole
instance id, which differs between tenants, whereas roleTemplateId is the
same GUID everywhere.
Never hard-code a role SID from one tenant into a
detection script expected to run against another.

Second, DisplayName is whatever the directory says, which is not always
the name the portal shows.
Graph still returns Global Administrator under
its legacy name 'Company Administrator' (roleTemplateId
62e90394-69f5-4237-9190-012177145e10) - so a resolved row reading
'Company Administrator' IS Global Administrator.
Matching role names as
strings will miss it; matching roleTemplateId will not.

Note the boundary: only S-1-12-1 SIDs encode an objectId.
An on-premises
or local SID - S-1-5-21-\<domain\>-\<rid\>, the shape you get from AD DS or
from a local account - carries no GUID at all and cannot be converted;
those are rejected with an explanatory error rather than silently
producing a meaningless GUID.
Hybrid users have both kinds of SID, and
their on-prem one maps to Entra only via the onPremisesSecurityIdentifier
property in the directory.

## EXAMPLES

### EXAMPLE 1
```
Convert-MsecEntraSid -Sid 'S-1-12-1-2640853384-1293864314-2707107988-2394433369'
```

ObjectId 9d683988-cd7a-4d1e-9430-5ba15927b88e - paste that into the Entra
portal search, or into a Graph /users/\<id\> call.

### EXAMPLE 2
```
# Who is this, actually?
Convert-MsecEntraSid -Sid 'S-1-12-1-2640853384-1293864314-2707107988-2394433369' -Resolve
```

### EXAMPLE 3
```
# A column of SIDs harvested from local Administrators membership.
Get-Content .\admin-sids.txt | Convert-MsecEntraSid -Resolve |
    Format-Table Sid, ObjectId, UserPrincipalName, ObjectType
```

### EXAMPLE 4
```
# The other direction: what SID will this user appear as on a device?
Convert-MsecEntraSid -ObjectId 9d683988-cd7a-4d1e-9430-5ba15927b88e
```

### EXAMPLE 5
```
# The SID turned out to be a directory role. Expand it to the people it
# actually grants - that is who has local admin, not the role itself.
$row = Convert-MsecEntraSid -Sid 'S-1-12-1-...' -Resolve
Get-MsecEntraRoleHolder |
    Where-Object RoleTemplateId -eq $row.Raw.roleTemplateId
```

### EXAMPLE 6
```
# Cross-reference a pile of SIDs against the privileged population. PrincipalId
# is the assignee - the object the SID names - so it is populated on every row,
# including the group assignments where EffectiveId is $null. Match EffectiveId
# instead to catch SIDs belonging to people who inherited a role via a group.
$sids = Get-Content .\event-4624-sids.txt | Convert-MsecEntraSid
Get-MsecEntraRoleHolder | Where-Object PrincipalId -in $sids.ObjectId
```

## PARAMETERS

### -Sid
One or more Entra SIDs to convert to objectIds.
Must be of the form
S-1-12-1-\<a\>-\<b\>-\<c\>-\<d\>, case-insensitive.

```yaml
Type: String[]
Parameter Sets: FromSid
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: True (ByPropertyName, ByValue)
Accept wildcard characters: False
```

### -ObjectId
One or more Entra objectIds (GUIDs) to convert to SIDs.

```yaml
Type: Guid[]
Parameter Sets: FromObjectId
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: True (ByPropertyName, ByValue)
Accept wildcard characters: False
```

### -Resolve
Look the objectId up in Graph (/v1.0/directoryObjects/{id}) and add
DisplayName, UserPrincipalName and ObjectType to each row.
Requires a
Connect-Msec session and the 'Directory.Read.All' application permission.
An object that no longer exists - a deleted account whose SID survives in
an old log - resolves to ObjectType 'NotFound' rather than terminating
the whole batch.

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

### PSCustomObject per input value, with PSTypeName 'MsecEntraSid'.
## NOTES
Row shape:
  Sid       - the S-1-12-1 form (input or computed)
  ObjectId  - \[guid\], the Entra objectId
  Direction - 'SidToObjectId' or 'ObjectIdToSid', which of the two the
              caller asked for

With -Resolve, four more:
  DisplayName       - object's displayName, if any
  UserPrincipalName - for users; $null for groups, roles, service
                      principals, and devices
  ObjectType        - 'user', 'group', 'directoryRole',
                      'servicePrincipal', 'device', ...
derived from
                      Graph's @odata.type; 'NotFound' when the objectId
                      does not resolve
  Raw               - the directoryObject verbatim, which is where the
                      type-specific fields live: roleTemplateId for a
                      directoryRole, deviceId for a device, appId for a
                      service principal.
Kept out of the default table
                      view rather than flattened, so the row shape stays
                      the same whatever the SID turns out to point at.

The encoding is documented by Microsoft as part of Entra-joined device
behaviour, and the arithmetic is stable: \[BitConverter\] writes each
sub-authority little-endian and \[guid\]::new(\[byte\[\]\]) reads the first
three GUID fields little-endian from the same bytes, so the two cancel out
and a round-trip is byte-exact.

## RELATED LINKS
