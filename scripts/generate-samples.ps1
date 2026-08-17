<#
.SYNOPSIS
  Generates FHIR R4 NDJSON for the Providence CMS-0057-F POC and uploads it to
  the integration data store.

.DESCRIPTION
  Produces Patient, Coverage, ExplanationOfBenefit and Group resources for each
  contract, then writes NDJSON to the `pdex` container using Entra credentials
  (the storage account has shared-key access disabled on purpose).

  Two things here are deliberate and worth reading before you copy this pattern:

  1. RESOURCE IDS ARE NAMESPACED.  `$import` preserves the `id` in the NDJSON
     verbatim. Two payers that both send `Patient/12345` will silently overwrite
     each other. Every id is prefixed `{payer}-{contract}-`.

  2. EVERY RESOURCE CARRIES meta.tag.  The tag is what the APIM outbound policy
     filters on. A resource without it is invisible to every payer, which is the
     safe failure mode.

.EXAMPLE
  ./generate-samples.ps1 -PatientsPerContract 25
  ./generate-samples.ps1 -PatientsPerContract 2000 -SkipUpload   # load-test volume
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = 'rg-ahds-fhir-poc',
  [int]$PatientsPerContract = 25,
  [int]$ClaimsPerPatient = 3,
  [string]$OutputRoot = "$PSScriptRoot/../samples/generated",
  [switch]$SkipUpload
)

$ErrorActionPreference = 'Stop'
$TagSystem = 'https://providence.org/fhir/contract'

# Mirrors infra/main.bicepparam. Kept as a literal so the script can run before
# the deployment outputs exist.
$payers = @(
  @{ key = 'payera'; name = 'Contoso Health Plan';         contracts = @('CT-3456','CT-7788') }
  @{ key = 'payerb'; name = 'Fabrikam Medicare Advantage'; contracts = @('CT-9001') }
)

$givenNames  = @('Avery','Jordan','Riley','Casey','Morgan','Quinn','Rowan','Sage','Emerson','Harper','Devon','Ellis')
$familyNames = @('Alvarez','Bennett','Castillo','Donovan','Eriksen','Fontaine','Guzman','Hollis','Ibarra','Jamison')
$eobTypes    = @(
  @{ code = 'MED'; display = 'Medical Service Provider'; amount = 1250.00 }
  @{ code = 'PHARM'; display = 'Pharmacy'; amount = 89.40 }
  @{ code = 'INST'; display = 'Institutional'; amount = 8420.75 }
)

function New-Meta([string]$contract) {
  @{ tag = @( @{ system = $TagSystem; code = $contract } ) }
}

function Write-Ndjson($objects, [string]$path) {
  $dir = Split-Path -Parent $path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $sw = [System.IO.StreamWriter]::new($path, $false, [System.Text.UTF8Encoding]::new($false))
  try {
    foreach ($o in $objects) { $sw.WriteLine(($o | ConvertTo-Json -Depth 30 -Compress)) }
  } finally { $sw.Dispose() }
  Write-Host ("  {0,-42} {1,6} resources" -f (Split-Path -Leaf $path), $objects.Count)
}

$rand = [System.Random]::new(20260812)   # fixed seed - reproducible demos

