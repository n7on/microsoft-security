// Infrastructure for the msec PowerShell module.
//
// Provisions:
//   - A Key Vault (RBAC-enabled, soft-delete + purge protection on by default).
//   - A Storage Account + blob container for monthly score snapshots that Power BI can read.
//
// Out of scope (handled elsewhere):
//   - Role assignments on these resources (managed outside this template).
//   - The Entra app registration (created at runtime by New-MsecApp via Microsoft Graph).
//   - The certificate itself (issued inside Key Vault by New-MsecApp via
//     Add-AzKeyVaultCertificate).

targetScope = 'resourceGroup'

@description('Globally-unique name for the Key Vault (3-24 chars, alphanumeric + dashes).')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('Globally-unique name for the Storage Account (3-24 chars, lowercase letters + digits only).')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Name of the blob container that holds score snapshots. Power BI reads from this.')
param scoresContainerName string = 'scores'

@description('Azure region for the resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Entra ID tenant the Key Vault binds to. Defaults to the subscription tenant.')
param tenantId string = subscription().tenantId

@description('Soft-delete retention in days. Min 7, max 90.')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 30

@description('Enable purge protection. Strongly recommended; once enabled, cannot be turned off and the vault cannot be permanently deleted before retention expires.')
param enablePurgeProtection bool = true

@description('Tags applied to all resources.')
param tags object = {}

resource kv 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    // Setting to false would be rejected once enabled; we only emit the property when true.
    enablePurgeProtection: enablePurgeProtection ? true : null
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Storage account for score snapshots that Power BI reads.
// - StorageV2 + isHnsEnabled: ADLS Gen2 (Data Lake) - real directories, POSIX-style ACLs,
//   native fit for Fabric/OneLake/Synapse if reporting ever grows past Power BI Desktop.
//   NOTE: HNS is set at creation and CANNOT be disabled later.
// - Standard_LRS / Hot: cheapest sensible tier for monthly CSV/Parquet files.
// - Shared-key (account key) access disabled: AAD-only auth, matches msec's no-secrets stance.
// - HTTPS only, TLS 1.2 min, public BLOB access disabled (no anonymous reads).
// - Public network access stays enabled with default Allow so Power BI Desktop/Service can
//   reach it without extra plumbing. Tighten with private endpoints later if you want.
resource sa 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    isHnsEnabled: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: sa
  name: 'default'
}

resource scoresContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobServices
  name: scoresContainerName
  properties: {
    publicAccess: 'None'
  }
}

output keyVaultName string = kv.name
output keyVaultUri string = kv.properties.vaultUri
output keyVaultResourceId string = kv.id
output storageAccountName string = sa.name
output blobEndpoint string = sa.properties.primaryEndpoints.blob
output dfsEndpoint string = sa.properties.primaryEndpoints.dfs
output scoresContainerName string = scoresContainer.name
