<#
.SYNOPSIS
  Executes the isolation proofs and prints a pass/fail table.

.DESCRIPTION
  The security model, run rather than described. Fifteen assertions covering the
  payer boundary, the contract boundary, the inbound/outbound split, export
  scoping, gateway bypass, tag integrity and export throttling.

  Credential handling: a short-lived client secret is minted for each payer,
  held in memory for the duration of the run, and revoked at the end. Nothing is
  written to disk and nothing is printed. That is deliberate and it also happens
  to be the only approach that works in this subscription, where tenant policy
  disables public network access on Key Vault.

  The equivalent as raw HTTP is tests/isolation-proofs.http, for environments
  where the vault is reachable and the credentials are long-lived.

.EXAMPLE
  ./run-isolation-tests.ps1
  ./run-isolation-tests.ps1 -KeepCredentials    # leave the secrets in place
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-ahds-fhir-poc',
  [switch]$KeepCredentials,
  [switch]$SkipThrottleTest
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$tenantId = az account show --query tenantId -o tsv
$ws       = az resource list -g $ResourceGroup --resource-type 'Microsoft.HealthcareApis/workspaces' --query "[0].name" -o tsv
$apim     = az apim list -g $ResourceGroup --query "[0].name" -o tsv
$gateway  = az apim show -g $ResourceGroup -n $apim --query gatewayUrl -o tsv

$payers = @(
  @{ key = 'payera'; app = 'providence-cmsdqm-payera'; groups = @('group-ct3456','group-ct7788') }
  @{ key = 'payerb'; app = 'providence-cmsdqm-payerb'; groups = @('group-ct9001') }
)

Write-Host "Gateway : $gateway" -ForegroundColor Cyan
Write-Host "Tenant  : $tenantId`n" -ForegroundColor Cyan

# --------------------------------------------------------------------------
# Mint ephemeral credentials
# --------------------------------------------------------------------------
function Get-AppToken {
  param([string]$AppId, [string]$Secret, [string]$Audience, [string]$TenantId)
  $body = "grant_type=client_credentials&client_id=$AppId&client_secret=$([uri]::EscapeDataString($Secret))&scope=$([uri]::EscapeDataString("$Audience/.default"))"
  for ($try = 1; $try -le 6; $try++) {
    try {
      return (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                -Body $body -ContentType 'application/x-www-form-urlencoded').access_token
    } catch {
      # New app credentials take a few seconds to replicate across Entra.
      Start-Sleep -Seconds 5
    }
  }
  return $null
}

