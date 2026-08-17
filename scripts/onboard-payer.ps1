<#
.SYNOPSIS
  Onboards a payer end to end: Entra app, credential, entitlement, verification.

.DESCRIPTION
  This is the runbook Enterprise Architecture asked for on 2026-08-12, executable:

    "All we need is that ... we have a payer. We want to give that payer access
     to the AHDS server. What is the process for us to set that thing up for them?"

  Seven steps, in order:

    1. Register an Entra application for the payer (one app per payer - this is
       the revocation unit).
    2. Create the service principal.
    3. Mint a credential and push it STRAIGHT into Key Vault. The secret is never
       written to disk, never echoed, and the variable is cleared immediately.
       Production should use a certificate / client assertion instead; Steve
       Microsoft HLS on the call: "a secret, which I don't recommend."
    4. Build the entitlement record: appId -> { payer, contracts[], groups[] }.
    5. Merge it into the APIM `payer-entitlements` named value.
    6. Optionally add the app to `ingest-principals` for the write path.
    7. Print the connection details to hand to the payer.

  Note what this script does NOT do: it never grants the payer app an Azure RBAC
  role on the FHIR service. That omission is the security control. A payer token
  presented directly to AHDS authenticates fine and then fails authorisation,
  because only APIM's managed identity holds FHIR Data Contributor.

.EXAMPLE
  ./onboard-payer.ps1 -PayerKey payera -DisplayName 'Contoso Health Plan' `
                      -Contracts CT-3456,CT-7788 -AllowIngest
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$PayerKey,
  [Parameter(Mandatory)][string]$DisplayName,
  [Parameter(Mandatory)][string[]]$Contracts,
  [string]$ResourceGroup = 'rg-ahds-fhir-poc',
  # Tenant policy (policies/defaultAppManagementPolicy, passwordLifetime) caps
  # secret lifetime. This tenant allows P30D; 29 keeps a margin. Query the policy
  # before changing it - the failure message names the policy but not the cap.
  [int]$CredentialDays = 29,
  [switch]$AllowIngest,
  [switch]$SkipCredential
)

$ErrorActionPreference = 'Stop'

# `pwsh -File` passes every argument as a single string, so -Contracts CT-1,CT-2
# arrives as one element rather than two. Normalise before use.
$Contracts = @($Contracts | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

function Step($n, $msg) { Write-Host "`n[$n] $msg" -ForegroundColor Cyan }

$apimName = az apim list -g $ResourceGroup --query "[0].name" -o tsv
$kvName   = az keyvault list -g $ResourceGroup --query "[0].name" -o tsv
$tenantId = az account show --query tenantId -o tsv
if (-not $apimName) { throw "No APIM instance in $ResourceGroup." }
if (-not $kvName)   { throw "No Key Vault in $ResourceGroup." }

$wsName = az resource list -g $ResourceGroup --resource-type 'Microsoft.HealthcareApis/workspaces' --query "[0].name" -o tsv
$fhirUrl = "https://$wsName-fhir-$PayerKey.fhir.azurehealthcareapis.com"
$gatewayUrl = az apim show -g $ResourceGroup -n $apimName --query gatewayUrl -o tsv

# ---------------------------------------------------------------- 1. app
Step 1 "Registering Entra application for $DisplayName"
$appName = "providence-cmsdqm-$PayerKey"
$appId = az ad app list --display-name $appName --query "[0].appId" -o tsv
if ($appId) {
  Write-Host "  reusing existing app $appId"
} else {
  $appId = az ad app create --display-name $appName --sign-in-audience AzureADMyOrg --query appId -o tsv
  Write-Host "  created $appId"
}

# ---------------------------------------------------------------- 2. sp
Step 2 "Ensuring service principal"
$spId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv
if (-not $spId) {
  $spId = az ad sp create --id $appId --query id -o tsv
  Write-Host "  created $spId"
} else {
  Write-Host "  reusing $spId"
}