foreach ($p in $payers) {
  Write-Host "`n$($p.name)  [$($p.key)]" -ForegroundColor Cyan

  foreach ($contract in $p.contracts) {
    $short   = $contract.Replace('-','').ToLower()
    $prefix  = "$($p.key)-$short"
    $outDir  = Join-Path $OutputRoot "$($p.key)/$contract"
    $meta    = New-Meta $contract

    $patients = @(); $coverages = @(); $eobs = @(); $memberRefs = @()

    for ($i = 1; $i -le $PatientsPerContract; $i++) {
      # NB: not $pid - that is a read-only PowerShell automatic variable.
      $patientId = "$prefix-pat-{0:D5}" -f $i
      $memberRefs += @{ entity = @{ reference = "Patient/$patientId" } }

      $patients += @{
        resourceType = 'Patient'
        id           = $patientId
        meta         = $meta
        identifier   = @( @{ system = "https://$($p.key).example.org/member"; value = "$short-M{0:D6}" -f $i } )
        active       = $true
        name         = @( @{ use = 'official'
                             family = $familyNames[$rand.Next($familyNames.Count)]
                             given  = @($givenNames[$rand.Next($givenNames.Count)]) } )
        gender       = @('male','female','other')[$rand.Next(3)]
        birthDate    = ('{0:D4}-{1:D2}-{2:D2}' -f $rand.Next(1935,2006), $rand.Next(1,13), $rand.Next(1,29))
        address      = @( @{ state = 'WA'; postalCode = ('{0:D5}' -f $rand.Next(98001,99404)); country = 'US' } )
      }

      $coverages += @{
        resourceType  = 'Coverage'
        id            = "$prefix-cov-{0:D5}" -f $i
        meta          = $meta
        status        = 'active'
        beneficiary   = @{ reference = "Patient/$patientId" }
        payor         = @( @{ display = $p.name } )
        subscriberId  = "$short-M{0:D6}" -f $i
        period        = @{ start = '2026-01-01'; end = '2026-12-31' }
        class         = @( @{ type = @{ coding = @( @{ system = 'http://terminology.hl7.org/CodeSystem/coverage-class'; code = 'group' } ) }
                              value = $contract
                              name  = "$($p.name) $contract" } )
      }

      for ($c = 1; $c -le $ClaimsPerPatient; $c++) {
        $t = $eobTypes[$rand.Next($eobTypes.Count)]
        $billed = [math]::Round($t.amount * (0.6 + $rand.NextDouble()), 2)
        $eobs += @{
          resourceType = 'ExplanationOfBenefit'
          id           = "$prefix-eob-{0:D5}-{1:D2}" -f $i, $c
          meta         = $meta
          status       = 'active'
          type         = @{ coding = @( @{ system = 'http://terminology.hl7.org/CodeSystem/claim-type'; code = 'professional' } ) }
          use          = 'claim'
          patient      = @{ reference = "Patient/$patientId" }
          created      = ('2026-{0:D2}-{1:D2}T09:00:00Z' -f $rand.Next(1,9), $rand.Next(1,29))
          insurer      = @{ display = $p.name }
          provider     = @{ display = 'Providence St. Joseph Health' }
          outcome      = 'complete'
          insurance    = @( @{ focal = $true; coverage = @{ reference = "Coverage/$prefix-cov-{0:D5}" -f $i } } )
          total        = @( @{ category = @{ coding = @( @{ system = 'http://terminology.hl7.org/CodeSystem/adjudication'; code = 'submitted' } ) }
                               amount   = @{ value = $billed; currency = 'USD' } } )
          item         = @( @{ sequence = 1
                               productOrService = @{ coding = @( @{ system = 'https://providence.org/fhir/service-type'; code = $t.code; display = $t.display } ) } } )
        }
      }
    }

    # The Group is the export unit. Group/{id}/$export is the ONLY export verb the
    # outbound APIM policy allows - system- and patient-level exports are rejected.
    $group = @{
      resourceType = 'Group'
      id           = "group-$short"
      meta         = $meta
      identifier   = @( @{ system = $TagSystem; value = $contract } )
      active       = $true
      type         = 'person'
      actual       = $true
      name         = "$($p.name) - $contract member cohort"
      quantity     = $PatientsPerContract
      member       = $memberRefs
    }

    Write-Ndjson $patients  (Join-Path $outDir 'Patient.ndjson')
    Write-Ndjson $coverages (Join-Path $outDir 'Coverage.ndjson')
    Write-Ndjson $eobs      (Join-Path $outDir 'ExplanationOfBenefit.ndjson')
    Write-Ndjson @($group)  (Join-Path $outDir 'Group.ndjson')
  }
}

if ($SkipUpload) { Write-Host "`nGenerated under $OutputRoot. Upload skipped." -ForegroundColor Yellow; return }

$storage = az storage account list -g $ResourceGroup --query "[0].name" -o tsv
if (-not $storage) { throw "No storage account found in $ResourceGroup. Deploy infra/main.bicep first." }
Write-Host "`nUploading to $storage/pdex (Entra auth - shared keys are disabled)" -ForegroundColor Cyan

az storage blob upload-batch `
  --account-name $storage `
  --auth-mode login `
  --destination pdex `
  --source $OutputRoot `
  --overwrite `
  --output none

Write-Host "Upload complete." -ForegroundColor Green
az storage blob list --account-name $storage --auth-mode login -c pdex --query "[].{blob:name, bytes:properties.contentLength}" -o table
