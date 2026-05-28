// Infrastructure for the msec PowerShell module.
//
// Provisions:
//   - A Key Vault (RBAC-enabled, soft-delete + purge protection on by default).
//
// Out of scope (handled elsewhere):
//   - Role assignments on the vault (managed outside this template).
//   - The Entra app registration (created at runtime by New-MsecApp via Microsoft Graph).
//   - The certificate itself (issued inside Key Vault by New-MsecApp via
//     Add-AzKeyVaultCertificate).

targetScope = 'resourceGroup'

@description('Globally-unique name for the Key Vault (3-24 chars, alphanumeric + dashes).')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('Azure region for the Key Vault. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Entra ID tenant the Key Vault binds to. Defaults to the subscription tenant.')
param tenantId string = subscription().tenantId

@description('Soft-delete retention in days. Min 7, max 90.')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 30

@description('Enable purge protection. Strongly recommended; once enabled, cannot be turned off and the vault cannot be permanently deleted before retention expires.')
param enablePurgeProtection bool = true

@description('Tags applied to the Key Vault.')
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

output keyVaultName string = kv.name
output keyVaultUri string = kv.properties.vaultUri
output keyVaultResourceId string = kv.id
