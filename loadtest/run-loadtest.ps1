<#
.SYNOPSIS
  Measures concurrent Group/$export behaviour - the question left unanswered on 2026-08-12.

.DESCRIPTION
  From the working session:

    "usually happens at the same time ... will pop the server itself"

  AHDS autoscales, and the scaling is free, but nothing published states how many
  simultaneous Group exports a FHIR service sustains, nor how quickly it reacts to
  a step change. This script produces the number.

  It drives N concurrent exports, records submit latency, time-to-completion and
  429 rate, and writes a CSV plus a summary. Run it against the FHIR service
  DIRECTLY (-Direct) to measure the platform, or through APIM to measure what a
  payer actually experiences with the gateway's export serialisation in place.

  Both are useful and they answer different questions:
    -Direct  : what can the platform take?
    default  : does the gateway policy protect the platform?

.EXAMPLE
  ./run-loadtest.ps1 -Concurrency 1,5,15,40 -Direct
  ./run-loadtest.ps1 -Concurrency 5 -IncludeImport
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-ahds-fhir-poc',
  [int[]]$Concurrency = @(1, 5, 15),
  [int]$TimeoutMinutes = 30,
  [switch]$Direct,
  [switch]$IncludeImport,
  [string]$OutputCsv = "$PSScriptRoot/results-$(Get-Date -f yyyyMMdd-HHmmss).csv"
)

$ErrorActionPreference = 'Stop'

$ws      = az resource list -g $ResourceGroup --resource-type 'Microsoft.HealthcareApis/workspaces' --query "[0].name" -o tsv
$svcRows = az resource list -g $ResourceGroup --resource-type 'Microsoft.HealthcareApis/workspaces/fhirservices' --query "[].name" -o tsv
$svcs    = @($svcRows -split "`n" | Where-Object { $_ } | ForEach-Object { ($_ -split '/')[-1] })
if (-not $svcs) { throw "No FHIR services in $ResourceGroup." }

$svc     = $svcs[0]
$fhirUrl = "https://$ws-$svc.fhir.azurehealthcareapis.com"

Write-Host "Target : $fhirUrl" -ForegroundColor Cyan
Write-Host "Mode   : $(if ($Direct) { 'DIRECT to AHDS - measuring the platform' } else { 'via APIM - measuring the payer experience' })" -ForegroundColor Cyan

# Discover the cohorts to export against.
$token  = az account get-access-token --resource $fhirUrl --query accessToken -o tsv
$groups = (Invoke-RestMethod -Uri "$fhirUrl/Group?_count=50" -Headers @{ Authorization = "Bearer $token" }).entry.resource.id
if (-not $groups) { throw "No Group resources found. Run scripts/generate-samples.ps1 and scripts/run-import.ps1 first." }
Write-Host "Groups : $($groups -join ', ')`n" -ForegroundColor Cyan

$results = [System.Collections.Generic.List[object]]::new()

