# Runbook — `$import` troubleshooting

Decision tree first, detail after. Full RCA of the Providence dev incident:
[docs/04-import-403-rootcause.md](../docs/04-import-403-rootcause.md).

---

## The first question: where did the 403 occur?

```
POST {fhir}/$import
   │
   ├─ 403 HERE ──────────► the CALLER lacks a FHIR data role
   │                       → grant FHIR Data Contributor (or Importer) to the caller
   │
   └─ 202 Accepted
          │
          GET {Content-Location}
          │
          ├─ 403 HERE ───► the FHIR SERVICE lacks storage access
          │                → grant Storage Blob Data Contributor to the FHIR service's
          │                  SYSTEM-ASSIGNED principal
          │
          ├─ 200 + error[] ► partial success, see below
          └─ 200            ► done
```

**The position of the 403 identifies the identity.** Three principals can be involved and granting
the wrong one produces a 403 indistinguishable from granting nothing.

---

## `403` on the POST

The caller — you, or the pipeline's identity — lacks a FHIR data role.

```powershell
az role assignment create `
  --assignee <objectId> --assignee-principal-type ServicePrincipal `
  --role "FHIR Data Contributor" `
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.HealthcareApis/workspaces/<ws>/fhirservices/<svc>"
```

Then confirm the token audience is the **FHIR service URL**, not the gateway and not
`https://management.azure.com`:

```powershell
az account get-access-token --resource "https://<ws>-<svc>.fhir.azurehealthcareapis.com" --query accessToken -o tsv
```

---

## `403` on the poll — the Providence dev failure

```
Failed to get properties of blob https://<storage>.blob.core.windows.net/pdex/...
```

### First, determine whether it is live or replayed

```kusto
StorageBlobLogs
| where TimeGenerated > ago(15m)
| where StatusCode == 403
| project TimeGenerated, OperationName, Uri, RequesterObjectId, AuthenticationType
```

| Result | Meaning |
|---|---|
| A `GetBlobProperties` row with a `RequesterObjectId` | **Live** permission failure. Fix the grant. |
| **Nothing** | **Replayed.** The job is terminal; you are re-reading a stored `OperationOutcome`. Nothing is wrong now. |

A terminal import job is immutable. Polling it returns the outcome persisted when it finished, not a
fresh authorisation decision. This is what made the 2026-08-14 retest look like the fix had failed.

### If live: grant the right identity

```powershell
$fhirPrincipal = az resource show -g <rg> `
  --resource-type Microsoft.HealthcareApis/workspaces/fhirservices `
  -n "<ws>/<svc>" --query identity.principalId -o tsv

az role assignment create `
  --assignee-object-id $fhirPrincipal --assignee-principal-type ServicePrincipal `
  --role "Storage Blob Data Contributor" `
  --scope $(az storage account show -g <rg> -n <storage> --query id -o tsv)
```

If `identity.principalId` is empty, the service has no system-assigned identity. Enable it — in
[infra/modules/ahds.bicep](../infra/modules/ahds.bicep) this is
`identity: { type: 'SystemAssigned' }`.

**Granting a user-assigned managed identity does nothing for `$import`.** It is not the identity
that reads the blobs.

Allow a few minutes for propagation.

### Then retest correctly

Do not re-poll, and do not simply re-POST the same body — registration is idempotent on the request
payload, so an identical submission returns the old failed job. Force a new one:

```powershell
./scripts/run-import.ps1 -PayerKey payera -Force
```

Confirm the new `Content-Location` job id **differs** from the previous one. If it does not, the
payload did not change and you are reading the old job again. See the next section for why.

---

## Retrying an import on a deterministic blob path

The situation: the pipeline writes to fixed paths
(`.../FhirExplanationOfBenefit-1026/part-000001.ndjson`), an import failed, the cause has been fixed,
and the blob cannot be renamed.

**Unique blob names are not required. A unique registration *payload* is.**

`$import` registration is idempotent on the request body — an identical payload returns the existing
job rather than creating a new one, so a re-POST replays the old failure. Adding the optional `etag`
to each input ties the payload to blob content and resolves it:

```json
{
  "name": "input",
  "part": [
    { "name": "type", "valueString": "ExplanationOfBenefit" },
    { "name": "url",  "valueUri": "https://<storage>.blob.core.windows.net/pdex/FhirExplanationOfBenefit-1026/part-000001.ndjson" },
    { "name": "etag", "valueUri": "\"0x8DC5F1A2B3C4D5E\"" }
  ]
}
```

### The pipeline pattern

| Step | Action |
|---|---|
| 1 | Read blob properties; capture `properties.etag` for every input file |
| 2 | `POST {fhir}/$import` with `url` **and** `etag` on each input |
| 3 | Store the **job id** from `Content-Location` in run state — not the blob path |
| 4 | Poll the job id to a terminal state |
| 5 | On failure: fix the cause, rewrite the blob (new ETag), return to step 1 |

Step 3 is the one that gets skipped. Keying run state on the blob path makes the path do double duty
as both "what to import" and "which job to check" — which is exactly how a replayed 403 gets
mistaken for a live one.

### When the blob has not changed

A configuration fix — RBAC, firewall, networking — leaves the file byte-identical, so the ETag is
unchanged and the payload still deduplicates. A metadata write bumps the ETag while content and path
stay put:

```powershell
az storage blob metadata update --account-name <storage> --auth-mode login `
  -c pdex -n <path> --metadata importRetry=$(Get-Date -Format yyyyMMddHHmmss)
```

