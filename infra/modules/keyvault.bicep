param location string
param suffix string
param env string
param tags object
param operatorObjectId string
param logAnalyticsId string

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${env}-ahds-${suffix}'
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: null
    publicNetworkAccess: 'Enabled'
    networkAcls: { defaultAction: 'Allow', bypass: 'AzureServices' }
  }
}

// Key Vault Secrets Officer for the operator, so onboard-payer.ps1 can write
// payer credentials straight from Entra into the vault without touching disk.
resource kvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(operatorObjectId)) {
  scope: kv
  name: guid(kv.id, operatorObjectId, 'kv-secrets-officer')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    principalId: operatorObjectId
    principalType: 'User'
  }
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: kv
  name: 'to-law'
  properties: {
    workspaceId: logAnalyticsId
    logs: [ { categoryGroup: 'audit', enabled: true } ]
  }
}

output keyVaultName string = kv.name
output keyVaultUri string = kv.properties.vaultUri
