# entra-local-admins

Inventories the **Microsoft Entra** principals in the local Administrators group.

Detection-only: there is no `remediate.ps1`. Intune allows a remediation with a
detection script and nothing else, which turns the **Pre-remediation detection
output** column into a fleet-wide inventory report.

| Exit | Meaning |
|---|---|
| `0` | the inventory ran — output is `AzureAD\a@x.com;AzureAD\b@x.com` or `None` |
| `1` | the group could not be enumerated at all — output is `ERROR: ...` |

Exit 0 means *the collection worked*, not *the device is clean*. Read the output
line, not the exit code.

## Reading it back

```powershell
Get-MsecIntuneScriptResult -Source Remediation |
    Where-Object ScriptName -like '*EntraLocalAdmin*' |
    Sort-Object Output, DeviceName |
    Format-Table DeviceName, State, Output
```

## Known limitation

Unresolvable members are **omitted** from the output line — a raw SID is an
unstable inventory value. They are counted and written to the verbose stream with
the object GUID decoded, which Intune does not capture, so `-Verbose` on the
device lists them.

The trade-off: on a device where *every* Entra admin is unresolvable this prints
`None`, which reads as "no Entra local admins" when there are some. Exit is still
`0` because the collection itself worked. The `$skipped` count is the hook if that
distinction ever needs surfacing.

## Pairs with the macOS script

`Scripts/Intune/macOS/local-admins/custom-attribute.sh` answers the same question
for Macs. **Join the two on UPN, never on the displayed name** — Windows shows a
derived SAM-compatible name and macOS gives the real UPN.
