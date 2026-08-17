# Platform questions — all seven, answered

Questions as sent. Q1–Q6 were answered previously in `v3/Solutions/`; those answers are carried
forward here, corrected where the POC changed the picture. **Q7 had no prior answer** — it is
answered in full below.

---

## Q1 — Partitioning by risk contract

> *"If we partition based on contract, how many FHIR service instances and workspaces can we
> provision, and what are the maintenance and cost implications? Our expected scale is ~200 inbound
> plus ~200 outbound contracts per environment, and we have three environments total (Dev/QA/Prod).
> Can all contracts in an environment be supported within a single workspace?"*

**Do not partition by contract. Partition by payer.** ~30–40 instances per environment, not 400.

| | Per contract | Per payer *(recommended)* |
|---|---|---|
| Instances per environment | ~400 | ~30–40 |
| Quota tickets | 400 → far beyond any reasonable grant | one, 10 → 40 |
| Onboarding a new contract | provision an instance | insert a row in an entitlement map |
| Blast radius of a policy defect | one contract | one payer |
| Cost | same | same — billing is consumption-based |

### Can one workspace hold them all?

Yes. The default is 10 workspaces and 10 FHIR services per subscription; both raise by support
ticket. Forty services fit comfortably inside a single workspace, so only the **service** quota
needs raising. Use the workspace as the environment boundary — one per Dev/QA/Prod, in separate
subscriptions — rather than as a payer boundary.

### Cost implication, stated directly

There is **no per-instance hourly charge**. AHDS FHIR bills on consumption: request volume,
structured storage, and provisioned throughput if you opt into it. Forty lightly-used payer
instances do not cost forty times one busy instance. At Providence's stated volume — 1.4 TB and
~30M resources/month — expect roughly **$800/month** for the FHIR tier regardless of how that
traffic is distributed across instances.

This matters because "40 instances sounds expensive" is the most common objection to this design,
and it is not correct.

### The maintenance implication that is real

Forty instances means forty of everything operational: diagnostic settings, alert rules, RBAC
assignments, upgrade windows to observe. Handle it by **never provisioning one by hand**.
[infra/main.bicep](../infra/main.bicep) takes a `payers` array; adding a payer is one array entry and
a redeploy. Configuration drift across forty instances is the failure mode to design against, and
IaC is the only durable answer.

### The constraint that will bite if it is missed

`$import` preserves the `id` in the NDJSON **verbatim**. Two payers that both send `Patient/12345`
will silently overwrite each other — no error, no warning, last write wins. **Namespace every
resource id by payer and contract before import.** The sample generator does this
(`payera-ct3456-pat-00001`); see [scripts/generate-samples.ps1](../scripts/generate-samples.ps1).

This is a data-loss bug that produces no signal. Put it in the ingest pipeline's contract tests.

---

## Q2 — Concurrency

> *"What is the maximum number of threads/requests that can run against a FHIR service at the same
> time? How can we increase it if we need more?"*

**There is no published limit and no customer-facing dial.** AHDS autoscales; scaling is free and
evaluated about once a minute. There is no setting to raise concurrency, and no documented ceiling
to plan against.

That is an unsatisfying answer, so here is how to work with it.

### Empirical starting points

| Workload | Start at | Signal to back off |
|---|---|---|
| `$validate` | 5–10 concurrent | 429 rate > 1% |
| Transaction bundles | 50–100 entries, < 28 MB | 409 conflicts rising |
| Bulk load | **use `$import`, not bundles** | — |
| `Group/$export` | 1 per payer at a time | queue depth, p95 latency |

`$import` is not "faster bundles" — it is a different ingestion path designed for volume. For
Providence's 80 GB per-contract files, transaction bundles are not a viable option at any
concurrency.

### Reading the status codes correctly

| Code | Meaning | Action |
|---|---|---|
| **429** | Server throttling | Honour `Retry-After`. Exponential backoff. **Do not retry immediately** — this is what turns a burst into an outage. |
| **409** | Optimistic-concurrency conflict | Safe to retry; re-read and reapply |
| **408** | The **client** gave up | Raise the client timeout; the server may still be working |

The 408 case is worth calling out because it is routinely misread as a server fault. It means your
HTTP client stopped waiting.

### What to monitor

- `TotalLatency` p95 per operation type
- 429 count as a percentage of total requests — **alert above 1%**
- Import and export job duration trend

### The honest gap

Providence's concurrency risk is not steady-state throughput; it is the **synchronised export
burst** described on the 8/12 call. Autoscale reacts in roughly a minute. If forty payers start
exports inside the same thirty seconds, the reaction arrives after the burst. The gateway policy
already serialises exports per payer, which converts a spike into a queue. What is still missing is
a measurement. See [docs/05-capacity-and-scale.md](05-capacity-and-scale.md).

