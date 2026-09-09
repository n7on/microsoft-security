<#
    Intune remediation - REMEDIATION half. Runs only when detect.ps1 exited 1.

    Removes a specific account from the local Administrators group.

        exit 0  - the account is not a member any more, either because this removed it or
                  because it was already gone. Idempotent on purpose: Intune re-runs
                  remediations, and a second run must not report failure.
        exit 1  - the removal was refused by a safety rail, or it failed and the account is
                  STILL a member. Either way the machine needs a human.

    THIS SCRIPT WRITES. Every other bundled script in this module is read-only; this one
    changes a security group on every device the remediation is assigned to. Scope the
    assignment to a pilot group first and read the detection output before widening it.

    KEEP $TargetAccount IDENTICAL TO detect.ps1. They are separate uploads and nothing
    enforces that they agree - a mismatch means detection fires on one account and
    remediation removes a different one. IntuneRemediationScripts.Tests.ps1 fails if they
    drift apart in this repo.
#>

#-------------------------------------------------------------------------------------
$TargetAccount = 'AzureAD\legacy.admin@contoso.com'

# Refuse to remove the built-in local Administrator (the account whose SID ends -500),
# whatever it has been renamed to. Removing it from its own group is how a device ends up
# with no usable local administrator at all. Set to $false only deliberately.
$ProtectBuiltInAdministrator = $true
#-------------------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

# ---- shared with detect.ps1 ---------------------------------------------------------
#
# Duplicated verbatim on purpose: Intune uploads each script as a single standalone file,
# so there is nowhere shared to put it. Keep the two copies in step.

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
# ---- act ----------------------------------------------------------------------------

$before = @(Get-AdminGroupMember)
$groupName = if ($before.Count) { $before[0].GroupName } else { 'Administrators' }
$targets = @($before | Where-Object { Test-TargetMatch $_ })

if (-not $targets.Count) {
    # Already gone. Not a failure: Intune re-runs remediations, and something else may have
    # fixed it between detection and now.
    Write-Output "OK: '$TargetAccount' is not a member of $groupName; nothing to remove."
    exit 0
}

# ---- safety rails -------------------------------------------------------------------
#
# Checked BEFORE anything is removed, so a refusal leaves the group exactly as it was.

foreach ($target in $targets) {
    if ($ProtectBuiltInAdministrator -and $target.Sid -match '-500$') {
        Write-Output "REFUSED: '$($target.Qualified)' [$($target.Sid)] is the built-in Administrator. Removing it from $groupName can leave this device with no usable local administrator. Set `$ProtectBuiltInAdministrator = `$false to override."
        exit 1
    }
}

# NEVER EMPTY THE GROUP. A device with no local administrators cannot be recovered locally,
# and a remediation assigned fleet-wide would do it everywhere at once. Counting what is LEFT
# rather than what is going is the check that survives the group containing the target twice.
$remaining = @($before | Where-Object { -not (Test-TargetMatch $_) })
if (-not $remaining.Count) {
    Write-Output "REFUSED: '$TargetAccount' is the only member of $groupName. Removing it would leave this device with no local administrator at all."
    exit 1
}

# ---- remove -------------------------------------------------------------------------

$group = [ADSI] "WinNT://./$groupName,group"
$removed = @()
$failed = @()

foreach ($target in $targets) {
    # Removed BY SID where we have one. A name is ambiguous the moment two directories are
    # in play - a local 'admin' and a domain 'admin' both answer to the bare name - and for
    # an Entra member the ADSI name is the SAM-compatible one, which is not what was matched
    # on. The SID form is the only one certain to remove the principal that was found.
    $path = if ($target.Sid) { "WinNT://$($target.Sid)" }
            elseif ($target.Domain) { "WinNT://$($target.Domain)/$($target.Name)" }
            else { "WinNT://./$($target.Name)" }

    try {
        $group.PSBase.Invoke('Remove', @($path))
        $removed += $target.Qualified
    }
    catch {
        $failed += "$($target.Qualified): $($_.Exception.Message)"
    }
}

# ---- verify -------------------------------------------------------------------------
#
# Re-read rather than trusting the call to have worked. The WinNT provider reports success
# for a Remove that a policy or a pending reboot quietly undid, and a remediation that says
# 'fixed' while the account is still an administrator is worse than one that says 'failed'.

$after = @(Get-AdminGroupMember | Where-Object { Test-TargetMatch $_ })

if ($after.Count) {
    $detail = if ($failed.Count) { $failed -join '; ' } else { 'the removal reported success but the account is still a member' }
    Write-Output "FAILED: '$TargetAccount' is still a member of ${groupName}. $detail"
    exit 1
}

Write-Output "REMOVED: '$($removed -join ', ')' from $groupName. $($remaining.Count) administrator(s) remain."
exit 0
