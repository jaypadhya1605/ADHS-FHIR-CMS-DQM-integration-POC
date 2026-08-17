# How to run the demo

Two ways to run it. Pick based on how much time you have.

| | Time | Use when |
|---|---|---|
| **A — Live proof run** | 3 minutes | Default. One command, 16 assertions, green table on screen. |
| **B — Guided walkthrough** | 25 minutes | Working session. Each control demonstrated and explained. |

Everything below runs against the deployed environment in `rg-ahds-fhir-poc`. Nothing needs to be
built first.

---

## Before the call

```powershell
cd "<repo>/v4"
az account set --subscription 2852c4f9-8fcc-47c1-8e96-c4142a9ae463
./scripts/show-env.ps1
```

Confirms the environment is up and prints the resource names. If the resource group was deleted to
save cost, rebuild it — see [Rebuilding](#rebuilding-from-nothing) at the end. Allow ~20 minutes,
almost all of it API Management.

Warm the gateway with one throwaway run so the first live call is not a cold start:

```powershell
./scripts/run-isolation-tests.ps1 | Out-Null
```

Then wait 5 minutes before the real run, or pass `-SkipThrottleTest`, because the export lock is
held for 300 seconds per payer.

---

## Option A — the three-minute proof

```powershell
./scripts/run-isolation-tests.ps1
```

**What to say while it runs.** This mints a short-lived credential for each of two payers, exercises
sixteen assertions against the live gateway, and revokes the credentials. Nothing is written to
disk. The assertions are the security guarantees — if the model is wrong, this goes red.

**Expected output:**

```
  # Test                                Expected         Actual Result
  1 own data readable                   200                 200 PASS
  2 Group export accepted               202                 202 PASS
  3 capability statement                200                 200 PASS
  4 payer B app, valid payer A audience 403                 403 PASS
  5 payer B token, payer B audience     401/403             401 PASS
  6 unentitled Group export             403                 403 PASS
  7 write on outbound route             403                 403 PASS
  8 payer credential on inbound route   403                 403 PASS
  9 export on inbound route             403                 403 PASS
 10 system-level export                 403                 403 PASS
 11 patient-level export                403                 403 PASS
 12 payer token straight to AHDS        403                 403 PASS
 13 caller-supplied _tag overridden     200                 200 PASS
 14 untagged inbound write rejected     400/403             403 PASS
 15 second export within 5 min          429                 429 PASS
13b body contains only own contracts    CT-3456/CT-7788 CT-3456 PASS

All 16 assertions passed.
```

**The three lines to point at:**

| Line | Why it matters |
|---|---|
| **4** | A valid, correctly-audienced token from the wrong payer is refused. This is the PHI boundary, and it holds even when the token itself is legitimate. |
| **12** | The payer's token sent *directly* to the FHIR service returns 403 — not 401. Entra issued the token; the application simply holds no role. This is why "enforced at the gateway" is a boundary and not a speed bump. |
| **13b** | The response body was inspected, not just the status code. Only the caller's own contracts came back. |

That is the whole argument in one screen.

---

## Option B — the guided walkthrough

### 1. Show the isolation is physical, not a filter (2 min)

```powershell
az resource list -g rg-ahds-fhir-poc `
  --resource-type Microsoft.HealthcareApis/workspaces/fhirservices `
  --query "[].{service:name, identity:identity.principalId}" -o table
```

Two FHIR services, one per payer, each with its own system-assigned identity. Adding the fortieth
payer is one array entry in [infra/main.bicepparam](infra/main.bicepparam) and a redeploy — never a
hand-built instance.

Open [diagrams/providence-ahds-reference-architecture.drawio](diagrams/providence-ahds-reference-architecture.drawio),
page 2, and confirm this is the option that was agreed: physical at the payer, logical at the
contract.

### 2. Show that no payer holds a role (2 min)

```powershell
$fhirId = az resource show -g rg-ahds-fhir-poc `
  --resource-type Microsoft.HealthcareApis/workspaces/fhirservices `
  -n "ahdspocdecotsv3/fhir-payera" --query id -o tsv

az role assignment list --scope $fhirId `
  --query "[].{role:roleDefinitionName, principal:principalId, type:principalType}" -o table
```

The gateway's managed identity holds FHIR Data Contributor. The operator holds a role. **No payer
application appears.** That absence is the control — everything else in the policy depends on it.

### 3. Show the storage grant that fixes the import 403 (2 min)

```powershell
az role assignment list `
  --scope $(az storage account show -g rg-ahds-fhir-poc -n stpocahdsdecotsv3 --query id -o tsv) `
  --query "[?roleDefinitionName=='Storage Blob Data Contributor'].principalId" -o tsv
```

Cross-reference against the principal ids from step 1: the grant is on each **FHIR service's own
system-assigned identity**, which is the identity `$import` actually uses to read blobs. Granting a
user-assigned managed identity instead produces a 403 that looks identical to granting nothing —
that is the failure that blocked the dev environment.

Detail: [docs/04-import-403-rootcause.md](docs/04-import-403-rootcause.md).

### 4. Run the proof suite (3 min)

```powershell
./scripts/run-isolation-tests.ps1
```

As Option A. Walk lines 4, 12 and 13b.

### 5. Onboard a payer live (4 min)

```powershell
./scripts/onboard-payer.ps1 -PayerKey payerc -DisplayName "Northwind Health" -Contracts CT-5150
```

Seven steps, narrated as it goes: register the application, issue a credential, define the Group,
confirm the data is tagged, add the entitlement record, **grant no Azure role**, print the handoff
sheet.

The handoff sheet lands in `out/payer-payerc-handoff.txt` and contains no credential material by
construction.

Offboarding is one command — `az ad app delete --id <appId>` — and every downstream check fails
closed.

Runbook: [runbooks/payer-onboarding.md](runbooks/payer-onboarding.md).

### 6. Show the observability (3 min)

Portal → `log-ahds-decotsv3` → Logs:

```kusto
// Every gateway denial in the last day, by route. The isolation model, observed.
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h) and ResponseCode in (401, 403, 429)
| summarize count() by ApiId, ResponseCode
| order by count_ desc
```

The test run you just did appears here. The security model is not only enforced, it is auditable.

```kusto
// Distinguishes a live permission failure from a replayed import job result.
StorageBlobLogs
| where TimeGenerated > ago(2h) and StatusCode == 403
| project TimeGenerated, OperationName, Uri, RequesterObjectId
```

Empty while `$import` returns 403 means the 403 is cached, not live. That single query removes a
whole class of false alarms.

### 7. Show the capacity harness (2 min)

```powershell
./loadtest/run-loadtest.ps1 -Concurrency 1,5,15 -WhatIf
```

Do not run it live — it takes too long. Show what it measures and why concurrent export behaviour is
the one question that cannot be answered from documentation.

[docs/05-capacity-and-scale.md](docs/05-capacity-and-scale.md).

---

## Demonstrating a failure on purpose

The most persuasive moment is a control failing correctly.

```powershell
# Grant a payer a direct FHIR role - the "helpful debugging" mistake
$appId = az ad app list --display-name providence-cmsdqm-payerb --query "[0].appId" -o tsv
$spId  = az ad sp show --id $appId --query id -o tsv
$fhirA = az resource show -g rg-ahds-fhir-poc `
  --resource-type Microsoft.HealthcareApis/workspaces/fhirservices `
  -n "ahdspocdecotsv3/fhir-payera" --query id -o tsv

