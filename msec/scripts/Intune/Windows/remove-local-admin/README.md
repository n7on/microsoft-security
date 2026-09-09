# remove-local-admin

Removes a specific account from the local Administrators group, as an Intune
**Remediation** (formerly Proactive Remediation).

| File | Role | Exit codes |
|---|---|---|
| `detect.ps1` | Is the account an administrator? | `0` not a member · `1` member, run remediation · *throw* group unreadable |
| `remediate.ps1` | Remove it | `0` gone (or already gone) · `1` refused or still present |

## Before you upload

**Edit `$TargetAccount` in BOTH files.** Intune remediation scripts take no
parameters, so the account is baked in. The two files are separate uploads and
nothing in Intune enforces that they agree — a mismatch means detection fires on
one account while remediation removes another. `msec/tests/IntuneRemediationScripts.Tests.ps1`
fails if they drift apart in this repo.

Accepted forms, most to least precise:

```
S-1-5-21-...-1013      SID - nothing can rename it out from under you
CONTOSO\legacy-admin   domain account
AzureAD\jane@x.com     Entra-joined device
localadmin             local account
```

## Intune settings

| Setting | Value |
|---|---|
| Run this script using the logged-on credentials | **No** — needs SYSTEM |
| Run script in 64-bit PowerShell | **Yes** |
| Enforce script signature check | your call |

## This one writes

Every other bundled script in this module is read-only. This one changes a
security group on every device the remediation is assigned to. Assign it to a
pilot group first, read the **Pre-remediation detection output** column for a
cycle, and widen only once the accounts it reports are the ones you expect.

## Safety rails

Both are checked *before* anything is removed, so a refusal leaves the group
exactly as it was:

- **The built-in Administrator is protected** (the account whose SID ends `-500`,
  whatever it has been renamed to). Removing it from its own group is how a
  device ends up with no usable local administrator. Override with
  `$ProtectBuiltInAdministrator = $false`.
- **The group is never emptied.** A device with no local administrators cannot be
  recovered locally, and a fleet-wide assignment would do it everywhere at once.

After removing, the script **re-reads the group** rather than trusting the call.
The WinNT provider reports success for a removal that a policy or a pending
reboot quietly undid, and a remediation that says *fixed* while the account is
still an administrator is worse than one that says *failed*.

## Two implementation notes worth keeping

**The group is resolved by SID (`S-1-5-32-544`), never by name.** `Administrators`
is localised — `Administratoren`, `Administradores`. A script that hard-codes the
English name finds no group at all on those builds and reports every one of them
as clean.

**Members are enumerated through ADSI, not `Get-LocalGroupMember`.** That cmdlet
throws `Failed to compare two elements in the array` whenever the group holds a
SID it cannot resolve — an orphaned account from a deleted domain user, or an
Entra principal on some builds. It throws rather than skipping, so *one* stale
member makes the whole group unreadable.

## Checking the result

```powershell
Get-MsecIntuneScriptResult -Source Remediation |
    Where-Object ScriptName -like 'remove-local-admin*' |
    Sort-Object State, DeviceName |
    Format-Table DeviceName, State, Output
```
