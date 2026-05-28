// Example parameters file. Copy to e.g. prod.bicepparam (gitignored) and fill in real values:
//
//   cp azure/main.example.bicepparam azure/prod.bicepparam
//
// Deploy with:
//   az deployment group create \
//     --resource-group rg-mysec \
//     --template-file ./azure/main.bicep \
//     --parameters ./azure/prod.bicepparam

using './main.bicep'

// Globally unique, 3-24 chars, alphanumeric + dashes.
param keyVaultName = 'kv-CHANGEME'

// Globally unique, 3-24 chars, lowercase letters + digits only (no dashes).
param storageAccountName = 'stCHANGEME'

param tags = {
  application: 'msec'
  purpose: 'security-posture-reporting'
}
