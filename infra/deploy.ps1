<#
.SYNOPSIS
  Deploys the POC, preserving payer entitlements across redeploys.

.DESCRIPTION
  Wraps `az deployment group create`.

  The reason this wrapper exists: APIM named values are declared in Bicep because
  a policy referencing {{payer-entitlements}} fails to apply if the named value
  does not exist. But declaring them in Bicep also means every redeploy resets
  them to the template default - silently de-entitling every onboarded payer and
  turning the whole gateway into a wall of 403s.

  Found the hard way: a policy fix redeployed cleanly and every payer request
  started failing, including the ones that had worked minutes earlier.

  So: read the live values first, pass them back in as parameters, deploy.
  Idempotent, and safe to run against an empty resource group.

.EXAMPLE
  ./deploy.ps1
  ./deploy.ps1 -ResourceGroup rg-ahds-fhir-poc -Name ahds-poc-main
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-ahds-fhir-poc',
  [string]$Name = 'ahds-poc-main',
  [string]$Template = "$PSScriptRoot/main.bicep",
  [string]$Parameters = "$PSScriptRoot/main.bicepparam"
)

$ErrorActionPreference = 'Stop'

$entitlements = '{}'
$ingest = '[]'

$apim = az apim list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
if ($apim) {
  Write-Host "Preserving named values from $apim" -ForegroundColor Cyan
  $v = az apim nv show -g $ResourceGroup --service-name $apim --named-value-id payer-entitlements --query value -o tsv 2>$null
  if ($v) { $entitlements = $v; Write-Host "  payer-entitlements : $((($v.Replace("'",'"')) | ConvertFrom-Json).PSObject.Properties.Name.Count) payer(s)" }
  $v = az apim nv show -g $ResourceGroup --service-name $apim --named-value-id ingest-principals --query value -o tsv 2>$null
  if ($v) { $ingest = $v; Write-Host "  ingest-principals  : preserved" }
} else {
  Write-Host "No APIM instance yet - first deployment." -ForegroundColor DarkGray
}

Write-Host "`nDeploying $Name to $ResourceGroup" -ForegroundColor Cyan
$out = az deployment group create `
  -g $ResourceGroup -n $Name -f $Template -p $Parameters `
  --parameters payerEntitlements=$entitlements ingestPrincipals=$ingest `
  --no-prompt --query properties.outputs -o json

if ($LASTEXITCODE -ne 0) { throw "Deployment failed." }

$o = $out | ConvertFrom-Json
Write-Host "`nDeployed" -ForegroundColor Green
Write-Host ("  {0,-18} {1}" -f 'workspace',  $o.workspaceName.value)
Write-Host ("  {0,-18} {1}" -f 'gateway',    $o.apimGatewayUrl.value)
Write-Host ("  {0,-18} {1}" -f 'storage',    $o.storageAccountName.value)
Write-Host ("  {0,-18} {1}" -f 'key vault',  $o.keyVaultName.value)
Write-Host ("  {0,-18} {1}" -f 'analytics',  $o.logAnalyticsName.value)
foreach ($f in $o.fhirServices.value) {
  Write-Host ("  {0,-18} {1}  [{2}]" -f $f.name, $f.url, ($f.contracts -join ', '))
}

if ($entitlements -eq '{}') {
  Write-Host "`nNo payers entitled yet. Run scripts/onboard-payer.ps1." -ForegroundColor Yellow
}
