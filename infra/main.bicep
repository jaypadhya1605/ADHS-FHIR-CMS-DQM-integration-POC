// =============================================================================
// Providence CMS-0057-F / AHDS FHIR POC - main deployment
// -----------------------------------------------------------------------------
// Proves the architecture agreed on the 2026-08-12 working session:
//   * Option 1 - one AHDS FHIR service per PAYER (physical isolation)
//   * Contracts within a payer are a LOGICAL boundary (meta.tag + _tag)
//   * APIM is the mandatory control plane in front of every FHIR service
//   * $import reads storage as the FHIR service's OWN system-assigned identity
//     -> this is the root cause of the 403 Platform Engineering hit on 2026-08-13, encoded here
//        so it can never be missed again on any of the ~40 planned instances.
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region. AHDS FHIR + APIM v2 must both be available.')
param location string = resourceGroup().location

@description('Short environment moniker used in resource names.')
@maxLength(6)
param env string = 'poc'

@description('Payers to provision a dedicated FHIR service for. Option 1 = one instance per payer.')
param payers array = [
  {
    key: 'payera'
    displayName: 'Contoso Health Plan'
    contracts: [ 'CT-3456', 'CT-7788' ]
  }
  {
    key: 'payerb'
    displayName: 'Fabrikam Medicare Advantage'
    contracts: [ 'CT-9001' ]
  }
]

@description('APIM SKU. BasicV2 deploys in ~10 min; Developer is cheaper but takes ~40 min.')
@allowed([ 'BasicV2', 'StandardV2', 'Developer' ])
param apimSku string = 'BasicV2'

@description('APIM publisher email (required by the service).')
param apimPublisherEmail string

@description('APIM publisher organisation name.')
param apimPublisherName string = 'Providence St. Joseph Health - CMS DQM POC'

@description('Object ID of the human operator who needs data-plane access to FHIR and Key Vault.')
param operatorObjectId string

@description('Deploy APIM. Set false for a fast infra-only redeploy.')
param deployApim bool = true

// Entitlements live in an APIM named value, which means a redeploy would reset
// them to the template default and silently de-entitle every onboarded payer.
// deploy.ps1 reads the live values and passes them back in here. Always deploy
// through that wrapper rather than calling `az deployment group create` directly.
@description('appId -> entitlement map as JSON with SINGLE quotes. Managed by scripts/onboard-payer.ps1.')
param payerEntitlements string = '{}'

@description('JSON array (single quotes) of appIds permitted to write on the inbound route.')
param ingestPrincipals string = '[]'

var suffix = substring(uniqueString(resourceGroup().id), 0, 8)
var tags = {
  workload: 'ahds-cms-dqm-poc'
  customer: 'Providence St. Joseph Health'
  owner: 'Microsoft HLS'
  env: env
  costCenter: 'poc-delete-when-done'
}

// -----------------------------------------------------------------------------
// Observability - stood up first so everything else can wire diagnostics to it
// -----------------------------------------------------------------------------
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    suffix: suffix
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// Integration data store. One account, three containers:
//   pdex       - inbound NDJSON staged for $import
//   export     - $export output ($export writes here, payers collect via APIM)
//   quarantine - resources that failed $validate (the "unclean" path)
// -----------------------------------------------------------------------------
module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    suffix: suffix
    env: env
    tags: tags
    logAnalyticsId: monitoring.outputs.logAnalyticsId
  }
}

// -----------------------------------------------------------------------------
// Key Vault - holds per-payer client credentials. No key material ever lands on
// disk; the onboarding script pipes the secret straight from Entra into KV.
// -----------------------------------------------------------------------------
module keyvault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    location: location
    suffix: suffix
    env: env
    tags: tags
    operatorObjectId: operatorObjectId
    logAnalyticsId: monitoring.outputs.logAnalyticsId
  }
}

// -----------------------------------------------------------------------------
// AHDS workspace + one FHIR service per payer
// -----------------------------------------------------------------------------
module ahds 'modules/ahds.bicep' = {
  name: 'ahds'
  params: {
    location: location
    suffix: suffix
    env: env
    tags: tags
    payers: payers
    storageAccountName: storage.outputs.storageAccountName
    logAnalyticsId: monitoring.outputs.logAnalyticsId
  }
}

// -----------------------------------------------------------------------------
// RBAC. THE important module.
//
// the platform lead's 2026-08-13 403 happened because Storage Blob Data Contributor was
// granted to the user-assigned managed identity, but $import authenticates as
// the FHIR service's own system-assigned identity. Granting the UAMI did
// nothing. This module grants the SYSTEM-ASSIGNED principal of every FHIR
// service, so the failure mode cannot recur.
// -----------------------------------------------------------------------------
module rbac 'modules/rbac.bicep' = {
  name: 'rbac'
  params: {
    storageAccountName: storage.outputs.storageAccountName
    workspaceName: ahds.outputs.workspaceName
    fhirPrincipalIds: ahds.outputs.fhirPrincipalIds
    fhirServiceNames: ahds.outputs.fhirServiceNames
    operatorObjectId: operatorObjectId
    apimPrincipalId: deployApim ? (apim.?outputs.principalId ?? '') : ''
    grantApim: deployApim
  }
}

// -----------------------------------------------------------------------------
// APIM - the control plane. Enforces what the FHIR service cannot:
//   * per-contract row filtering via _tag
//   * inbound vs outbound route separation inside one instance
//   * per-payer rate limiting
//   * JWT audience/issuer/scope validation
// -----------------------------------------------------------------------------
module apim 'modules/apim.bicep' = if (deployApim) {
  name: 'apim'
  params: {
    location: location
    suffix: suffix
    env: env
    tags: tags
    sku: apimSku
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    payers: payers
    fhirEndpoints: ahds.outputs.fhirEndpoints
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    appInsightsId: monitoring.outputs.appInsightsId
    appInsightsKey: monitoring.outputs.appInsightsKey
    payerEntitlements: payerEntitlements
    ingestPrincipals: ingestPrincipals
  }
}

output storageAccountName string = storage.outputs.storageAccountName
output keyVaultName string = keyvault.outputs.keyVaultName
output workspaceName string = ahds.outputs.workspaceName
output fhirServices array = ahds.outputs.fhirServices
output apimName string = apim.?outputs.apimName ?? ''
output apimGatewayUrl string = apim.?outputs.gatewayUrl ?? ''
output logAnalyticsName string = monitoring.outputs.logAnalyticsName
output tenantId string = subscription().tenantId
output resourceGroupName string = resourceGroup().name