# ---------------------------------------------------------------- 3. credential
if ($SkipCredential) {
  Step 3 "Credential SKIPPED (-SkipCredential)"
} else {
  Step 3 "Minting credential and storing it in Key Vault $kvName"
  # Tenant policy caps application credential lifetime. Asking for a year fails
  # with "Credential lifetime exceeds the max value allowed as per assigned
  # policy" - request an explicit end date inside the cap instead.
  $end = (Get-Date).AddDays($CredentialDays).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  # The secret exists in memory for exactly the lines below. Never echoed,
  # never persisted to the workspace - the workspace is DLP-scanned.
  $secret = az ad app credential reset --id $appId --end-date $end --append --query password -o tsv
  if ([string]::IsNullOrWhiteSpace($secret)) {
    throw "Credential creation failed. Try a shorter -CredentialDays (current: $CredentialDays)."
  }
  az keyvault secret set --vault-name $kvName --name "payer-$PayerKey-client-secret" --value $secret --output none 2>$null
  $stored = $LASTEXITCODE -eq 0
  Clear-Variable secret
  if ($stored) {
    Write-Host "  stored as secret 'payer-$PayerKey-client-secret', expires $end  (value never displayed)"
  } else {
    Write-Warning @"
  Key Vault write failed - the vault's public network access is disabled by tenant policy.
  The credential WAS created but is now unrecoverable, which is the correct outcome:
  it was never written to disk and never displayed.

  For this environment use scripts/run-isolation-tests.ps1, which mints an
  ephemeral credential, proves the model, and revokes it inside one process.
"@
  }
}

# ---------------------------------------------------------------- 4. entitlement
Step 4 "Building entitlement record"
$groups = $Contracts | ForEach-Object { "group-" + ($_ -replace '-','').ToLower() }
$record = [ordered]@{
  payer     = $PayerKey
  name      = $DisplayName
  contracts = @($Contracts)
  groups    = @($groups)
}
Write-Host "  contracts : $($Contracts -join ', ')"
Write-Host "  groups    : $($groups -join ', ')"

# ---------------------------------------------------------------- 5. merge
Step 5 "Merging into APIM named value 'payer-entitlements'"
$currentRaw = az apim nv show -g $ResourceGroup --service-name $apimName --named-value-id payer-entitlements --query value -o tsv
# Stored single-quoted so the JSON can sit inside a C# string literal in the
# policy without an escaping nightmare. The policy calls .Replace((char)39,(char)34).
$current = if ([string]::IsNullOrWhiteSpace($currentRaw)) { @{} } else { $currentRaw.Replace("'", '"') | ConvertFrom-Json -AsHashtable }
$current[$appId] = $record
$merged = ($current | ConvertTo-Json -Depth 10 -Compress).Replace('"', "'")

az apim nv update -g $ResourceGroup --service-name $apimName --named-value-id payer-entitlements --value $merged --output none
Write-Host "  $($current.Keys.Count) payer(s) now entitled"

# ---------------------------------------------------------------- 6. ingest
if ($AllowIngest) {
  Step 6 "Adding to 'ingest-principals' (write path)"
  $ingRaw = az apim nv show -g $ResourceGroup --service-name $apimName --named-value-id ingest-principals --query value -o tsv
  $ing = if ([string]::IsNullOrWhiteSpace($ingRaw)) { @() } else { @($ingRaw.Replace("'", '"') | ConvertFrom-Json) }
  if ($ing -notcontains $appId) { $ing += $appId }
  $ingOut = (ConvertTo-Json @($ing) -Compress).Replace('"', "'")
  az apim nv update -g $ResourceGroup --service-name $apimName --named-value-id ingest-principals --value $ingOut --output none
  Write-Host "  $($ing.Count) principal(s) may write"
} else {
  Step 6 "Ingest NOT granted - this payer is read-only (the CMS-0057-F default)"
}

# ---------------------------------------------------------------- 7. handoff
Step 7 "Connection details to hand to $DisplayName"
$sheet = @"
--------------------------------------------------------------------------
  $DisplayName
--------------------------------------------------------------------------
  Token endpoint   https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token
  Grant type       client_credentials
  Client ID        $appId
  Client secret    Key Vault '$kvName', secret 'payer-$PayerKey-client-secret'
  Scope            $fhirUrl/.default

  FHIR base URL    $gatewayUrl/$PayerKey/outbound
  SMART config     $gatewayUrl/$PayerKey/outbound/.well-known/smart-configuration
  Capability stmt  $gatewayUrl/$PayerKey/outbound/metadata

  Bulk export      GET {base}/Group/{groupId}/`$export
                       ?_type=Patient,Coverage,ExplanationOfBenefit
                   Prefer: respond-async   (added for you if omitted)
  Your group ids   $($groups -join "`n" + ' ' * 19)

  Constraints      • read-only; writes return 403
                   • Group-scoped export only; system/patient level return 403
                   • results are filtered to your contracts automatically
                   • one concurrent export job per 5 minutes
                   • 600 requests/min, 50,000/day
--------------------------------------------------------------------------
"@
Write-Host $sheet -ForegroundColor Green

$outFile = Join-Path $PSScriptRoot "../out/payer-$PayerKey-handoff.txt"
New-Item -ItemType Directory -Path (Split-Path $outFile) -Force | Out-Null
$sheet | Out-File $outFile -Encoding utf8
Write-Host "Saved to $outFile  (contains no credential material)" -ForegroundColor DarkGray
