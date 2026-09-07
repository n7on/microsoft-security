<#
    Inventory the Microsoft Entra principals in the local Administrators group.

    Output contract (unchanged): a single line, semicolon-separated, or 'None'.
    Exit 0 = the inventory ran; exit 1 = it could not run at all.

    WHY NOT Get-LocalGroupMember
    ----------------------------
    Get-LocalGroupMember raises "A local account with the SID '<sid>' was not found."
    for any member it cannot resolve to a principal - an Entra user who has never signed
    in to this device, or an object since deleted from Entra. The membership is real; only
    the name lookup fails.

    That error is NON-TERMINATING, so the cmdlet still returns the members it could
    resolve. But under $ErrorActionPreference = 'Stop' it becomes terminating, one bad
    member aborts the enumeration, and the script reports ERROR while a machine full of
    Entra admins looks like a collection failure.

    So membership is read through the ADSI WinNT provider, which yields each member's raw
    objectSid and never fails on an unresolvable one.

    UNRESOLVABLE MEMBERS ARE OMITTED from the output line, on purpose: a raw SID is an
    unstable inventory value that means nothing to whatever consumes this. They are
    counted and written to the VERBOSE stream with the object id decoded, which Intune
    does not capture, so `-Verbose` on the device lists them without ever polluting the
    inventory.

    The trade-off to be aware of: on a device where EVERY Entra admin is unresolvable
    this prints 'None', which reads as "no Entra local admins" when there are some. The
    exit code is still 0 because the collection itself worked. If that distinction ever
    matters, the count in $skipped is the hook to surface it.
#>

$ErrorActionPreference = 'Stop'

# Entra ID's SID authority. Every Entra user or group placed in a local group appears
# under S-1-12-1-, with the object's GUID encoded as four little-endian uint32s. This
# prefix is the reliable way to tell an Entra principal from a local or domain one:
# PrincipalSource requires the member to have resolved, which is exactly what fails here.
$entraSidPrefix = 'S-1-12-1-'

function ConvertFrom-EntraSid {
    <#
        S-1-12-1-a-b-c-d -> object GUID. Each of the four values is one little-endian
        uint32 of the GUID's 16 bytes, so the GUID is the concatenation in order. Emitting
        it turns an unresolvable SID into something you can look up in Entra directly.
    #>
    param([string] $Sid)

    # Guarded rather than trusting the caller: a local or domain SID such as
    # S-1-5-21-a-b-c-rid also has eight parts, and would decode into a plausible-looking
    # GUID that means nothing at all.
    if (-not $Sid.StartsWith($entraSidPrefix)) { return $null }

    $parts = $Sid.Split('-')
    if ($parts.Count -ne 8) { return $null }

    try {
        $bytes = foreach ($p in $parts[4..7]) { [BitConverter]::GetBytes([uint32] $p) }
        return [guid][byte[]] $bytes
    }
    catch {
        return $null
    }
}

