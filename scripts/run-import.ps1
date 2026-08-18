<#
.SYNOPSIS
  Submits $import for each payer FHIR service and polls to completion.

.DESCRIPTION
  This is the operation that failed with HTTP 403 in Providence's dev environment
  on 2026-08-13. It works here because infra/modules/rbac.bicep grants Storage
  Blob Data Contributor to each FHIR service's SYSTEM-ASSIGNED principal - the
  identity AHDS actually uses to read the integration data store - rather than to
  a user-assigned managed identity attached to the service.

  The script also demonstrates the two behaviours that confused the dev retest:

    * A terminal import job is IMMUTABLE, and registration is IDEMPOTENT on the
      request payload. Re-polling replays the stored OperationOutcome; re-POSTing
      an identical body returns that same job rather than creating a new one.
      -Force bumps each input blob's ETag via a metadata write, so the payload
      differs and a genuinely new job id is created - same path, same content.
    * Partial success is normal. `error[]` in the completion payload points at a
      per-file OperationOutcome NDJSON. A non-empty error[] with a populated
      output[] means "most rows landed", not "the import failed".

.EXAMPLE
  ./run-import.ps1
  ./run-import.ps1 -PayerKey payera -Force
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-ahds-fhir-poc',
  [string]$PayerKey,
  [int]$TimeoutMinutes = 20,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

$wsName  = az resource list -g $ResourceGroup --resource-type 'Microsoft.HealthcareApis/workspaces' --query "[0].name" -o tsv
$storage = az storage account list -g $ResourceGroup --query "[0].name" -o tsv
$services = az resource list -g $ResourceGroup --resource-type 'Microsoft.HealthcareApis/workspaces/fhirservices' --query "[].name" -o tsv
if (-not $services) { throw "No FHIR services in $ResourceGroup." }

$targets = @($services -split "`n" | Where-Object { $_ }) | ForEach-Object { ($_ -split '/')[-1] }
if ($PayerKey) { $targets = $targets | Where-Object { $_ -eq "fhir-$PayerKey" } }

$blobBase = "https://$storage.blob.core.windows.net"