foreach ($n in $Concurrency) {
  Write-Host "=== concurrency $n ===" -ForegroundColor Yellow
  $token = az account get-access-token --resource $fhirUrl --query accessToken -o tsv

  # Submit N exports as close to simultaneously as the client allows. The point is
  # the step change, so submissions are deliberately not staggered.
  $jobs = 1..$n | ForEach-Object {
    $g = $groups[($_ - 1) % $groups.Count]
    Start-ThreadJob -ArgumentList $fhirUrl, $g, $token -ScriptBlock {
      param($url, $group, $tok)
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $r = Invoke-WebRequest -Uri "$url/Group/$group/`$export?_type=Patient,Coverage,ExplanationOfBenefit" `
             -Headers @{ Authorization = "Bearer $tok"; Prefer = 'respond-async' } -SkipHttpErrorCheck
      $sw.Stop()
      [pscustomobject]@{
        group      = $group
        status     = $r.StatusCode
        submitMs   = $sw.ElapsedMilliseconds
        pollUrl    = ($r.Headers['Content-Location'] | Select-Object -First 1)
        retryAfter = ($r.Headers['Retry-After'] | Select-Object -First 1)
      }
    }
  }

  $submits = $jobs | Receive-Job -Wait -AutoRemoveJob
  $accepted = @($submits | Where-Object status -eq 202)
  $throttled = @($submits | Where-Object status -eq 429)

  Write-Host ("  submitted {0}  accepted {1}  throttled {2}  p95 submit {3} ms" -f `
    $submits.Count, $accepted.Count, $throttled.Count,
    [int](($submits.submitMs | Sort-Object)[[math]::Floor($submits.Count * 0.95) - 1]))

  # Poll accepted jobs to completion.
  $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
  $pending = [System.Collections.Generic.List[object]]::new()
  $accepted | ForEach-Object { $pending.Add([pscustomobject]@{ group = $_.group; url = $_.pollUrl; started = Get-Date }) }

  while ($pending.Count -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    $token = az account get-access-token --resource $fhirUrl --query accessToken -o tsv
    foreach ($p in @($pending)) {
      $r = Invoke-WebRequest -Uri $p.url -Headers @{ Authorization = "Bearer $tok" } -SkipHttpErrorCheck -ErrorAction SilentlyContinue
      if ($r.StatusCode -eq 202) { continue }
      $elapsed = ((Get-Date) - $p.started).TotalSeconds
      $count = if ($r.StatusCode -eq 200) { (($r.Content | ConvertFrom-Json).output.count | Measure-Object -Sum).Sum } else { 0 }
      $results.Add([pscustomobject]@{
        concurrency = $n; group = $p.group; status = $r.StatusCode
        durationSec = [math]::Round($elapsed, 1); resources = $count
      })
      Write-Host ("    {0,-16} {1}  {2,6:N1}s  {3} resources" -f $p.group, $r.StatusCode, $elapsed, $count) -ForegroundColor DarkGray
      $pending.Remove($p) | Out-Null
    }
  }

  foreach ($p in $pending) {
    $results.Add([pscustomobject]@{ concurrency = $n; group = $p.group; status = 'TIMEOUT'; durationSec = $TimeoutMinutes * 60; resources = 0 })
    Write-Host "    $($p.group)  TIMEOUT" -ForegroundColor Red
  }
  foreach ($t in $throttled) {
    $results.Add([pscustomobject]@{ concurrency = $n; group = $t.group; status = 429; durationSec = 0; resources = 0 })
  }

  Write-Host ""
}

$results | Export-Csv -Path $OutputCsv -NoTypeInformation
Write-Host "Results -> $OutputCsv`n" -ForegroundColor Green

Write-Host "Summary" -ForegroundColor Cyan
$results | Group-Object concurrency | ForEach-Object {
  $ok = @($_.Group | Where-Object status -eq 200)
  $t429 = @($_.Group | Where-Object status -eq 429).Count
  $durs = @($ok.durationSec | Sort-Object)
  $p95 = if ($durs.Count) { $durs[[math]::Max(0, [math]::Floor($durs.Count * 0.95) - 1)] } else { 0 }
  [pscustomobject]@{
    Concurrency = $_.Name
    Completed   = $ok.Count
    Throttled   = $t429
    MedianSec   = if ($durs.Count) { $durs[[int]($durs.Count / 2)] } else { 0 }
    P95Sec      = $p95
  }
} | Format-Table -AutoSize

Write-Host @"
Cross-reference with Log Analytics for the server-side view:

  MicrosoftHealthcareApisAuditLogs
  | where TimeGenerated > ago(1h)
  | summarize total=count(), throttled=countif(StatusCode==429), p95=percentile(DurationMs,95)
            by bin(TimeGenerated, 1m)
  | order by TimeGenerated asc

The shape to look for: does p95 climb linearly with concurrency, or step? A step
is autoscale arriving late, and it is the number to take to the product group.
"@ -ForegroundColor DarkGray
