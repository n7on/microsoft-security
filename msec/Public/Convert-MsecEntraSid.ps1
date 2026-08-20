function Convert-MsecEntraSid {
    <#
    .SYNOPSIS
        Converts an Entra ID SID (S-1-12-1-...) to the object's GUID objectId, and
        back again.

    .DESCRIPTION
        Cloud-only Entra accounts get a synthetic SID of the form

            S-1-12-1-<a>-<b>-<c>-<d>

        where a..d are four unsigned 32-bit integers holding, little-endian, the
        16 bytes of the object's Entra objectId. The mapping is pure arithmetic:
        no directory lookup is involved, and it is exactly reversible. This is the
        SID that shows up in Windows event logs, `whoami /user`, local group
        membership, Intune detection scripts and NTFS ACLs on Entra-joined
        devices - where the objectId you can actually search for in Entra is
        nowhere in sight.

        Both directions are supported: -Sid yields the objectId, -ObjectId yields
        the SID. Both parameters accept arrays and pipeline input, so a column of
        SIDs from a log export can be piped straight in.

        -Resolve additionally asks Graph what the object is (display name, UPN,
        type), which turns the objectId into something human-readable. That is
        the only part of this command that needs a session and network access;
        without -Resolve it works fully offline.

        Expect roles, not just people. Every directory object gets a SID of this
        shape, including directoryRole objects - and on an Entra-joined device
        that is how role-based local admin works: the local Administrators group
        contains the SIDs of the Global Administrator and Azure AD Joined Device
        Local Administrator roles rather than the SIDs of the people holding
        them. So a SID harvested from local group membership resolving to
        ObjectType 'directoryRole' is the normal case, not a conversion error,
        and it means "everyone currently in that role" - a set that changes
        without the device changing. Raw.roleTemplateId is the stable, tenant-
        independent identifier for such a row; join on it to expand the role to
        its actual holders with Get-MsecEntraRoleHolder.

        Two caveats on role identity, both of which make roleTemplateId the only
        field worth branching on:

        First, the objectId a role SID decodes to is the per-tenant directoryRole
        instance id, which differs between tenants, whereas roleTemplateId is the
        same GUID everywhere. Never hard-code a role SID from one tenant into a
        detection script expected to run against another.

        Second, DisplayName is whatever the directory says, which is not always
        the name the portal shows. Graph still returns Global Administrator under
        its legacy name 'Company Administrator' (roleTemplateId
        62e90394-69f5-4237-9190-012177145e10) - so a resolved row reading
        'Company Administrator' IS Global Administrator. Matching role names as
        strings will miss it; matching roleTemplateId will not.

        Note the boundary: only S-1-12-1 SIDs encode an objectId. An on-premises
        or local SID - S-1-5-21-<domain>-<rid>, the shape you get from AD DS or
        from a local account - carries no GUID at all and cannot be converted;
        those are rejected with an explanatory error rather than silently
        producing a meaningless GUID. Hybrid users have both kinds of SID, and
        their on-prem one maps to Entra only via the onPremisesSecurityIdentifier
        property in the directory.

    .PARAMETER Sid
        One or more Entra SIDs to convert to objectIds. Must be of the form
        S-1-12-1-<a>-<b>-<c>-<d>, case-insensitive.

    .PARAMETER ObjectId
        One or more Entra objectIds (GUIDs) to convert to SIDs.

    .PARAMETER Resolve
        Look the objectId up in Graph (/v1.0/directoryObjects/{id}) and add
        DisplayName, UserPrincipalName and ObjectType to each row. Requires a
        Connect-Msec session and the 'Directory.Read.All' application permission.
        An object that no longer exists - a deleted account whose SID survives in
        an old log - resolves to ObjectType 'NotFound' rather than terminating
        the whole batch.

    .EXAMPLE
        Convert-MsecEntraSid -Sid 'S-1-12-1-2640853384-1293864314-2707107988-2394433369'

        ObjectId 9d683988-cd7a-4d1e-9430-5ba15927b88e - paste that into the Entra
        portal search, or into a Graph /users/<id> call.

    .EXAMPLE
        # Who is this, actually?
        Convert-MsecEntraSid -Sid 'S-1-12-1-2640853384-1293864314-2707107988-2394433369' -Resolve

    .EXAMPLE
        # A column of SIDs harvested from local Administrators membership.
        Get-Content .\admin-sids.txt | Convert-MsecEntraSid -Resolve |
            Format-Table Sid, ObjectId, UserPrincipalName, ObjectType

    .EXAMPLE
        # The other direction: what SID will this user appear as on a device?
        Convert-MsecEntraSid -ObjectId 9d683988-cd7a-4d1e-9430-5ba15927b88e

    .EXAMPLE
        # The SID turned out to be a directory role. Expand it to the people it
        # actually grants - that is who has local admin, not the role itself.
        $row = Convert-MsecEntraSid -Sid 'S-1-12-1-...' -Resolve
        Get-MsecEntraRoleHolder |
            Where-Object RoleTemplateId -eq $row.Raw.roleTemplateId

    .EXAMPLE
        # Cross-reference a pile of SIDs against the privileged population. PrincipalId
        # is the assignee - the object the SID names - so it is populated on every row,
        # including the group assignments where EffectiveId is $null. Match EffectiveId
        # instead to catch SIDs belonging to people who inherited a role via a group.
        $sids = Get-Content .\event-4624-sids.txt | Convert-MsecEntraSid
        Get-MsecEntraRoleHolder | Where-Object PrincipalId -in $sids.ObjectId

    .OUTPUTS
        PSCustomObject per input value, with PSTypeName 'MsecEntraSid'.

    .NOTES
        Row shape:
          Sid       - the S-1-12-1 form (input or computed)
          ObjectId  - [guid], the Entra objectId
          Direction - 'SidToObjectId' or 'ObjectIdToSid', which of the two the
                      caller asked for

        With -Resolve, four more:
          DisplayName       - object's displayName, if any
          UserPrincipalName - for users; $null for groups, roles, service
                              principals, and devices
          ObjectType        - 'user', 'group', 'directoryRole',
                              'servicePrincipal', 'device', ... derived from
                              Graph's @odata.type; 'NotFound' when the objectId
                              does not resolve
          Raw               - the directoryObject verbatim, which is where the
                              type-specific fields live: roleTemplateId for a
                              directoryRole, deviceId for a device, appId for a
                              service principal. Kept out of the default table
                              view rather than flattened, so the row shape stays
                              the same whatever the SID turns out to point at.

        The encoding is documented by Microsoft as part of Entra-joined device
        behaviour, and the arithmetic is stable: [BitConverter] writes each
        sub-authority little-endian and [guid]::new([byte[]]) reads the first
        three GUID fields little-endian from the same bytes, so the two cancel out
        and a round-trip is byte-exact.
    #>
    [CmdletBinding(DefaultParameterSetName = 'FromSid')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'FromSid',
                   ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Sid,

        [Parameter(Mandatory, Position = 0, ParameterSetName = 'FromObjectId',
                   ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [guid[]] $ObjectId,

        [Parameter()]
        [switch] $Resolve
    )

    begin {
        if ($Resolve) { Assert-MsecSession }

        # An Entra SID is S-1-12-1 (authority 12 = 'Azure AD') plus exactly four
        # sub-authorities, each a uint32. Anything else is a different kind of SID
        # and must not be run through the arithmetic.
        $entraSidPattern = '^S-1-12-1-(\d+)-(\d+)-(\d+)-(\d+)$'

        $sidToGuid = {
            param([string] $Value)

            $trimmed = $Value.Trim()
            $match = [regex]::Match($trimmed, $entraSidPattern, 'IgnoreCase')
            if (-not $match.Success) {
                # Name the likely case rather than just rejecting the string: a
                # S-1-5-21 SID is the single most common thing to try here, and
                # "it is the wrong sort of SID" is more actionable than "invalid".
                $hint = if ($trimmed -match '^S-1-5-21-') {
                    " That is an on-premises or local account SID (S-1-5-21-...), which does not encode an Entra objectId. Only cloud-only Entra SIDs (S-1-12-1-...) can be converted; for a hybrid user, match it against the directory's onPremisesSecurityIdentifier property instead."
                }
                else {
                    " Expected the form S-1-12-1-<a>-<b>-<c>-<d>, four unsigned 32-bit sub-authorities."
                }
                throw "'$Value' is not an Entra ID SID.$hint"
            }

            $bytes = [System.Collections.Generic.List[byte]]::new()
            foreach ($group in $match.Groups[1..4]) {
                # [uint32] on an out-of-range literal throws a cast error whose
                # message does not mention the SID, so range-check it here.
                $number = [decimal] $group.Value
                if ($number -gt [uint32]::MaxValue) {
                    throw "'$Value' is not an Entra ID SID: the sub-authority '$($group.Value)' exceeds the 32-bit maximum ($([uint32]::MaxValue))."
                }
                $bytes.AddRange([BitConverter]::GetBytes([uint32] $number))
            }

            [guid]::new($bytes.ToArray())
        }

        $guidToSid = {
            param([guid] $Value)

            $bytes = $Value.ToByteArray()
            $parts = 0..3 | ForEach-Object { [BitConverter]::ToUInt32($bytes, $_ * 4) }
            'S-1-12-1-' + ($parts -join '-')
        }

        # /directoryObjects/{id} answers for any object type - user, group, service
        # principal, device - which is what we want, because a SID from a log does
        # not say which of those it is. A 404 becomes a row, not an exception: a
        # batch of SIDs from historical logs will legitimately contain deleted
        # accounts, and losing the whole batch over one of them is useless.
        $resolveObject = {
            param([guid] $Id)

            try {
                $obj = Invoke-MsecGraphRequest -Path "/v1.0/directoryObjects/$Id"
                $type = if ($obj.'@odata.type') {
                    ($obj.'@odata.type' -replace '^#?microsoft\.graph\.', '')
                }
                else {
                    'unknown'
                }

                [PSCustomObject]@{
                    DisplayName       = $obj.displayName
                    UserPrincipalName = $obj.userPrincipalName
                    ObjectType        = $type
                    Raw               = $obj
                }
            }
            catch {
                if ($_.Exception.Message -match '404|Not Found') {
                    Write-Verbose "objectId $Id not found in the directory (deleted object, or a SID from another tenant)."
                    return [PSCustomObject]@{
                        DisplayName       = $null
                        UserPrincipalName = $null
                        ObjectType        = 'NotFound'
                        Raw               = $null
                    }
                }
                if ($_.Exception.Message -match '403|Forbidden') {
                    throw "Forbidden when calling /directoryObjects. -Resolve needs the 'Directory.Read.All' application permission (admin consent required). Re-run New-MsecApp to add and consent it, or drop -Resolve to convert offline. Original error: $($_.Exception.Message)"
                }
                throw
            }
        }

        $emit = {
            param([string] $SidValue, [guid] $IdValue, [string] $Direction)

            $row = [ordered]@{
                PSTypeName = 'MsecEntraSid'

                Sid        = $SidValue
                ObjectId   = $IdValue
                Direction  = $Direction
            }

            if (-not $Resolve) {
                return [PSCustomObject] $row
            }

            $info = & $resolveObject $IdValue
            $row['DisplayName']       = $info.DisplayName
            $row['UserPrincipalName'] = $info.UserPrincipalName
            $row['ObjectType']        = $info.ObjectType
            $row['Raw']               = $info.Raw

            $obj = [PSCustomObject] $row
            # Front of the type list wins the format view, so a resolved row shows
            # its resolved columns; 'MsecEntraSid' is still on the object behind it.
            $obj.PSObject.TypeNames.Insert(0, 'MsecEntraSidResolved')
            $obj
        }
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'FromSid') {
            foreach ($value in $Sid) {
                $id = & $sidToGuid $value
                & $emit $value.Trim() $id 'SidToObjectId'
            }
        }
        else {
            foreach ($value in $ObjectId) {
                & $emit (& $guidToSid $value) $value 'ObjectIdToSid'
            }
        }
    }
}