$ctx = @{}
$secrets = @{}
foreach ($p in $payers) {
  $appId = az ad app list --display-name $p.app --query "[0].appId" -o tsv
  if (-not $appId) { throw "App '$($p.app)' not found. Run scripts/onboard-payer.ps1 first." }

  $end = (Get-Date).AddDays(1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  $s = az ad app credential reset --id $appId --end-date $end --append --display-name 'isolation-test' --query password -o tsv
  if ([string]::IsNullOrWhiteSpace($s)) { throw "Could not mint a credential for $($p.app)." }
  $secrets[$p.key] = $s

  $ctx[$p.key] = @{ appId = $appId; fhirUrl = "https://$ws-fhir-$($p.key).fhir.azurehealthcareapis.com"; groups = $p.groups }
}

foreach ($p in $payers) {
  # Entra issues .default tokens for Azure RBAC-protected resources without any
  # app-role assignment. Authorisation happens at the resource. That property is
  # what makes case 12 meaningful: the token is real, the access is not.
  $ctx[$p.key].token = Get-AppToken $ctx[$p.key].appId $secrets[$p.key] $ctx[$p.key].fhirUrl $tenantId
  if (-not $ctx[$p.key].token) { throw "Token acquisition failed for $($p.app)." }
  Write-Host "  credential ready for $($p.key)  ($($ctx[$p.key].appId))" -ForegroundColor DarkGray
}

# Payer B's application, but a token correctly audienced for Payer A's FHIR
# service. validate-jwt will ACCEPT this - the signature and audience are both
# valid. Only the entitlement lookup catches it. Without this token the
# cross-payer guard is never exercised, because the audience check rejects the
# obvious attempt first.
$ctx['payerb'].tokenForA = Get-AppToken $ctx['payerb'].appId $secrets['payerb'] $ctx['payera'].fhirUrl $tenantId
$secrets.Clear()
Remove-Variable secrets

# --------------------------------------------------------------------------
# Test harness
# --------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()

function Get-BodyText($r) {
  # Invoke-WebRequest returns Content as a byte[] when the response has no
  # charset on the content type, which is what AHDS does for application/fhir+json.
  if ($null -eq $r) { return '' }
  if ($r.Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($r.Content) }
  return [string]$r.Content
}

function Assert-Status {
  param(
    [int]$Num, [string]$Name, [string]$Uri, [int[]]$Expect,
    [string]$Token, [string]$Method = 'GET', [string]$Body, [hashtable]$Headers = @{}
  )
  $h = @{ Authorization = "Bearer $Token" } + $Headers
  $args = @{ Uri = $Uri; Method = $Method; Headers = $h; SkipHttpErrorCheck = $true }
  if ($Body) { $args.Body = $Body; $args.ContentType = 'application/fhir+json' }

  try { $r = Invoke-WebRequest @args } catch { $r = $_.Exception.Response }
  $code = [int]$r.StatusCode
  $pass = $Expect -contains $code

  $results.Add([pscustomobject]@{
    '#' = $Num; Test = $Name; Expected = ($Expect -join '/'); Actual = $code
    Result = $(if ($pass) { 'PASS' } else { 'FAIL' })
  })
  Write-Host ("  [{0,2}] {1,-46} expect {2,-7} got {3,-4} {4}" -f `
    $Num, $Name, ($Expect -join '/'), $code, $(if ($pass) { 'PASS' } else { 'FAIL' })) `
    -ForegroundColor $(if ($pass) { 'Green' } else { 'Red' })
  return $r
}

$A = $ctx['payera']; $B = $ctx['payerb']
$outA = "$gateway/payera/outbound"
$inA  = "$gateway/payera/inbound"
$outB = "$gateway/payerb/outbound"

Write-Host "`nBaseline" -ForegroundColor Yellow
$r1 = Assert-Status 1 'own data readable'              "$outA/Patient?_count=5"                200 $A.token
Assert-Status 2 'Group export accepted'                "$outA/Group/$($A.groups[0])/`$export"  202 $A.token -Headers @{ Prefer = 'respond-async' } | Out-Null
Assert-Status 3 'capability statement'                 "$outA/metadata"                        200 $A.token | Out-Null

Write-Host "`nPayer boundary" -ForegroundColor Yellow
Assert-Status 4 'payer B app, valid payer A audience'  "$outA/Patient?_count=5"                403 $B.tokenForA | Out-Null
Assert-Status 5 'payer B token, payer B audience'      "$outA/Patient?_count=5"           @(401,403) $B.token | Out-Null

Write-Host "`nContract boundary" -ForegroundColor Yellow
Assert-Status 6 'unentitled Group export'              "$outA/Group/$($B.groups[0])/`$export"  403 $A.token -Headers @{ Prefer = 'respond-async' } | Out-Null

Write-Host "`nDirection boundary" -ForegroundColor Yellow
Assert-Status 7 'write on outbound route'              "$outA/Patient"                         403 $A.token -Method POST -Body '{"resourceType":"Patient","id":"nope"}' | Out-Null
Assert-Status 8 'payer credential on inbound route'    "$inA/Patient"                          403 $A.token -Method POST -Body '{"resourceType":"Patient","id":"nope"}' -Headers @{ 'X-Providence-Contract' = 'CT-3456' } | Out-Null
Assert-Status 9 'export on inbound route'              "$inA/Group/$($A.groups[0])/`$export"   403 $A.token -Headers @{ Prefer = 'respond-async' } | Out-Null

Write-Host "`nExport scope" -ForegroundColor Yellow
Assert-Status 10 'system-level export'                 "$outA/`$export"                        403 $A.token -Headers @{ Prefer = 'respond-async' } | Out-Null
Assert-Status 11 'patient-level export'                "$outA/Patient/`$export"                403 $A.token -Headers @{ Prefer = 'respond-async' } | Out-Null

Write-Host "`nGateway bypass - the keystone control" -ForegroundColor Yellow
Assert-Status 12 'payer token straight to AHDS'        "$($A.fhirUrl)/Patient?_count=5"        403 $A.token | Out-Null

Write-Host "`nTag integrity" -ForegroundColor Yellow
$r13 = Assert-Status 13 'caller-supplied _tag overridden' "$outA/Patient?_tag=https://providence.org/fhir/contract|CT-9001&_count=20" 200 $A.token
Assert-Status 14 'untagged inbound write rejected'     "$inA/Patient"                     @(400,403) $A.token -Method POST -Body '{"resourceType":"Patient","id":"untagged"}' | Out-Null

if (-not $SkipThrottleTest) {
  Write-Host "`nExport concurrency" -ForegroundColor Yellow
  Assert-Status 15 'second export within 5 min'        "$outA/Group/$($A.groups[1])/`$export"  429 $A.token -Headers @{ Prefer = 'respond-async' } | Out-Null
}

# --------------------------------------------------------------------------
# Deep check on case 13: the filter must actually have removed payer B's data
# --------------------------------------------------------------------------
if ($r13 -and [int]$r13.StatusCode -eq 200) {
  $bundle = (Get-BodyText $r13) | ConvertFrom-Json
  $codes = @($bundle.entry.resource.meta.tag.code | Sort-Object -Unique)
  $leak = @($codes | Where-Object { $_ -notin @('CT-3456','CT-7788') })
  $ok = ($codes.Count -gt 0) -and ($leak.Count -eq 0)
  Write-Host ("`n  entries returned: {0}   tags: {1}" -f @($bundle.entry).Count, ($codes -join ', ')) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
  if ($leak.Count) { Write-Host "  LEAK: $($leak -join ', ')" -ForegroundColor Red }
  $results.Add([pscustomobject]@{ '#' = '13b'; Test = 'body contains only own contracts'; Expected = 'CT-3456/CT-7788'; Actual = ($codes -join ','); Result = $(if ($ok) { 'PASS' } else { 'FAIL' }) })
}

# --------------------------------------------------------------------------
# Revoke
# --------------------------------------------------------------------------
if (-not $KeepCredentials) {
  Write-Host "`nRevoking ephemeral credentials" -ForegroundColor DarkGray
  foreach ($k in $ctx.Keys) {
    $ids = az ad app credential list --id $ctx[$k].appId --query "[?displayName=='isolation-test'].keyId" -o tsv
    foreach ($id in @($ids -split "`n" | Where-Object { $_ })) {
      az ad app credential delete --id $ctx[$k].appId --key-id $id 2>$null
    }
  }
}

Write-Host "`n"
$results | Format-Table -AutoSize
$failed = @($results | Where-Object Result -eq 'FAIL').Count
if ($failed) {
  Write-Host "$failed assertion(s) FAILED." -ForegroundColor Red
  exit 1
}
Write-Host "All $($results.Count) assertions passed." -ForegroundColor Green
