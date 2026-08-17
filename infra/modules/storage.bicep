param location string
param suffix string
param env string
param tags object
param logAnalyticsId string

var name = 'st${env}ahds${suffix}'

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    // Key auth disabled: $import/$export must use managed identity, which is the
    // whole point of the RBAC wiring in modules/rbac.bicep.
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    encryption: {
      requireInfrastructureEncryption: false
      services: {
        blob: { enabled: true, keyType: 'Account' }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

resource blob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: sa
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 7 }
  }
}

// pdex       -> inbound NDJSON staged for $import (mirrors Providence's real container name)
// export     -> $export destination; payers collect from here through APIM
// quarantine -> resources that failed $validate, plus their OperationOutcome
var containers = [ 'pdex', 'export', 'quarantine' ]

resource c 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [for n in containers: {
  parent: blob
  name: n
  properties: { publicAccess: 'None' }
}]

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: blob
  name: 'to-law'
  properties: {
    workspaceId: logAnalyticsId
    logs: [
      { category: 'StorageRead', enabled: true }
      { category: 'StorageWrite', enabled: true }
    ]
  }
}

output storageAccountName string = sa.name
output storageAccountId string = sa.id
output blobEndpoint string = sa.properties.primaryEndpoints.blob
