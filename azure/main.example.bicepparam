// Example parameters file - the ONLY .bicepparam committed to git.
//
// Per-environment convention: copy this to azure/<env>.bicepparam, one per environment,
// and fill in real values. Everything matching *.bicepparam is gitignored except
// *.example.bicepparam, so your real files never get committed:
//
//   cp azure/main.example.bicepparam azure/dev.bicepparam
//   cp azure/main.example.bicepparam azure/prod.bicepparam
//   cp azure/main.example.bicepparam azure/china.bicepparam
//
// Deploy a specific environment by pointing --parameters at its file:
//
//   az deployment group create \
//     --resource-group rg-mysec-prod \
//     --template-file ./azure/main.bicep \
//     --parameters ./azure/prod.bicepparam
//
// Azure China: set the CLI to that cloud first (az cloud set --name AzureChinaCloud),
// log in, then deploy with china.bicepparam.

using './main.bicep'

// Globally unique, 3-24 chars, alphanumeric + dashes.
param keyVaultName = 'kv-CHANGEME'

param tags = {
  application: 'msec'
  purpose: 'security-posture-reporting'
  environment: 'CHANGEME'
}
