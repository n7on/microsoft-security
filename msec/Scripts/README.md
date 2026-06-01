# Scripts

Bundled scripts that `Invoke-MsecVMScript` can run against Azure VMs via `Invoke-AzVMRunCommand`.

```
msec/Scripts/
├── Linux/
│   └── *.sh        ← bash scripts (CommandId: RunShellScript)
└── Windows/
    └── *.ps1       ← PowerShell scripts (CommandId: RunPowerShellScript)
```

## One function, `-Os` chooses the flavour

```powershell
Invoke-MsecVMScript -Os Linux   -ScriptName os-info
Invoke-MsecVMScript -Os Windows -ScriptName os-info
```

- `-ScriptName` tab-completes from `Scripts/<Os>/` (type `-Os Linux` first, then tab on
  `-ScriptName` to see only `.sh` scripts; with `-Os Windows`, only `.ps1`).
- Invalid `-ScriptName` produces a clear runtime error like
  `Linux script not found: /…/Scripts/Linux/<name>.sh` before any Azure work happens.
- Filter the pipeline to the OS you want — this function does not auto-route per-VM:

  ```powershell
  Search-MsecResourceGraph -ResourceType VM | Where-Object Os -eq 'Linux' |
      Invoke-MsecVMScript -Os Linux -ScriptName os-info
  ```

## Authoring tips

- Keep scripts **idempotent and read-only by default**. Anything you wouldn't want to run
  blindly across the fleet shouldn't live here.
- Write to stdout; the runner returns whatever the script printed.
- Linux: `#!/usr/bin/env bash` and `set -euo pipefail` for predictable exits.
- Windows: `$ErrorActionPreference = 'Stop'` for the same.
- Avoid interactive prompts — there's no terminal on the other end.
- Same name in both folders (e.g. `os-info.sh` and `os-info.ps1`) is the convention for
  "same check, two implementations" — just switch `-Os`.

## RBAC

The caller needs **`Virtual Machine Contributor`** (or finer-grained
`Microsoft.Compute/virtualMachines/runCommand/action`) on the target VMs. This is the user's
own Azure identity — the msec app registration is *not* involved here (msec's app permissions
cover Graph and Defender APIs, not ARM operations).
