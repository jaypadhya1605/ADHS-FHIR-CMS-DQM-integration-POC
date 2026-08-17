<#
.SYNOPSIS
  Prints the deployed environment and writes a filled-in copy of the test suite.

.DESCRIPTION
  Reads the live resource group and emits:
    * a summary table of what exists
    * tests/isolation-proofs.local.http with the @variables substituted
    * the KQL queries worth pinning in the portal

  Client secrets are read from Key Vault only when -IncludeSecrets is passed, and
  even then they go straight into the generated .http file, which is gitignored.
  Nothing is echoed to the console.
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-ahds-fhir-poc',
  [switch]$IncludeSecrets
)

$ErrorActionPreference = 'Stop'

$tenantId = az account show --query tenantId -o tsv
$sub      = az account show --query id -o tsv
$ws       = az resource list -g $ResourceGroup --resource-type 'Microsoft.HealthcareApis/workspaces' --query "[0].name" -o tsv
$apim     = az apim list -g $ResourceGroup --query "[0].name" -o tsv
$kv       = az keyvault list -g $ResourceGroup --query "[0].name" -o tsv
$storage  = az storage account list -g $ResourceGroup --query "[0].name" -o tsv
$law      = az monitor log-analytics workspace list -g $ResourceGroup --query "[0].name" -o tsv
$gateway  = if ($apim) { az apim show -g $ResourceGroup -n $apim --query gatewayUrl -o tsv } else { $null }

Write-Host "`n  Providence CMS-0057-F POC" -ForegroundColor Cyan
Write-Host "  ---------------------------------------------------------------"
Write-Host ("  {0,-22} {1}" -f 'Subscription',   $sub)
Write-Host ("  {0,-22} {1}" -f 'Tenant',         $tenantId)
Write-Host ("  {0,-22} {1}" -f 'Resource group', $ResourceGroup)
Write-Host ("  {0,-22} {1}" -f 'AHDS workspace', $ws)
Write-Host ("  {0,-22} {1}" -f 'APIM',           $apim)
Write-Host ("  {0,-22} {1}" -f 'Gateway',        $gateway)
Write-Host ("  {0,-22} {1}" -f 'Key Vault',      $kv)
Write-Host ("  {0,-22} {1}" -f 'Storage',        $storage)
Write-Host ("  {0,-22} {1}" -f 'Log Analytics',  $law)

Write-Host "`n  FHIR services" -ForegroundColor Cyan
$svcRows = az resource list -g $ResourceGroup --resource-type 'Microsoft.HealthcareApis/workspaces/fhirservices' --query "[].name" -o tsv
$svcNames = @($svcRows -split "`n" | Where-Object { $_ } | ForEach-Object { ($_ -split '/')[-1] })
foreach ($s in $svcNames) {
  $pid = az resource show -g $ResourceGroup --resource-type 'Microsoft.HealthcareApis/workspaces/fhirservices' -n "$ws/$s" --query identity.principalId -o tsv
  Write-Host ("    {0,-16} https://{1}-{0}.fhir.azurehealthcareapis.com" -f $s, $ws)
  Write-Host ("    {0,-16} system-assigned principal {1}" -f '', $pid) -ForegroundColor DarkGray
}

Write-Host "`n  Payer applications" -ForegroundColor Cyan
$apps = az ad app list --filter "startswith(displayName,'providence-cmsdqm-')" --query "[].{name:displayName, appId:appId}" -o json | ConvertFrom-Json
if (-not $apps) { Write-Host "    none yet - run scripts/onboard-payer.ps1" -ForegroundColor DarkGray }
foreach ($a in $apps) { Write-Host ("    {0,-34} {1}" -f $a.name, $a.appId) }

# ---------------------------------------------------------------------------
# Generate a runnable copy of the test suite
# ---------------------------------------------------------------------------
$tpl = Join-Path $PSScriptRoot '../tests/isolation-proofs.http'
$out = Join-Path $PSScriptRoot '../tests/isolation-proofs.local.http'
if ((Test-Path $tpl) -and $apim) {
  $text = Get-Content $tpl -Raw
  $text = $text -replace 'https://REPLACE-apim\.azure-api\.net', $gateway
  $text = $text -replace '@tenant\s*=\s*\S+', "@tenant      = $tenantId"
  $text = $text -replace 'https://REPLACE-ws-fhir-payera\.fhir\.azurehealthcareapis\.com', "https://$ws-fhir-payera.fhir.azurehealthcareapis.com"
  $text = $text -replace 'https://REPLACE-ws-fhir-payerb\.fhir\.azurehealthcareapis\.com', "https://$ws-fhir-payerb.fhir.azurehealthcareapis.com"

  foreach ($a in $apps) {
    $key = $a.name -replace '^providence-cmsdqm-',''
    $var = if ($key -eq 'payera') { 'payerAAppId' } elseif ($key -eq 'payerb') { 'payerBAppId' } else { $null }
    if ($var) { $text = $text -replace "@$var\s*=\s*REPLACE", "@$var = $($a.appId)" }

    if ($IncludeSecrets -and $kv) {
      $svar = if ($key -eq 'payera') { 'payerASecret' } elseif ($key -eq 'payerb') { 'payerBSecret' } else { $null }
      if ($svar) {
        $sec = az keyvault secret show --vault-name $kv --name "payer-$key-client-secret" --query value -o tsv 2>$null
        if ($sec) { $text = $text -replace "@$svar\s*=\s*REPLACE", "@$svar= $sec"; Clear-Variable sec }
      }
    }
  }

  $text | Out-File $out -Encoding utf8
  Write-Host "`n  Wrote $out" -ForegroundColor Green
  if (-not $IncludeSecrets) { Write-Host "  Secrets omitted. Re-run with -IncludeSecrets to fill them in." -ForegroundColor DarkGray }
  else { Write-Host "  CONTAINS SECRETS - do not commit. Covered by .gitignore." -ForegroundColor Yellow }
}

Write-Host @"

  Pin these in Log Analytics ($law)
  ---------------------------------------------------------------
  // throttling rate - alert above 1%
  MicrosoftHealthcareApisAuditLogs
  | where TimeGenerated > ago(1h)
  | summarize total=count(), throttled=countif(StatusCode==429) by bin(TimeGenerated,5m)
  | extend pct = round(100.0*throttled/total,2)

  // storage 403s - distinguishes a live permission failure from a replayed job
  StorageBlobLogs
  | where TimeGenerated > ago(2h) and StatusCode == 403
  | project TimeGenerated, OperationName, Uri, RequesterObjectId

  // gateway denials by payer - the isolation model, observed
  ApiManagementGatewayLogs
  | where TimeGenerated > ago(24h) and ResponseCode == 403
  | summarize count() by ApiId, Url

"@ -ForegroundColor DarkGray
