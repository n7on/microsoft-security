# Azure infrastructure for `msec`

Provisions the Key Vault that holds the certificate the [msec](../msec) PowerShell module uses for app authentication.

## What gets created

| Resource | Purpose |
|---|---|
| **Key Vault** (`Microsoft.KeyVault/vaults`) | Stores the certificate that authenticates the msec app registration. RBAC-enabled. Soft-delete + purge protection on by default. |

## What is **not** in this template

- **RBAC role assignments on the vault** — managed outside this template.
- The Entra **app registration** — created at runtime by `New-MsecApp` via Microsoft Graph.
- The **certificate itself** — issued inside the vault by `New-MsecApp` via `Add-AzKeyVaultCertificate`.

## Roles you'll need to grant (elsewhere)

The vault is RBAC-only; whoever manages role assignments should grant:

| Role (built-in) | To whom | Why |
|---|---|---|
| **Key Vault Certificates Officer** | The setup admin who will run `New-MsecApp` | Lets them create the cert inside the vault. |
| **Key Vault Certificate User** | Anyone who will run `Connect-Msec` | Read the cert's metadata (thumbprint + key name) — the JWT `x5t` header needs the thumbprint. |
| **Key Vault Crypto User** | Anyone who will run `Connect-Msec` | Sign the JWT client assertion via the Key Vault Sign API. **The private key never leaves the vault.** |

Note: report users do **not** need *Key Vault Secrets User*. msec deliberately avoids fetching the PFX/private key — Key Vault performs the signing.

## Deploy

1. Create (or reuse) a resource group:
   ```bash
   az group create -n rg-mysec -l westeurope
   ```
2. Copy the example params file to a real one (gitignored — see root `.gitignore`) and set a globally-unique `keyVaultName`:
   ```bash
   cp azure/main.example.bicepparam azure/prod.bicepparam
   # edit azure/prod.bicepparam
   ```
3. Deploy:
   ```bash
   az deployment group create \
     --resource-group rg-mysec \
     --template-file ./azure/main.bicep \
     --parameters ./azure/prod.bicepparam
   ```
   PowerShell equivalent:
   ```powershell
   New-AzResourceGroupDeployment `
     -ResourceGroupName rg-mysec `
     -TemplateFile ./azure/main.bicep `
     -TemplateParameterFile ./azure/prod.bicepparam
   ```

## What to do after the vault exists

```powershell
# One-time, by a setup admin (with Key Vault Certificates Officer on the vault):
Connect-AzAccount
New-MsecApp -KeyVaultName 'kv-mysec'
# New-MsecApp stamps the cert with AppId / TenantId tags so other users don't
# have to remember IDs - just the vault and (optionally) cert name.

# Per user, per session, by a report user (with Key Vault Certificate User + Crypto User):
Connect-AzAccount
Connect-Msec -KeyVaultName 'kv-mysec'   # defaults: CertificateName = 'msec-app'
Get-MsecScoreSummary | Format-Table -AutoSize
```

## Defaults worth knowing

- `enablePurgeProtection: true` — recommended, but **once on it cannot be turned off**, and the vault cannot be permanently deleted before `softDeleteRetentionInDays` elapses. If that is too strict for a learning environment, override to `false` in your `.bicepparam`.
- `publicNetworkAccess: Enabled`, `networkAcls.defaultAction: Allow` — fine for an internal tool consumed from admin laptops. For production tightening, switch to private endpoints / IP allow-listing.
- Standard SKU — sufficient; the Premium HSM SKU is only needed if you must keep the private key in an HSM.
