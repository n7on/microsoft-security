# local-admins (macOS)

Inventories the members of the local `admin` group.

Not a Remediation — macOS has no equivalent. This is a **Custom attribute for
macOS**:

| Setting | Value |
|---|---|
| Intune blade | Devices → macOS → Custom attributes for macOS |
| Data type | String |
| Runs as | root, every 8 hours, by the Intune management agent |

Output is comma-separated and qualified by account source, or `none`:

```
AzureAD\user@company.com,CONTOSO\jdoe,Local\localadmin
```

| Prefix | Meaning |
|---|---|
| `AzureAD\<upn>` | Platform SSO / Entra-linked account |
| `<DOMAIN>\<name>` | legacy Active Directory mobile account |
| `Local\<name>` | local-only account |

## Two implementation notes worth keeping

**Membership is tested with `dseditgroup -o checkmember`, not by reading the
`GroupMembership` attribute** — that attribute misses members added by
GeneratedUID or through nesting.

**`printf`, not `echo`.** `/bin/sh` interprets backslash escapes in `echo`, so
`AzureAD\user` would lose the separator (`\a` becomes a bell character).

## Pairs with the Windows script

`Scripts/Intune/Windows/entra-local-admins/detect.ps1` answers the same question
for Windows. The two are deliberately asymmetric and it cannot be helped: Windows
shows the *derived* SAM-compatible name (`AzureAD\FirstnameLastname`), macOS gives
the real UPN. **Join on UPN, normalising the Windows side by SID — never on the
displayed name.**