---

## Q3 — Monitoring and transaction-level logging

> *"What server-side operational and transaction-level logging is available, down to the data level
> (transactional logs from the server side)?"*

Available today, all flowing into the Log Analytics workspace this POC deploys:

| Source | Table | Grain |
|---|---|---|
| AHDS FHIR audit | `MicrosoftHealthcareApisAuditLogs` | one row per API call: caller identity, operation, resource type, status, latency, correlation id |
| AHDS metrics | `AzureMetrics` | `TotalRequests`, `TotalErrors`, `TotalLatency`, availability |
| APIM gateway | `ApiManagementGatewayLogs` | one row per gateway request: caller app id, backend latency, policy outcome |
| Storage | `StorageBlobLogs` | one row per blob operation — this is where a 403 on `GetBlobProperties` appears |
| App Insights | requests / dependencies | end-to-end correlation via W3C trace context |

### What you do **not** get

There is no row-level change log — nothing equivalent to a database transaction log that lets you
replay "field X on Patient/123 changed from A to B". FHIR versioning
(`resourceVersionPolicy: versioned`, enabled in this deployment) gives you the resource history via
`GET /Patient/123/_history`, which is the closest available equivalent and is usually what is
actually wanted.

If a true change-data-capture feed is a requirement, that is an architectural item — typically an
event-driven fan-out on write — not a configuration setting. Worth confirming which of the two you
need before designing for it.

### Starter queries

```kusto
// Import and export job outcomes, last 24 hours
MicrosoftHealthcareApisAuditLogs
| where TimeGenerated > ago(24h)
| where OperationName has_any ("import", "export")
| project TimeGenerated, OperationName, ResultType, StatusCode, CorrelationId, CallerIdentity
| order by TimeGenerated desc

// Throttling rate - the number to alert on
MicrosoftHealthcareApisAuditLogs
| where TimeGenerated > ago(1h)
| summarize total = count(), throttled = countif(StatusCode == 429) by bin(TimeGenerated, 5m)
| extend pct = round(100.0 * throttled / total, 2)

// Storage 403s - the platform lead's failure mode, and the identity that was refused
StorageBlobLogs
| where TimeGenerated > ago(2h)
| where StatusCode == 403
| project TimeGenerated, OperationName, Uri, AuthenticationType, RequesterObjectId, StatusText
```

The third query is the one that distinguishes a live permission failure from a replayed job result.
If it returns nothing while `$import` is returning 403, the 403 is cached.

---

## Q4 — Multiple IG versions

> *"Follow-up on the PR you mentioned. Any updates on current status would be helpful."*

**Status unchanged: not supported in the managed service, and no committed date.**

A FHIR service holds **one** active set of profile `StructureDefinition` resources. It cannot
validate against US Core 3.1.1 and 6.1.0 simultaneously and select per request.

### Options available now

| Option | Trade-off |
|---|---|
| **Separate FHIR service per IG version** | Clean, no custom code. Consumes instance quota — count these into the 40. |
| **Validate outside the FHIR service** | HL7 Java validator or `firely-terminal` in the ingest pipeline, one profile set per payer. Full control over versions and error handling. More to operate. |
| **Version-tag and validate at the boundary** | `meta.profile` records the claimed version; the pipeline routes to the right validator. Most flexible, most build. |

For Providence, option 2 fits the existing shape: validation already happens in the pipeline before
`$import`, and payers migrate IG versions on their own schedules, which is precisely what a
per-payer validator config handles well.

**Recommendation:** do not architect around this being fixed. If it ships, it simplifies; if it does
not, nothing needs to change.

---

## Q5 — Configurable error suppression

> *"Could you provide an update on configurable server-side suppression of specific validation
> errors?"*

**Not available server-side, and this is unlikely to change** — a FHIR server that suppresses
validation errors by configuration is a server whose conformance claim is no longer meaningful.

### What works instead

Validate **before** `$import`, and make the suppression policy your own:

1. `POST {fhir}/{Type}/$validate` returns an `OperationOutcome` with `issue[].severity` and
   `issue[].details.coding.code`.
2. Apply a Providence-owned suppression list — for example "`information` and `warning` pass;
   `error` on `us-core-6` for payers still on 3.1.1 passes with a recorded exception".
3. Route clean resources to `pdex/`, rejects to `quarantine/` with the `OperationOutcome` alongside.
4. `$import` only the clean set.

This is the pattern already implemented in [infra/modules/storage.bicep](../infra/modules/storage.bicep)
(the three containers) and drawn on page 1 of the diagram.