az role assignment create --assignee-object-id $spId --assignee-principal-type ServicePrincipal `
  --role "FHIR Data Reader" --scope $fhirA

# Wait ~2 min for propagation, then:
./scripts/run-isolation-tests.ps1
```

Assertion **12** turns red. One well-intentioned role assignment downgrades every gateway policy
from a control to a suggestion, and nothing else changes to signal it.

Undo it:

```powershell
az role assignment delete --assignee $spId --role "FHIR Data Reader" --scope $fhirA
```

**This is the argument for keeping the suite in CI.** It is the only thing that notices.

---

## Rebuilding from nothing

```powershell
cd v4/infra
az deployment group create -g rg-ahds-fhir-poc -f main.bicep -p main.bicepparam

cd ..
./scripts/generate-samples.ps1 -PatientsPerContract 25
./scripts/load-fhir-direct.ps1
./scripts/onboard-payer.ps1 -PayerKey payera -DisplayName 'Contoso Health Plan' -Contracts CT-3456,CT-7788
./scripts/onboard-payer.ps1 -PayerKey payerb -DisplayName 'Fabrikam Medicare Advantage' -Contracts CT-9001
./scripts/run-isolation-tests.ps1
```

~20 minutes, almost all of it API Management.

**Redeploying resets the APIM entitlement store**, because the named value is declared with an empty
default. Re-run both `onboard-payer.ps1` calls after any `az deployment group create`. In production
the entitlement store should be backed by the contract master rather than a named value, which
removes the problem entirely.

---

## Tearing down

```powershell
az group delete -n rg-ahds-fhir-poc --yes --no-wait
```

AHDS FHIR has no pause state — a provisioned service bills whether or not it is used. Delete between
demos: ~$10 per demo day versus ~$450 per month left running.

---

## If something goes wrong

| Symptom | Cause and fix |
|---|---|
| Every assertion returns 403 "not onboarded" | The entitlement named value was reset by a redeploy. Re-run `onboard-payer.ps1` for both payers, wait ~60s for APIM to pick it up. |
| Assertion 15 returns 202 instead of 429 | The 300-second export lock expired between runs. Expected on a rerun; re-run immediately after a previous run, or pass `-SkipThrottleTest`. |
| Assertion 2 returns 400 | `Accept` header. AHDS rejects `$export` unless `Accept: application/fhir+json` is set; the gateway injects it. Confirm the outbound policy deployed. |
| Token acquisition fails | New Entra credentials take a few seconds to replicate. The script already retries six times over 30 seconds. |
| `az` says "blocked by network rules" on storage or Key Vault | Tenant policy forces `publicNetworkAccess: Disabled` in this subscription. Expected here, not in the customer tenant. See [docs/00-poc-environment.md](docs/00-poc-environment.md). |
