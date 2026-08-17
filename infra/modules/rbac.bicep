// =============================================================================
// RBAC - the module that encodes the fix for the platform lead's 2026-08-13 $import 403.
//
// WHAT WENT WRONG IN DEV
//   Storage Blob Data Contributor was granted to the user-assigned managed
//   identity `mi-pophealth-fhir-inbound-test-01-westus2` (324cb15a-...).
//   But $import does NOT read the blob as the UAMI. It reads as the FHIR
//   service's OWN service principal - the enterprise application named
//   `<workspace>/fhirservices/<service>` (7d1e195d-... in Providence dev).
//   That principal had no role on the storage account, so every GetBlobProperties
//   returned 403 and the import job failed before reading a single line.
//
// WHY IT MATTERS AT SCALE
//   Providence is standing up ~40 FHIR services. A manual portal click cannot be
//   the control. It has to be a deployment artifact, which is what this is.
// =============================================================================

param storageAccountName string
param workspaceName string
param fhirPrincipalIds array
param fhirServiceNames array
param operatorObjectId string
param apimPrincipalId string
param grantApim bool

var storageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageBlobDataReader = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
var fhirDataContributor = '5a1fc7df-4bf1-4951-a576-89034ee01acd'
var fhirDataExporter = '3db33094-8700-4567-8da5-1501d4e7e843'

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource fhirSvc 'Microsoft.HealthcareApis/workspaces/fhirservices@2024-03-31' existing = [for n in fhirServiceNames: {
  name: '${workspaceName}/${n}'
}]

// --- THE FIX -----------------------------------------------------------------
// Each FHIR service's system-assigned identity gets Storage Blob Data Contributor
// on the integration data store. Contributor (not Reader) because $export writes
// NDJSON back to the same account.
resource importExportGrant 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (pid, i) in fhirPrincipalIds: {
  scope: sa
  name: guid(sa.id, pid, storageBlobDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributor)
    principalId: pid
    // Explicit principalType avoids the "principal does not exist in the
    // directory" replication race on a fresh deployment.
    principalType: 'ServicePrincipal'
  }
}]

// --- Operator data-plane access ----------------------------------------------
// FHIR Data Contributor on each service so a human can seed and query it.
resource operatorFhir 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (n, i) in fhirServiceNames: if (!empty(operatorObjectId)) {
  scope: fhirSvc[i]
  name: guid(resourceId('Microsoft.HealthcareApis/workspaces/fhirservices', workspaceName, n), operatorObjectId, fhirDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', fhirDataContributor)
    principalId: operatorObjectId
    principalType: 'User'
  }
}]

// Operator also needs to read/write the NDJSON staging container directly.
resource operatorStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(operatorObjectId)) {
  scope: sa
  name: guid(sa.id, operatorObjectId, storageBlobDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributor)
    principalId: operatorObjectId
    principalType: 'User'
  }
}

// --- APIM -> FHIR -------------------------------------------------------------
// APIM calls FHIR with its own managed identity when acting as trusted broker.
// Contributor because the same gateway fronts both the inbound ingest route and
// the outbound payer route; the route split is enforced by policy, not by RBAC.
resource apimFhir 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (n, i) in fhirServiceNames: if (grantApim && !empty(apimPrincipalId)) {
  scope: fhirSvc[i]
  name: guid(resourceId('Microsoft.HealthcareApis/workspaces/fhirservices', workspaceName, n), apimPrincipalId, fhirDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', fhirDataContributor)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}]

// APIM streams finished $export NDJSON back to the payer, so it needs blob read.
resource apimStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantApim && !empty(apimPrincipalId)) {
  scope: sa
  name: guid(sa.id, apimPrincipalId, storageBlobDataReader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReader)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output fhirDataExporterRoleId string = fhirDataExporter
