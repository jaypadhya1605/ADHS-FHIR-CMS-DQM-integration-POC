# The `$import` 403 — root cause, fix, and how to avoid re-diagnosing it

**Environment** `ste-test-01` (`accde124-a45f-47be-aefa-b09362b2c5fc`) · `rg-dev-interop`
**FHIR service** `devfhirahdsworkspace/dev-fhir-ahds-inbound`
**Storage** `devfhirinbound`, container `pdex`
**Reported by** Platform Engineering, 2026-08-13 · **Confirmed** 2026-08-14

---

## Symptom

`$import` accepted the job with `202`, then the poll returned `403`:

```
Failed to get properties of blob
https://devfhirinbound.blob.core.windows.net/pdex/MSSP/Group01/.../part-000001.ndjson
```

Failing jobs `d90c9658-59c1-4a39-9995-098259bdcac2` (896) and
`b3abdeb8-95bd-4737-bb3e-adea4f5276ef` (899). An earlier job (153) had succeeded — `transactionTime
2026-08-05T10:29:01.45+00:00`, 244 `ExplanationOfBenefit` — which made this look like a regression
rather than a permission gap.

Storage Blob Data Contributor **was** assigned. That is what made it confusing.

---

## Root cause

The role was on the wrong identity.

| | |
|---|---|
| Identity that **held** the role | `mi-pophealth-fhir-inbound-test-01-westus2` — user-assigned MI, client `324cb15a-566b-442c-826d-43451d671cc0`, object `0cff6f29-3e44-4df0-8099-59a1f342083b` |
| Identity that **made the request** | `devfhirahdsworkspace/fhirservices/dev-fhir-ahds-inbound` — the FHIR service's own enterprise application, object `7d1e195d-2708-4a22-8470-87ad4811e8e1` |

**AHDS `$import` reads the integration data store as the FHIR service's own service principal, not
as a user-assigned managed identity attached to the service.** Attaching a UAMI and granting it
storage access changes nothing about which identity performs the blob read.

The naming is what makes this hard to spot: the enterprise application is named after the FHIR
service, so it reads like a description of the resource rather than a security principal you must
grant a role to.

### The unresolved detail

The Identity blade for `dev-fhir-ahds-inbound` showed system-assigned identity **Off**, while a
service principal named after that exact service was making authenticated calls to storage. Those
two facts do not reconcile.

Most likely: the principal is a platform-managed identity that exists independently of the
system-assigned toggle. But it has not been confirmed, and **it is a production blocker** — if the
principal's lifecycle is not understood, a role assignment against it cannot be relied on. Raise it
with the AHDS product group before production.

The v4 template sidesteps the ambiguity entirely by setting
`identity: { type: 'SystemAssigned' }` explicitly and granting **that** principal.

---

## Fix

[infra/modules/rbac.bicep](../infra/modules/rbac.bicep):

```bicep
resource importExportGrant 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (pid, i) in fhirPrincipalIds: {
  scope: storage
  name: guid(storage.id, pid, storageBlobDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributor)
    principalId: pid                      // the FHIR service's SYSTEM-ASSIGNED principal
    principalType: 'ServicePrincipal'
  }
}]
```

`principalType: 'ServicePrincipal'` is not decorative — without it, ARM may evaluate the assignment
before Entra has replicated the principal and fail with `PrincipalNotFound`.

Equivalent CLI for an existing service:

```powershell
$fhirPrincipal = az resource show -g <rg> `
  --resource-type Microsoft.HealthcareApis/workspaces/fhirservices `
  -n "<workspace>/<service>" --query identity.principalId -o tsv

az role assignment create `
  --assignee-object-id $fhirPrincipal --assignee-principal-type ServicePrincipal `
  --role "Storage Blob Data Contributor" `
  --scope $(az storage account show -g <rg> -n <storage> --query id -o tsv)
```

Allow a few minutes for propagation before retesting.

---

## The follow-up that looked like the fix had failed

On 2026-08-14 Platform Engineering reported: a **new** file imported successfully, while the **previously tested**
file still returned 403 — same poll URL, and **no `GetBlobProperties` request reaching storage at
all**.

That last detail is the whole answer.

**An import job is immutable once terminal.** Polling a completed job returns the `OperationOutcome`
that was persisted when it finished. It is a stored record, not a re-evaluated authorisation
decision. Job 899 failed on 8/13 under the old permissions; polling it on 8/14 replays that failure
regardless of what changed in between. Storage sees nothing because no blob read occurs.

The new file created a **new** job, which ran under the corrected permissions and succeeded. Both
observations are consistent with the fix having worked.

### Telling the two apart in thirty seconds

| | Live 403 | Replayed 403 |
|---|---|---|
| `StorageBlobLogs` in the last 5 min | a `GetBlobProperties` row, `StatusCode 403`, with the calling object id | **nothing** |
| Poll URL | from a POST you just issued | the same URL as before |
| Response body | may vary | byte-identical every time |

```kusto
StorageBlobLogs
| where TimeGenerated > ago(15m)
| where StatusCode == 403
| project TimeGenerated, OperationName, Uri, RequesterObjectId, AuthenticationType
```

Empty result while `$import` returns 403 ⇒ the 403 is cached.

### Retesting correctly

Never retest by re-polling. Force a new job id:

1. Copy the NDJSON to a new blob path (`pdex/retest-<timestamp>/...`).
2. Issue a fresh `POST {fhir}/$import`.
3. Confirm the returned `Content-Location` job id **differs** from the previous one.
4. Poll the new URL.

Implemented as `-Force` in [scripts/run-import.ps1](../scripts/run-import.ps1).

---

## The general rule

> **Three different identities can be involved in a single `$import`, and granting the wrong one
> produces a 403 that looks identical to granting nothing at all.**

| Identity | Needs | Failure mode |
|---|---|---|
| The **caller** submitting `$import` | FHIR Data Contributor / Importer on the FHIR service | `403` **on the POST** |
| The **FHIR service** reading blobs | Storage Blob Data Contributor on the storage account | `403` **on the poll**, `GetBlobProperties` |
| A **UAMI** attached to the service | nothing, for `$import` | grants have no effect |

The position of the 403 — submit versus poll — tells you which identity to look at. That distinction
is the fastest available diagnostic and is built into the error handling in
[scripts/run-import.ps1](../scripts/run-import.ps1).

---

## Preventing the recurrence

1. **Never grant storage access to a UAMI for `$import` and assume it applies.** It does not.
2. **Set `identity.type: 'SystemAssigned'` explicitly** in IaC. Relying on an implicitly-created
   principal is how the dev environment reached an unexplainable state.
3. **Keep the role assignment in the same template as the FHIR service.** Split across templates or
   done by hand, it drifts — at forty instances, it will drift.
4. **Disable shared-key access on the storage account** (`allowSharedKeyAccess: false`, set in
   [infra/modules/storage.bicep](../infra/modules/storage.bicep)). It removes the tempting workaround
   that hides the real problem until production.
5. **Add a smoke test** that runs `$import` of a single-row NDJSON after every environment change.
   Ninety seconds, and it catches this class of failure before a payer does.
