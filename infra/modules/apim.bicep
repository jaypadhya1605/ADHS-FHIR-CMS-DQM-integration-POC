param location string
param suffix string
param env string
param tags object
param sku string
param publisherEmail string
param publisherName string
param payers array
param fhirEndpoints array
param logAnalyticsId string
param appInsightsId string
@secure()
param appInsightsKey string

@description('appId -> entitlement map, JSON with SINGLE quotes. Populated by scripts/onboard-payer.ps1.')
param payerEntitlements string = '{}'

@description('JSON array (single quotes) of appIds allowed to write on the inbound route.')
param ingestPrincipals string = '[]'

var apimName = 'apim-${env}-ahds-${suffix}'
var tenantId = subscription().tenantId

var outboundTemplate = loadTextContent('../../apim/policies/payer-outbound.xml')
var inboundTemplate = loadTextContent('../../apim/policies/payer-inbound.xml')

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: sku
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

// Entitlement store. In production this is a cached lookup against the contract
// master; as a named value it keeps the POC self-contained and auditable in the
// portal, which is what Enterprise Architecture asked to be able to see.
resource nvEntitlements 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'payer-entitlements'
  properties: {
    displayName: 'payer-entitlements'
    value: payerEntitlements
    secret: false
  }
}

resource nvIngest 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'ingest-principals'
  properties: {
    displayName: 'ingest-principals'
    value: ingestPrincipals
    secret: false
  }
}

resource logger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    resourceId: appInsightsId
    credentials: {
      instrumentationKey: appInsightsKey
    }
  }
}

// One backend per payer FHIR service.
resource backend 'Microsoft.ApiManagement/service/backends@2024-05-01' = [for (p, i) in payers: {
  parent: apim
  name: 'fhir-${p.key}'
  properties: {
    title: '${p.displayName} FHIR service'
    protocol: 'http'
    url: fhirEndpoints[i]
  }
}]

// ---------------------------------------------------------------------------
// OUTBOUND API - payer-facing, read-only, Group-scoped
// ---------------------------------------------------------------------------
resource outboundApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = [for (p, i) in payers: {
  parent: apim
  name: 'fhir-${p.key}-outbound'
  properties: {
    displayName: '${p.displayName} - Outbound (payer pull)'
    description: 'CMS-0057-F payer access. Group-scoped $export and contract-filtered search only.'
    path: '${p.key}/outbound'
    protocols: [ 'https' ]
    serviceUrl: fhirEndpoints[i]
    // Auth is the SMART Backend Services JWT, not an APIM subscription key.
    subscriptionRequired: false
  }
}]

var methods = [ 'GET', 'POST' ]

resource outboundOps 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = [for item in flatten(map(range(0, length(payers)), i => map(methods, m => { i: i, m: m }))): {
  parent: outboundApi[item.i]
  name: 'all-${toLower(item.m)}'
  properties: {
    displayName: '${item.m} (wildcard)'
    method: item.m
    urlTemplate: '/*'
    templateParameters: []
    responses: []
  }
}]

resource outboundPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = [for (p, i) in payers: {
  parent: outboundApi[i]
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(replace(replace(outboundTemplate, '__PAYER_KEY__', p.key), '__FHIR_AUDIENCE__', fhirEndpoints[i]), '__TENANT_ID__', tenantId)
  }
  dependsOn: [ nvEntitlements, nvIngest, outboundOps ]
}]

resource outboundDiag 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = [for (p, i) in payers: {
  parent: outboundApi[i]
  name: 'applicationinsights'
  properties: {
    loggerId: logger.id
    alwaysLog: 'allErrors'
    sampling: { samplingType: 'fixed', percentage: 100 }
    verbosity: 'information'
    httpCorrelationProtocol: 'W3C'
  }
}]

// ---------------------------------------------------------------------------
// INBOUND API - ingest only, $export explicitly denied
// ---------------------------------------------------------------------------
resource inboundApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = [for (p, i) in payers: {
  parent: apim
  name: 'fhir-${p.key}-inbound'
  properties: {
    displayName: '${p.displayName} - Inbound (ingest)'
    description: 'Write path. Stamps meta.tag with the contract. $export is denied on this route.'
    path: '${p.key}/inbound'
    protocols: [ 'https' ]
    serviceUrl: fhirEndpoints[i]
    subscriptionRequired: false
  }
}]

var inboundMethods = [ 'GET', 'POST', 'PUT', 'DELETE' ]

resource inboundOps 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = [for item in flatten(map(range(0, length(payers)), i => map(inboundMethods, m => { i: i, m: m }))): {
  parent: inboundApi[item.i]
  name: 'all-${toLower(item.m)}'
  properties: {
    displayName: '${item.m} (wildcard)'
    method: item.m
    urlTemplate: '/*'
    templateParameters: []
    responses: []
  }
}]

resource inboundPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = [for (p, i) in payers: {
  parent: inboundApi[i]
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(replace(replace(inboundTemplate, '__PAYER_KEY__', p.key), '__FHIR_AUDIENCE__', fhirEndpoints[i]), '__TENANT_ID__', tenantId)
  }
  dependsOn: [ nvEntitlements, nvIngest, inboundOps ]
}]

resource apimDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: apim
  name: 'to-law'
  properties: {
    workspaceId: logAnalyticsId
    logs: [ { categoryGroup: 'allLogs', enabled: true } ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

output apimName string = apim.name
output gatewayUrl string = apim.properties.gatewayUrl
output principalId string = apim.identity.principalId
