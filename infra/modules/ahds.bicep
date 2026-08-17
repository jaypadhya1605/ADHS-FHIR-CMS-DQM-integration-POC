param location string
param suffix string
param env string
param tags object
param payers array
param storageAccountName string
param logAnalyticsId string

// AHDS workspace names are alphanumeric ONLY (no hyphens), 3-24 chars.
var workspaceName = 'ahds${env}${suffix}'

resource ws 'Microsoft.HealthcareApis/workspaces@2024-03-31' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {}
}

// One FHIR service per payer. This is Option 1 from the architecture lead's canvas: the payer is
// the physical boundary; contracts inside a payer are logical (meta.tag + _tag).
resource fhir 'Microsoft.HealthcareApis/workspaces/fhirservices@2024-03-31' = [for p in payers: {
  parent: ws
  name: 'fhir-${p.key}'
  location: location
  kind: 'fhir-R4'
  tags: union(tags, { payer: p.displayName })
  identity: {
    // System-assigned is MANDATORY. $import and $export authenticate to storage
    // as THIS principal - not as any user-assigned identity you attach.
    // Turning this off is what broke Providence's dev import on 2026-08-13.
    type: 'SystemAssigned'
  }
  properties: {
    authenticationConfiguration: {
      authority: '${environment().authentication.loginEndpoint}${subscription().tenantId}'
      audience: 'https://${workspaceName}-fhir-${p.key}.fhir.azurehealthcareapis.com'
      // Native SMART on FHIR. The legacy smart proxy retires Sept 2026 - do not use it.
      smartProxyEnabled: false
    }
    importConfiguration: {
      enabled: true
      // false = incremental mode: versioned, queryable while importing, billed.
      // true  = initial load mode: faster and free, but the service is not
      //         generally queryable and lastUpdated is not preserved.
      initialImportMode: false
      integrationDataStore: storageAccountName
    }
    exportConfiguration: {
      storageAccountName: storageAccountName
    }
    resourceVersionPolicyConfiguration: {
      default: 'versioned'
    }
    corsConfiguration: {
      origins: [ '*' ]
      headers: [ '*' ]
      methods: [ 'GET', 'POST', 'PUT', 'DELETE', 'OPTIONS' ]
      maxAge: 600
      allowCredentials: false
    }
  }
}]

// AHDS FHIR only accepts the 'allLogs' category group - 'audit' is rejected with
// BadRequest even though AuditLogs is the only category the service emits.
resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [for (p, i) in payers: {
  scope: fhir[i]
  name: 'to-law'
  properties: {
    workspaceId: logAnalyticsId
    logs: [ { categoryGroup: 'allLogs', enabled: true } ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}]

output workspaceName string = ws.name
output fhirServiceNames array = [for (p, i) in payers: fhir[i].name]
output fhirPrincipalIds array = [for (p, i) in payers: fhir[i].identity.principalId]
output fhirEndpoints array = [for (p, i) in payers: 'https://${workspaceName}-fhir-${p.key}.fhir.azurehealthcareapis.com']
output fhirServices array = [for (p, i) in payers: {
  payerKey: p.key
  payerName: p.displayName
  contracts: p.contracts
  name: fhir[i].name
  url: 'https://${workspaceName}-fhir-${p.key}.fhir.azurehealthcareapis.com'
  principalId: fhir[i].identity.principalId
}]
