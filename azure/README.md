# Azure infrastructure for `msec`

Provisions the Azure resources behind the [msec](../Msec) PowerShell module:

| Resource | Purpose |
|---|---|
| **Key Vault** (`Microsoft.KeyVault/vaults`) | Holds the certificate that authenticates the msec app registration. RBAC-enabled. Soft-delete + purge protection on by default. |
| **Storage Account (ADLS Gen2)** + `scores` container | Holds monthly score snapshots that Power BI can plot trends from. StorageV2 with hierarchical namespace (Data Lake), Standard_LRS, Hot. Shared-key disabled (AAD-only). HTTPS + TLS 1.2 enforced. |

## What is **not** in this template

- **RBAC role assignments** on either resource — managed outside this template.
- The Entra **app registration** — created at runtime by `New-MsecApp` via Microsoft Graph.
- The **certificate itself** — issued inside the vault by `New-MsecApp` via `Add-AzKeyVaultCertificate`.
- Writing **score snapshots** into the storage account — that's a job for a scheduled run of the msec module (see "Next step" below).

## Roles you'll need to grant (elsewhere)

Both resources are RBAC-only; whoever manages role assignments should grant:

| Role (built-in) | On | To whom | Why |
|---|---|---|---|
| **Key Vault Certificates Officer** | Key Vault | Setup admin (runs `New-MsecApp` once) | Create the certificate. |
| **Key Vault Certificate User** | Key Vault | Report users (run `Connect-Msec`) | Read cert metadata + tags. |
| **Key Vault Crypto User** | Key Vault | Report users | Sign JWT client assertions via Key Vault. |
| **Storage Blob Data Contributor** | Storage Account | Whoever appends snapshots (the report-generating identity) | Upload the monthly CSV. |
| **Storage Blob Data Reader** | Storage Account | Power BI users / Power BI Service workspace identity | Read the snapshots for reporting. |

Note: msec does **not** need *Key Vault Secrets User* — the certificate's private key never leaves the vault.

## Power BI access

Because shared-key auth is disabled, Power BI connects via **AAD (OAuth2 organizational account)**:

- **Power BI Desktop**: Get Data → Azure → **Azure Data Lake Storage Gen2**, paste the `dfsEndpoint` URL, choose *Organizational account* and sign in. (The "Azure Blob Storage" connector also works against ADLS Gen2, but the ADLS Gen2 connector understands the directory hierarchy properly.)
- **Power BI Service** (scheduled refresh): use a service principal or the workspace's managed identity with *Storage Blob Data Reader* on the account. Configure under *Workspace settings → Data source credentials*.

The endpoints are in the deployment outputs:
- `dfsEndpoint` — for the ADLS Gen2 connector (preferred when HNS is on)
- `blobEndpoint` — for the legacy blob connector / tools that don't know about HNS
- `scoresContainerName` — the container (a.k.a. "filesystem" in ADLS Gen2 terminology)

## Deploy

1. Create (or reuse) a resource group:
   ```bash
   az group create -n rg-mysec -l westeurope
   ```
2. Copy the example params file to a real one (gitignored — see root `.gitignore`) and set unique `keyVaultName` + `storageAccountName`:
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

## What to do after the resources exist

```powershell
# One-time, by a setup admin (with Key Vault Certificates Officer on the vault):
Connect-AzAccount
New-MsecApp -KeyVaultName 'kv-mysec'
# New-MsecApp stamps the cert with AppId / TenantId tags so other users don't
# have to remember IDs - just the vault and (optionally) cert name.

# Per user, per session, by a report user (with Key Vault Certificate User + Crypto User):
Connect-AzAccount
Connect-Msec -KeyVaultName 'kv-mysec'   # defaults: CertificateName = 'msec-app'
Get-MsecSecureScore -Top 1 | Format-Table -AutoSize
```

## Next step: persisting snapshots

The storage account is provisioned but currently empty. To start trending scores in Power BI, the next step is a small msec helper (or a scheduled job) that runs `Get-MsecSecureScore -Top 1` (plus `Get-MsecDefenderScoreExposure` / `Get-MsecDefenderScoreDeviceConfiguration` if you want them too), serializes the combined snapshot to CSV/JSON, and uploads it to the `scores` container. Each monthly run leaves a new dated file behind; Power BI's *Folder* connector picks up all of them. Trend math (diff vs previous month, etc.) lives in the consumer — msec only ever returns point-in-time snapshots.

## Defaults worth knowing

- **Key Vault `enablePurgeProtection: true`** — once on it cannot be turned off, and the vault cannot be permanently deleted before `softDeleteRetentionInDays` elapses. Override to `false` in your `.bicepparam` for test/learning environments.
- **Storage `allowSharedKeyAccess: false`** — no account keys. Everything is AAD/RBAC. If a tool only supports key auth, this template won't let it in (which is the point).
- **Storage `isHnsEnabled: true`** (ADLS Gen2) — hierarchical namespace is set at creation and **cannot be disabled** later. Same cost as flat blob, gives you real directories, POSIX-style ACLs, and native compatibility with Synapse / Databricks / Fabric / OneLake. If you'd rather start with plain blob, change this to `false` *before* the first deployment.
- **`publicNetworkAccess: Enabled`** on both — fine for an internal tool consumed from admin laptops and Power BI. For production tightening, switch to private endpoints / IP allow-listing.
