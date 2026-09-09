<#
    Intune remediation - DETECTION half.

    Reports whether a specific account is a member of the local Administrators group.

        exit 0  - the account is NOT a member. Nothing to do.
        exit 1  - the account IS a member. Intune runs remediate.ps1.
        throw   - the group could not be read. Intune records a SCRIPT FAILURE and does
                  NOT run the remediation, which is the safe direction: a machine we
                  could not read is not a machine we should start removing admins from.

    CONFIGURE $TargetAccount BELOW BEFORE UPLOADING. Intune remediation scripts take no
    parameters, so the account is baked into the file. Upload one detect/remediate pair
    per account you want gone, and keep the value identical in both halves.

    Intune settings this expects:
        Run this script using the logged-on credentials : No   (needs SYSTEM)
        Run script in 64-bit PowerShell                 : Yes
#>

#-------------------------------------------------------------------------------------
# The account to look for. Any of these forms:
#
#   S-1-12-1-... / S-1-5-21-...   SID. Nothing can rename it out from under you, so
#                                 prefer it wherever you have it.
#   AzureAD\jane@contoso.com      Entra account BY UPN - see the note on Entra below.
#   jane@contoso.com              the bare UPN, same thing.
#   CONTOSO\jdoe                  Active Directory account.
#   localadmin                    local account.
$TargetAccount = 'AzureAD\legacy.admin@contoso.com'
#-------------------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

# Entra ID's SID authority. Every Entra user or group placed in a local group appears
# under S-1-12-1-, with the object's GUID encoded as four little-endian uint32s.
$EntraSidPrefix = 'S-1-12-1-'

function Get-EntraUpnFromSid {
    <#
        Entra SID -> UPN, from the two IdentityStore caches Windows writes when an Entra
        principal is known to the device.

        THIS IS WHAT MAKES MATCHING BY UPN POSSIBLE AT ALL. ADSI and LSA give an Entra
        member its SAM-COMPATIBLE name - 'AzureAD\JaneDoe' - never the UPN. Matching a
        target written as 'AzureAD\jane@contoso.com' against that fails every time, so
        the account stays an administrator and the detection reports the device clean.

        Returns $null when neither cache has it, which is the normal answer for an Entra
        GROUP (groups have no UPN) and for a user who has never signed in here.
    #>
    param([string] $Sid)

    # Written per signed-in identity. The SID appears twice in the path by design.
    $cache = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$Sid\IdentityCache\$Sid" `
                              -Name 'UserName' -ErrorAction SilentlyContinue
    if ($cache.UserName -and $cache.UserName -like '*@*') { return $cache.UserName }

    # LogonCache is keyed by identity provider GUID, and which provider holds a given
    # account is not fixed, so every provider subkey is tried.
    foreach ($provider in (Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\IdentityStore\LogonCache' -ErrorAction SilentlyContinue)) {
        $entry = Get-ItemProperty -Path "$($provider.PSPath)\Sid2Name\$Sid" `
                                  -Name 'IdentityName' -ErrorAction SilentlyContinue
        if ($entry.IdentityName -and $entry.IdentityName -like '*@*') { return $entry.IdentityName }
    }

    return $null
}

function Get-AdminGroupMember {
    <#
        Every member of the local Administrators group, with the identifiers needed to
        match one.

        THE GROUP IS BOUND BY SID, NEVER BY NAME. 'Administrators' is renamed on localised
        Windows - Administratoren, Administratörer - and a hardcoded English name silently
        finds nothing there, reporting every such machine as clean.

        MEMBERS COME FROM ADSI, NOT Get-LocalGroupMember. That cmdlet raises "A local
        account with the SID '<sid>' was not found" for any member it cannot resolve - an
        Entra user who has never signed in to this device, or an object since deleted from
        Entra. The membership is real; only the name lookup fails. The error is
        NON-TERMINATING, but under $ErrorActionPreference = 'Stop' it becomes terminating,
        so ONE unresolvable member aborts the whole enumeration and a machine full of Entra
        admins looks like a collection failure.
    #>
    $adminSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $groupName = $adminSid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]

    # 'WinNT://./' rather than the computer name: a machine renamed but not yet rebooted
    # still answers to '.', and would not answer to either name reliably.
    $group = [ADSI] "WinNT://./$groupName,group"

    # PSBase.Invoke, because an ADSI object can shadow Invoke with a directory method of
    # the same name.
    foreach ($member in @($group.PSBase.Invoke('Members'))) {
        $sid = $null; $name = $null; $domain = $null

        try {
            # Late binding: these are raw COM objects, so ordinary property access does
            # not apply.
            $bytes = $member.GetType().InvokeMember('objectSid', 'GetProperty', $null, $member, $null)
            $sid = [System.Security.Principal.SecurityIdentifier]::new([byte[]] $bytes, 0).Value
        }
        catch { }

        try {
            $name = $member.GetType().InvokeMember('Name', 'GetProperty', $null, $member, $null)
            $path = $member.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $member, $null)
            $parts = ($path -replace '^WinNT://', '') -split '/'
            if ($parts.Count -ge 2) { $domain = $parts[-2] }
        }
        catch { }

        # The UPN lookup is UNCONDITIONAL for an Entra member, deliberately not skipped
        # when $name already contains an '@'. The SAM-compatible name is truncated at 20
        # characters, which can cut mid-domain and leave 'anton@examp' - that looks like a
        # UPN and is not one. The cached UPN is authoritative either way.
        $upn = if ($sid -and $sid.StartsWith($EntraSidPrefix)) { Get-EntraUpnFromSid -Sid $sid } else { $null }

        [pscustomobject]@{
            Sid       = $sid
            Name      = $name
            Domain    = $domain
            Upn       = $upn
            # Same qualified shape the macOS inventory script emits, so the two platforms
            # line up: AzureAD\<upn> | <DOMAIN>\<name> | <COMPUTER>\<name>.
            Qualified = if ($upn -and $domain) { "$domain\$upn" }
                        elseif ($domain -and $name) { "$domain\$name" }
                        else { $name }
            GroupName = $groupName
        }
    }
}

function Test-TargetMatch {
    param($Member)

    if ($TargetAccount -match '^S-1-') { return ($Member.Sid -and $Member.Sid -eq $TargetAccount) }

    # Every form the same principal can legitimately be written as. The UPN forms are what
    # the IdentityStore lookup above exists to make possible.
    $candidates = @($Member.Name, $Member.Qualified, $Member.Upn)
    if ($Member.Upn -and $Member.Domain) { $candidates += "$($Member.Domain)\$($Member.Upn)" }

    return @($candidates | Where-Object { $_ -and $_ -eq $TargetAccount }).Count -gt 0
}

$members = @(Get-AdminGroupMember)
$groupName = if ($members.Count) { $members[0].GroupName } else { 'Administrators' }
$found = @($members | Where-Object { Test-TargetMatch $_ })

if (-not $found.Count) {
    Write-Output "OK: '$TargetAccount' is not a member of $groupName ($($members.Count) member(s))."
    exit 0
}

# Intune keeps roughly 2 KB of this and shows it in the 'Pre-remediation detection output'
# column, so it names what was found and its SID - which is what makes the removal that
# follows auditable rather than just a green tick.
$detail = ($found | ForEach-Object { "$($_.Qualified) [$($_.Sid)]" }) -join ', '
Write-Output "REMEDIATE: '$TargetAccount' is a member of ${groupName}: $detail"
exit 1