function Get-EntraUpnFromSid {
    <#
        Entra SID -> UPN, from the two IdentityStore caches Windows writes when an Entra
        principal is known to the device. Returns $null when neither has it, which is the
        normal answer for an Entra *group* (groups have no UPN) and for a user who has
        never signed in here.

        Both lookups are best-effort: a missing key is an expected outcome, not an error,
        hence -ErrorAction SilentlyContinue rather than letting $ErrorActionPreference
        turn an absent path into a terminating failure.
    #>
    param([string] $Sid)

    # Written per signed-in identity. The SID appears twice in the path by design.
    $cache = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$Sid\IdentityCache\$Sid" `
                              -Name 'UserName' -ErrorAction SilentlyContinue
    if ($cache.UserName -and $cache.UserName -like '*@*') { return $cache.UserName }

    # LogonCache is keyed by identity provider GUID, and which provider holds a given
    # account is not fixed, so every provider subkey is tried.
    $providers = Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\IdentityStore\LogonCache' `
                               -ErrorAction SilentlyContinue
    foreach ($provider in $providers) {
        $entry = Get-ItemProperty -Path "$($provider.PSPath)\Sid2Name\$Sid" `
                                  -Name 'IdentityName' -ErrorAction SilentlyContinue
        if ($entry.IdentityName -and $entry.IdentityName -like '*@*') { return $entry.IdentityName }
    }

    return $null
}

try {
    # Bind by well-known SID, not by the name 'Administrators': the group is renamed on
    # localised Windows ('Administratoren', 'Administratörer'), and a hardcoded English
    # name silently finds nothing on those machines.
    $adminSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $adminGroupName = $adminSid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]

    $group = [ADSI] "WinNT://./$adminGroupName,group"
    $members = @($group.PSBase.Invoke('Members'))

    $entraMembers = [System.Collections.Generic.List[string]]::new()
    $skipped = 0

    foreach ($member in $members) {
        # Read objectSid via late binding: these are raw COM objects, so the usual
        # property access does not apply.
        $sidValue = $null
        try {
            $sidBytes = $member.GetType().InvokeMember('objectSid', 'GetProperty', $null, $member, $null)
            $sidValue = [System.Security.Principal.SecurityIdentifier]::new([byte[]] $sidBytes, 0).Value
        }
        catch {
            $skipped++
            Write-Verbose "Skipped a group member whose SID could not be read: $($_.Exception.Message)"
            continue
        }

        if (-not $sidValue.StartsWith($entraSidPrefix)) { continue }

        # Try for a friendly name. This gives 'AzureAD\<sam-compatible name>'; it throws
        # IdentityNotMappedException for the object this script exists to survive, so the
        # failure is per-member and expected.
        $name = $null
        try {
            $name = [System.Security.Principal.SecurityIdentifier]::new($sidValue).
                Translate([System.Security.Principal.NTAccount]).Value
        }
        catch {
            $name = $null
        }

        # Replace the SAM-compatible account part with the UPN, keeping whatever domain
        # prefix LSA gave ('AzureAD' here, but not hardcoded - it is the authority's
        # answer, not ours to assert). Only the part after the LAST backslash is swapped;
        # a UPN never contains one, so the split is unambiguous.
        # The lookup is unconditional, NOT skipped when the translated name already
        # contains an '@': the 20-character SAM truncation can cut mid-domain and leave
        # 'anton@examp', which looks like a UPN and is not one. The cached UPN is
        # authoritative either way, so there is nothing to gain by guessing first.
        if ($name) {
            $upn = Get-EntraUpnFromSid -Sid $sidValue
            if ($upn) {
                $prefix = $name.Substring(0, $name.LastIndexOf('\') + 1)
                $name = "$prefix$upn"
            }
            else {
                # Left as the SAM-compatible name rather than dropped: it is still a real
                # member, and this is the expected shape for an Entra *group*, which has
                # no UPN to find.
                Write-Verbose "No UPN cached for $sidValue; reporting '$name' as translated."
            }
        }

        if ([string]::IsNullOrWhiteSpace($name)) {
            # Deliberately excluded from the output: a raw SID is an unstable inventory
            # value that tells whatever consumes this line nothing useful. It still goes
            # to the verbose stream, with the object id decoded, so a manual run can
            # chase it - and that stream never reaches Intune's captured output.
            $skipped++
            $guid = ConvertFrom-EntraSid -Sid $sidValue
            Write-Verbose $(if ($guid) { "Skipped unresolvable Entra member $sidValue (object $guid)" }
                            else       { "Skipped unresolvable Entra member $sidValue" })
            continue
        }

        $entraMembers.Add($name)
    }

    if ($skipped) {
        Write-Verbose "$skipped Entra member(s) of '$adminGroupName' could not be resolved and were omitted. Re-run with -Verbose on the device to list them."
    }

    if ($entraMembers.Count) {
        Write-Output (($entraMembers | Sort-Object -Unique) -join ';')
    }
    else {
        Write-Output 'None'
    }

    exit 0
}
catch {
    # Only a failure to enumerate the group at all reaches here now - not a single
    # member that would not resolve.
    Write-Output "ERROR: $($_.Exception.Message)"
    exit 1
}