foreach ($svc in $targets) {
  $payer = $svc -replace '^fhir-',''
  $fhirUrl = "https://$wsName-$svc.fhir.azurehealthcareapis.com"
  Write-Host "`n=== $svc ===" -ForegroundColor Cyan

  $token = az account get-access-token --resource $fhirUrl --query accessToken -o tsv
  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/fhir+json'; Prefer = 'respond-async' }

  # Discover this payer's NDJSON. Only files under the payer's own prefix - a
  # payer's data never reaches another payer's FHIR service.
  $blobs = az storage blob list --account-name $storage --auth-mode login -c pdex `
             --prefix "$payer/" --query "[?ends_with(name,'.ndjson')].name" -o tsv
  $blobList = @($blobs -split "`n" | Where-Object { $_ })
  if (-not $blobList) { Write-Warning "  no NDJSON under pdex/$payer/ - run generate-samples.ps1"; continue }

  # Group.ndjson last: members must exist before the cohort references them.
  $ordered = @($blobList | Where-Object { $_ -notmatch 'Group\.ndjson$' }) +
             @($blobList | Where-Object { $_ -match  'Group\.ndjson$' })

  # A metadata write changes the blob's ETag without touching content or path,
  # which is what makes the registration payload differ on a config-fix retry.
  if ($Force) {
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    foreach ($b in $ordered) {
      az storage blob metadata update --account-name $storage --auth-mode login `
        -c pdex -n $b --metadata importRetry=$stamp | Out-Null
    }
    Write-Host "  -Force: bumped ETag on $($ordered.Count) blob(s)" -ForegroundColor DarkYellow
  }

  $input = foreach ($b in $ordered) {
    $type = [System.IO.Path]::GetFileNameWithoutExtension($b)
    $etag = az storage blob show --account-name $storage --auth-mode login `
              -c pdex -n $b --query properties.etag -o tsv
    @{ type = $type; url = "$blobBase/pdex/$b"; etag = $etag }
  }

  $body = @{
    resourceType = 'Parameters'
    parameter = @(
      @{ name = 'inputFormat';  valueString = 'application/fhir+ndjson' }
      @{ name = 'mode';         valueString = 'IncrementalLoad' }
      @{ name = 'input';        part = @( $input | ForEach-Object {
            @{ name = 'input'; part = @(
                @{ name = 'type'; valueString = $_.type }
                @{ name = 'url';  valueUri    = $_.url }
                @{ name = 'etag'; valueUri    = $_.etag }
              ) }
          }) }
    )
  } | ConvertTo-Json -Depth 20

  Write-Host "  submitting $($ordered.Count) file(s)"
  $ordered | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

  try {
    $resp = Invoke-WebRequest -Uri "$fhirUrl/`$import" -Method Post -Headers $headers -Body $body -SkipHttpErrorCheck
  } catch {
    Write-Error "  submit failed: $_"; continue
  }

  if ($resp.StatusCode -ne 202) {
    Write-Host "  HTTP $($resp.StatusCode)" -ForegroundColor Red
    Write-Host "  $($resp.Content)" -ForegroundColor Red
    if ($resp.StatusCode -eq 403) {
      Write-Host @"

  403 on submit means the CALLER lacks FHIR Data Importer/Contributor.
  403 later, on GetBlobProperties, means the FHIR SERVICE's system-assigned
  identity lacks Storage Blob Data Contributor. Different identity, different fix.
  See runbooks/import-troubleshooting.md.
"@ -ForegroundColor Yellow
    }
    continue
  }

  $pollUrl = $resp.Headers['Content-Location'] | Select-Object -First 1
  Write-Host "  202 Accepted -> $pollUrl" -ForegroundColor Green

  $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
  $delay = 5
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $delay
    $token = az account get-access-token --resource $fhirUrl --query accessToken -o tsv
    $poll = Invoke-WebRequest -Uri $pollUrl -Headers @{ Authorization = "Bearer $token" } -SkipHttpErrorCheck

    if ($poll.StatusCode -eq 202) {
      $pct = ($poll.Headers['X-Progress'] | Select-Object -First 1)
      Write-Host "  ... $pct" -ForegroundColor DarkGray
      $delay = [math]::Min($delay * 2, 30)
      continue
    }

    if ($poll.StatusCode -eq 200) {
      $r = $poll.Content | ConvertFrom-Json
      Write-Host "  COMPLETE  transactionTime=$($r.transactionTime)" -ForegroundColor Green
      foreach ($o in $r.output) { Write-Host ("    {0,-26} {1,8} imported" -f $o.type, $o.count) }
      if ($r.error -and $r.error.Count) {
        Write-Host "  PARTIAL SUCCESS - $($r.error.Count) error file(s):" -ForegroundColor Yellow
        foreach ($e in $r.error) { Write-Host ("    {0,-26} {1,8} rejected  {2}" -f $e.type, $e.count, $e.url) -ForegroundColor Yellow }
        Write-Host "  Rejected rows are NOT retried automatically. Fix and resubmit those files only." -ForegroundColor Yellow
      }
      break
    }

    Write-Host "  HTTP $($poll.StatusCode)" -ForegroundColor Red
    Write-Host "  $($poll.Content)" -ForegroundColor Red
    if ($poll.StatusCode -eq 403) {
      Write-Host @"

  This is the platform lead's failure mode. Confirm which of the two it is:
    Live  -> StorageBlobLogs | where OperationName == 'GetBlobProperties' and StatusCode == 403
             will show a row with the calling object id in the last 5 minutes.
    Cached-> storage sees NO request. The job is terminal; the body is a replay.
             Re-submitting the same payload returns this same job - registration
             is idempotent. Re-run with -Force to bump the ETag and get a new id.
"@ -ForegroundColor Yellow
    }
    break
  }
}
