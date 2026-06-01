# Scripts

Bundled scripts that `Invoke-MsecVMScriptLinux` and `Invoke-MsecVMScriptWindows` can run
against Azure VMs via `Invoke-AzVMRunCommand`.

```
msec/Scripts/
├── Linux/
│   └── *.sh        ← bash scripts (CommandId: RunShellScript)
└── Windows/
    └── *.ps1       ← PowerShell scripts (CommandId: RunPowerShellScript)
```

## Two functions, one per OS

Splitting by OS gives a few things at once:

- **Parameter-binding validation.** `-ScriptName` on `Invoke-MsecVMScriptLinux` only accepts
  names that exist in `Scripts/Linux/`; on `Invoke-MsecVMScriptWindows`, only names in
  `Scripts/Windows/`. You cannot accidentally aim a Linux-only script at Windows or vice
  versa - the binder rejects it before the function runs.
- **Tab completion** for `-ScriptName` from the correct folder.
- **No OS-detection inside the function**, which means the runtime stays simple.

The trade-off is that you must filter the pipeline to one OS before piping in.

## Filtering VMs by OS

The natural pairing is `Search-MsecGraph -ResourceType VM` (KQL/Graph/VM/All.kql), which
returns the flat shape `Invoke-MsecVMScript{Linux,Windows}` binds to. Filter in PowerShell:

```powershell
Search-MsecGraph -ResourceType VM | Where-Object Os -eq Linux   | Where-Object Running |
    Invoke-MsecVMScriptLinux   -ScriptName os-info

Search-MsecGraph -ResourceType VM | Where-Object Os -eq Windows | Where-Object Running |
    Invoke-MsecVMScriptWindows -ScriptName os-info
```

If you prefer `Get-AzVM`, you'll need a `Where-Object` clause because OS lives in a nested
property:

```powershell
Get-AzVM | Where-Object { $_.StorageProfile.OsDisk.OsType -eq 'Linux' } |
    Invoke-MsecVMScriptLinux -ScriptName os-info
```

## Authoring tips

- Keep scripts **idempotent and read-only by default**. Anything you wouldn't want to run
  blindly across the fleet shouldn't live here.
- Write to stdout; the runner returns whatever the script printed.
- Linux: `#!/usr/bin/env bash` and `set -euo pipefail` for predictable exits.
- Windows: `$ErrorActionPreference = 'Stop'` for the same.
- Avoid interactive prompts - there's no terminal on the other end.
- Same name in both folders (e.g. `os-info.sh` and `os-info.ps1`) is the convention for
  "same check, two implementations" - just call the two OS-specific runners.

## RBAC

The caller needs **`Virtual Machine Contributor`** (or finer-grained
`Microsoft.Compute/virtualMachines/runCommand/action`) on the target VMs. This is the user's
own Azure identity - the msec app registration is *not* involved here (msec's app permissions
cover Graph and Defender APIs, not ARM operations).