### Why this is better than the feature you asked for

A server-side suppression list is invisible to auditors and applies uniformly. A pipeline-side list
is code — reviewed, versioned, diffable, and **per payer**, which is what you actually need when
one payer is on US Core 3.1.1 and another on 6.1.0. Ask for the exception report by payer and you
have a genuine data-quality metric rather than a silently-tolerated error class.

### Partial success on `$import`

Related and worth knowing: `$import` does not fail an entire job because of bad rows. The completion
payload carries `output[]` (imported) and `error[]` (rejected, with a URL to a per-file
`OperationOutcome` NDJSON). A non-empty `error[]` alongside a populated `output[]` means "most rows
landed", not "the import failed". **Rejected rows are not retried automatically** — resubmit only
the corrected files. Handled in [scripts/run-import.ps1](../scripts/run-import.ps1).

---

## Q6 — SMART on FHIR

> *"Does AHDS support SMART on FHIR?"*

**Yes — v1.0.0 and v2.0.0, natively.** `/.well-known/smart-configuration` is served by the FHIR
service. No proxy required.

Three things to plan around:

1. **The SMART on FHIR proxy retires in September 2026.** If anything is built on the proxy, plan
   the move to the native implementation now.
2. **Maximum two external identity providers per FHIR service.** With one instance per payer this
   is not a constraint. It would be a hard blocker under a shared-instance design — another reason
   Option 2 was the wrong shape.
3. **SMART scopes do not do row-level filtering.** They are resource-type-grained. There is no scope
   that expresses "only members of contract CT-3456". That rule lives at APIM, always.

For CMS-0057-F the relevant profile is **SMART Backend Services** — `client_credentials` with a
signed client assertion, no user present — combined with `Group/{id}/$export`.
Detail: [docs/06-smart-backend-services.md](06-smart-backend-services.md).

---

## Q7 — Custom search parameters

> *"Does AHDS support custom search, e.g., searching by group name / custom search parameters?"*

**Yes. This one had no prior answer, so here it is in full.**

AHDS supports user-defined search parameters through the standard FHIR `SearchParameter` resource
plus a reindex operation. Three steps.

### Step 1 — Define the parameter

```http
POST {{fhir}}/SearchParameter
Content-Type: application/fhir+json

{
  "resourceType": "SearchParameter",
  "url": "https://providence.org/fhir/SearchParameter/group-name",
  "name": "group-name",
  "status": "active",
  "description": "Search Group resources by name",
  "code": "group-name",
  "base": [ "Group" ],
  "type": "string",
  "expression": "Group.name"
}
```

`expression` is FHIRPath. `type` must be one of `number | date | string | token | reference |
composite | quantity | uri`.

### Step 2 — Reindex

New parameters are **not** usable until existing data is indexed against them.

```http
POST {{fhir}}/$reindex
Content-Type: application/fhir+json

{ "resourceType": "Parameters", "parameter": [] }
```

Returns `201` with a job location; poll it. On a small dataset this is quick. **On a populated
production instance a full reindex is a long, resource-intensive job** — plan it into a maintenance
window and expect elevated latency while it runs.

Throughput can be tuned with `maximumConcurrency`, `maximumResourcesPerQuery` and
`queryDelayIntervalInMilliseconds` in the `Parameters` body. Start conservative.

### Step 3 — Use it

```http
GET {{fhir}}/Group?group-name:contains=CT-3456
```

### Practical guidance for Providence

| | |
|---|---|
| **Reindex cost** | Full reindex touches every resource. At 1.4 TB this is hours, not minutes. Define custom parameters **before** bulk loading a new environment wherever possible. |
| **`_tag` needs nothing** | `meta.tag` is a **standard** search parameter. The contract-scoping this POC relies on requires no custom parameter and no reindex. That was deliberate. |
| **Group name vs. Group id** | If the use case is "find the cohort for contract CT-3456", prefer `GET /Group?identifier=https://providence.org/fhir/contract\|CT-3456`. `identifier` is standard and needs no reindex. A custom `group-name` parameter is only worth it for genuine free-text search over names. |
| **Deletion** | Deleting a `SearchParameter` requires another reindex to reclaim the index. Treat custom parameters as close to permanent. |
| **Sequencing** | Add all custom parameters, then reindex **once**. Do not add-and-reindex per parameter. |

### The recommendation

Before defining a custom parameter, check whether a standard one already does the job — `identifier`,
`_tag`, `_profile`, `_security` and `_source` cover most "how do we find things by our own business
key" needs, and they cost nothing. Reserve custom `SearchParameter` resources for cases with no
standard equivalent, and batch them.
