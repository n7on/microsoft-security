# Scripts

Bundled scripts run on remote machines through different **execution channels**.
Each channel is a separate top-level folder so scripts for one channel can't
accidentally be invoked through another.

```
Msec/Scripts/
├── VM/                ← Azure VM Run-Command (Invoke-MsecAzureVMScript)
│   ├── Linux/
│   │   └── *.sh      ← bash scripts (CommandId: RunShellScript)
│   └── Windows/
│       └── *.ps1     ← PowerShell scripts (CommandId: RunPowerShellScript)
└── Intune/            ← uploaded to Intune, not run by any msec function
    ├── Windows/
    │   └── <name>/
    │       ├── detect.ps1     ← exit 0 clean, exit 1 run the remediation
    │       ├── remediate.ps1  ← the fix. OPTIONAL - see below
    │       └── README.md
    └── macOS/
        └── <name>/
            ├── custom-attribute.sh  ← Custom attributes for macOS, not a Remediation
            └── README.md
```

**The remediation half is optional.** Intune allows a remediation with a detection
script and nothing else, which turns the *Pre-remediation detection output* column
into a fleet-wide inventory report. `entra-local-admins` is that shape;
`remove-local-admin` is a full pair.

**macOS has no Remediations feature.** Its equivalent is *Custom attributes for
macOS* — one script, returns one string, no detect/remediate split. Same folder
convention so the two platforms sit together.

## Intune/ is the exception to read-only

Every script under `VM/` is read-only and safe to run blindly across a fleet.
**Scripts under `Intune/` WRITE.** They are Intune Remediations: a detection half
that reports, and a remediation half that changes the machine on every device the
assignment covers.

They are also the one channel msec does not execute — you upload them to Intune,
which runs them on its own schedule. `Get-MsecIntuneScriptResult -Source Remediation`
reads back what they did.

Each remediation is a folder holding both halves plus a README covering the
settings it needs and the safety rails it relies on. Detection and remediation
are separate uploads and nothing in Intune enforces that they agree, so anything
configured in both — the account to act on, most obviously — is guarded by a test
in `Msec/Tests/IntuneRemediationScripts.Tests.ps1`.

Future channels follow the same shape — one folder per channel, OS subfolders
inside:

```
Msec/Scripts/
├── VM/                ← already exists
└── Xdr/               ← future: Defender XDR Live Response (Invoke-MsecXdrScript)
    ├── Linux/
    └── Windows/
```

The convention: the channel folder name matches the suffix of the runner
function (`Invoke-Msec<Channel>Script` → `Scripts/<Channel>/`).

## Convention: scripts emit a single JSON object on stdout

Each script outputs **one JSON object** with audit-relevant fields. `ConvertFrom-Json`
parses it natively; a single `ForEach-Object` produces the audit CSV without any msec
helper functions.

`ntp-status` (both `.sh` and `.ps1`) emits:

```json
{
  "NowUtc":       "2026-06-02T12:34:56Z",
  "TimeZone":     "UTC",
  "Synchronized": true,
  "NtpEnabled":   true,
  "Daemon":       "systemd-timesyncd",
  "Source":       "time.cloudflare.com",
  "Compliant":    true
}
```

`Compliant` is the A.8.17 verdict (synchronized AND a real upstream source). The
script computes it so consumers don't re-derive the rule — auditors filter on this
column directly.

A human running the script directly still gets readable output (JSON is text). The
parsing pipeline gets structured data without regex.

## CSV report (the audit-friendly path)

```powershell
Search-MsecAzureResourceGraph -ResourceType VM | Where-Object Running |
    Invoke-MsecAzureVMScript -ScriptName ntp-status -ThrottleLimit 8 |
    ForEach-Object {
        $j = if ($_.Output) { $_.Output | ConvertFrom-Json } else { $null }
        [PSCustomObject]@{
            VmName       = $_.VmName
            Location     = $_.Location
            Os           = $_.Os
            Status       = $_.Status
            Compliant    = $j.Compliant       # headline pass/fail for the auditor
            Synchronized = $j.Synchronized    # supporting fact
            NowUtc       = $j.NowUtc          # VM's own clock at check time
            TimeZone     = $j.TimeZone
            Source       = $j.Source
        }
    } |
    Sort-Object Os, VmName |
    Export-Csv "./ntp-evidence-$(Get-Date -Format 'yyyy-MM-dd').csv" -NoTypeInformation
```

One row per VM, **`Compliant`** first as the auditor's primary filter. VMs whose
script failed come through with `Status` populated and the JSON-sourced columns
left as `$null` — `Compliant` will be empty (not `$false`) in that case, which is
the right signal: "we didn't get a verdict for this VM, investigate".

> **Why `Sort-Object`?** With `-ThrottleLimit > 1`, output order is the order results
> *complete in*, not the order VMs were piped in. Sorting at the end gives a stable,
> reviewer-friendly CSV regardless of which VMs happened to finish first.

> **Per-VM timeout is on by default (300s).** Without it, one VM whose agent is
> wedged (rebooting, unhealthy `waagent`, network partition) would hang the entire
> parallel batch — Azure's own internal timeout is 45 minutes. The default wraps
> each call in a `ThreadJob` with `Wait-Job -Timeout 300`; a stuck VM yields a
> `Status=Failed` row whose `Error` says it timed out, and the rest of the audit
> completes normally. 300s clears even cold/slow VMs comfortably while bounding
> the worst case well below Azure's 45-minute default. Override via
> `-TimeoutSeconds 600` for very slow fleets, lower (e.g. 120) for tight runs,
> or `0` to disable entirely (mostly useful for unit tests that mock
> `Invoke-AzVMRunCommand`).

## When an auditor wants the raw per-VM output

The CSV above is a summary. When someone asks for "the actual output, not just a
summary", keep the `Output` column — it is the script's JSON exactly as the VM
emitted it, so it stands on its own as evidence:

```powershell
... | Select-Object VmName, Status, Output | Export-Csv ./eset-raw.csv -NoTypeInformation
```

## Filtering VMs by OS

`Invoke-MsecAzureVMScript` requires `-Os`, so filter to that OS first:

```powershell
Search-MsecAzureResourceGraph -ResourceType VM | Where-Object Os -eq 'Linux' |
    Invoke-MsecAzureVMScript -Os Linux -ScriptName ntp-status
```

If you prefer `Get-AzVM`, you'll need a `Where-Object` clause because OS lives in a
nested property:

```powershell
Get-AzVM | Where-Object { $_.StorageProfile.OsDisk.OsType -eq 'Linux' } |
    Invoke-MsecAzureVMScript -Os Linux -ScriptName ntp-status
```

## Authoring new check scripts

- **Read-only, idempotent**. Anything you wouldn't want to run blindly across the fleet
  shouldn't live here.
- **Single JSON object on stdout.** PascalCase keys to match PowerShell convention so
  the flattened CSV columns look right (`Synchronized` not `synchronized`).
- Linux: `#!/usr/bin/env bash` — no strict mode if you want partial results when a
  sub-tool is missing.
- Windows: `$ErrorActionPreference = 'Continue'` so individual probe failures don't
  abort the script.
- Same base name in both folders (e.g. `ntp-status.sh` and `ntp-status.ps1`) lets the
  caller use `-ScriptName ntp-status` with either `-Os Linux` or `-Os Windows`.

## RBAC

The caller needs **`Virtual Machine Contributor`** (or finer-grained
`Microsoft.Compute/virtualMachines/runCommand/action`) on the target VMs. This is the
user's own Azure identity — the msec app registration is *not* involved here (msec's
app permissions cover Graph and Defender APIs, not ARM operations).
