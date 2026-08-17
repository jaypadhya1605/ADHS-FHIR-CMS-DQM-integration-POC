<#
.SYNOPSIS
  Loads the generated NDJSON into the FHIR services over the REST API.

.DESCRIPTION
  A fallback for `$import` when the integration data store cannot be written to
  from the operator's machine.

  In this demo subscription a tenant governance policy forces
  `publicNetworkAccess = Disabled` on every storage account - an ARM PATCH setting
  it to Enabled is silently reverted by a Modify-effect policy. AHDS itself can
  still read the container (networkAcls.bypass = AzureServices covers trusted
  first-party services), so `$import` would work; the blocked step is uploading
  the NDJSON from outside Azure.

  Providence's own subscription will not have this restriction, so
  scripts/run-import.ps1 remains the production path and the RBAC wiring it
  depends on is deployed and verifiable. This script exists so the isolation
  demo does not depend on resolving someone else's policy.

  Resources are written with PUT (update-as-create) so the ids in the NDJSON are
  preserved verbatim - the same semantics as `$import`, including the id-collision
  hazard the sample data is namespaced to avoid.

.EXAMPLE
  ./load-fhir-direct.ps1
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-ahds-fhir-poc',
  [string]$SamplesRoot = "$PSScriptRoot/../samples/generated",
  [int]$BatchSize = 50
)

$ErrorActionPreference = 'Stop'
$ws = az resource list -g $ResourceGroup --resource-type 'Microsoft.HealthcareApis/workspaces' --query "[0].name" -o tsv

# Referenced types first; Group last, because it references the Patients.
$order = @('Patient', 'Coverage', 'ExplanationOfBenefit', 'Group')

$payerDirs = Get-ChildItem $SamplesRoot -Directory
foreach ($pd in $payerDirs) {
  $payer   = $pd.Name
  $fhirUrl = "https://$ws-fhir-$payer.fhir.azurehealthcareapis.com"
  Write-Host "`n=== $payer -> $fhirUrl ===" -ForegroundColor Cyan

  $token = az account get-access-token --resource $fhirUrl --query accessToken -o tsv
  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/fhir+json' }
  $tokenAge = [Diagnostics.Stopwatch]::StartNew()

  foreach ($cd in Get-ChildItem $pd.FullName -Directory) {
    Write-Host "  contract $($cd.Name)" -ForegroundColor White

    foreach ($type in $order) {
      $file = Join-Path $cd.FullName "$type.ndjson"
      if (-not (Test-Path $file)) { continue }

      # -Raw + explicit split: Get-Content on a single-line file returns a String,
      # and indexing a String yields characters rather than lines.
      $lines = @((Get-Content $file -Raw) -split "`r?`n" | Where-Object { $_.Trim() })
      $ok = 0; $fail = 0

      for ($i = 0; $i -lt $lines.Count; $i += $BatchSize) {
        # Tokens last an hour; refresh well inside that on large loads.
        if ($tokenAge.Elapsed.TotalMinutes -gt 40) {
          $token = az account get-access-token --resource $fhirUrl --query accessToken -o tsv
          $headers.Authorization = "Bearer $token"
          $tokenAge.Restart()
        }

        $slice = @($lines[$i..([math]::Min($i + $BatchSize - 1, $lines.Count - 1))])
        $entries = @(foreach ($l in $slice) {
          $r = $l | ConvertFrom-Json
          @{
            resource = $r
            request  = @{ method = 'PUT'; url = "$($r.resourceType)/$($r.id)" }
          }
        })

        $bundle = @{ resourceType = 'Bundle'; type = 'transaction'; entry = $entries } | ConvertTo-Json -Depth 40
        $resp = Invoke-WebRequest -Uri $fhirUrl -Method Post -Headers $headers -Body $bundle -SkipHttpErrorCheck

        if ($resp.StatusCode -eq 200) {
          $rb = $resp.Content | ConvertFrom-Json
          $statuses = @($rb.entry.response.status)
          if ($statuses.Count) {
            $ok   += @($statuses | Where-Object { $_ -match '^(200|201)' }).Count
            $fail += @($statuses | Where-Object { $_ -notmatch '^(200|201)' }).Count
          } else {
            $ok += $slice.Count
          }
        } else {
          $fail += $slice.Count
          Write-Host "      HTTP $($resp.StatusCode) on batch at offset $i" -ForegroundColor Red
          Write-Host "      $($resp.Content.Substring(0, [math]::Min(500, $resp.Content.Length)))" -ForegroundColor DarkRed
        }
      }

      $colour = if ($fail) { 'Yellow' } else { 'Green' }
      Write-Host ("    {0,-24} {1,5} loaded  {2,4} failed" -f $type, $ok, $fail) -ForegroundColor $colour
    }
  }
}

Write-Host "`nVerifying counts and tag integrity" -ForegroundColor Cyan
foreach ($pd in $payerDirs) {
  $payer = $pd.Name
  $fhirUrl = "https://$ws-fhir-$payer.fhir.azurehealthcareapis.com"
  $token = az account get-access-token --resource $fhirUrl --query accessToken -o tsv
  $h = @{ Authorization = "Bearer $token" }

  Write-Host "  $payer" -ForegroundColor White
  foreach ($type in $order) {
    $c = (Invoke-RestMethod -Uri "$fhirUrl/$type`?_summary=count" -Headers $h).total
    Write-Host ("    {0,-24} {1,5}" -f $type, $c)
  }
  # An untagged resource is invisible to every payer. This must be zero.
  $untagged = (Invoke-RestMethod -Uri "$fhirUrl/Patient?_tag:missing=true&_summary=count" -Headers $h).total
  $colour = if ($untagged -eq 0) { 'Green' } else { 'Red' }
  Write-Host ("    {0,-24} {1,5}" -f 'untagged Patients', $untagged) -ForegroundColor $colour
}