Re-read the ETag, then resubmit. `./scripts/run-import.ps1 -Force` does exactly this.

### Mode

Use `IncrementalLoad` — the default. It is safe to re-run over the same file, because matching
resource ids are updated in place, and it does not block API writes. `InitialLoad` locks the service
and returns `423 Locked` to concurrent operations; correct for a first bulk load, wrong for anything
retryable.

Reference:
[Import data into the FHIR service](https://learn.microsoft.com/azure/healthcare-apis/fhir/import-data).

---

## `200` with a non-empty `error[]`

This is **partial success**, and it is normal.

```json
{
  "transactionTime": "2026-08-14T10:29:01.45+00:00",
  "output": [ { "type": "Patient", "count": 4821, "url": "..." } ],
  "error":  [ { "type": "OperationOutcome", "count": 179, "url": "https://.../errors.ndjson" } ]
}
```

`output[]` = imported. `error[]` = rejected, with a URL to a per-file `OperationOutcome` NDJSON.

```powershell
az storage blob download --account-name <storage> --auth-mode login `
  -c <container> -n <path-from-error-url> --file errors.ndjson
Get-Content errors.ndjson | ForEach-Object { ($_ | ConvertFrom-Json).issue[0].diagnostics } | Group-Object | Sort-Object Count -Descending
```

**Rejected rows are not retried automatically.** Fix the data and resubmit only the corrected files.
Resubmitting the whole set is safe in `IncrementalLoad` mode but wasteful at 80 GB.

Frequent causes, in order:

| Cause | Fix |
|---|---|
| Profile validation failure | Validate before import; route rejects to `quarantine/` |
| Malformed JSON on a line | NDJSON is line-delimited — one bad line, one rejected resource |
| Missing required element | Usually an upstream mapping defect |
| Reference to a resource not yet imported | Order the files: referenced types first, `Group` last |

---

## Import succeeds but the data is invisible to payers

Almost always a missing `meta.tag`.

```http
GET {fhir}/Patient?_tag:missing=true&_summary=count
```

Non-zero means resources were imported without a contract tag. They exist and no payer can see
them — the safe failure mode, but still a failure.

`$import` does **not** run APIM policies. The tag must be in the NDJSON. See
[scripts/generate-samples.ps1](../scripts/generate-samples.ps1).

Remediation: re-import the affected files with the tag present. `IncrementalLoad` will update in
place, because the resource ids are unchanged.

---

## Resources overwritten between payers

`$import` preserves the `id` in the NDJSON **verbatim**. Two payers sending `Patient/12345` overwrite
each other — no error, no warning, last write wins.

Detect:

```http
GET {fhir}/Patient/12345/_history
```

Versions alternating between contract tags is the signature.

Prevent: namespace every id by payer and contract before import (`payera-ct3456-pat-00001`). Add it
as a contract test in the ingest pipeline — this is a silent data-loss bug and there is no runtime
signal.

---

## Job appears stuck

```powershell
GET {Content-Location}   # 202 with X-Progress
```

`X-Progress` reports the phase. Large files legitimately take a long time — an 80 GB NDJSON is not a
quick operation.

Before escalating, check:

1. `X-Progress` changing over 10 minutes? Then it is working.
2. Storage account throttling? `StorageBlobLogs | where StatusCode == 503`.
3. Concurrent exports on the same instance competing for capacity?
4. Is `initialImportMode` set? Initial mode is faster but the FHIR service is **read-only** during
   the job — correct for first load, wrong for incremental.

---

## Preventive checks

Run after every environment change:

```powershell
# 1. Every FHIR service has a system-assigned principal
az resource list -g <rg> --resource-type Microsoft.HealthcareApis/workspaces/fhirservices `
  --query "[].{name:name, principalId:identity.principalId}" -o table

# 2. Every principal holds Storage Blob Data Contributor
az role assignment list --scope $(az storage account show -g <rg> -n <storage> --query id -o tsv) `
  --query "[?roleDefinitionName=='Storage Blob Data Contributor'].principalId" -o tsv

# 3. Shared-key access is off - keeps the workaround unavailable
az storage account show -g <rg> -n <storage> --query allowSharedKeyAccess

# 4. Smoke test: import a one-row NDJSON
./scripts/run-import.ps1 -PayerKey payera -Force
```

Ninety seconds, and it catches this entire failure class before a payer does.
