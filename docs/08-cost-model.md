# Cost model

East US pricing, USD, as of the estimate date. Verify current rates before quoting externally.

> **Correction, 2026-08-17.** The `$0.40 / hour` FHIR runtime line below is **not** a current
> Azure Health Data Services meter — it reflects the legacy provisioned Azure API for FHIR model.
> The published AHDS rate card is consumption-only: structured storage, API requests, export,
> transformation, de-identification and events. Every total on this page that includes an hourly
> runtime figure is therefore **overstated**.
>
> Use [09-quota-and-cost-guidance.md](09-quota-and-cost-guidance.md) as the authoritative rate
> card. The *shape* of the analysis on this page — especially "forty instances will not cost forty
> times as much" and the levers at the bottom — still holds, and holds more strongly once the
> hourly floor is removed.

---

## Unit rates

| Component | Rate |
|---|---|
| AHDS FHIR runtime | ~~$0.40 / hour~~ — see correction above; no hourly meter exists |
| AHDS provisioned throughput | $0.008 / hour per 100 RU/s |
| AHDS API requests | $0.54 / 100,000 |
| AHDS structured storage | $0.39 / GB-month |
| Blob storage, Hot LRS | $0.0208 / GB-month |
| APIM Developer | ~$50 / month |
| APIM BasicV2 | ~$150 / month |
| APIM StandardV2 | ~$700 / month |
| Log Analytics ingestion | ~$2.30 / GB after 5 GB free |
| Key Vault | negligible |

---

## This POC

| Component | Monthly |
|---|---|
| 2 × FHIR service runtime | $292 |
| API requests (demo volume) | ~$2 |
| Structured storage (< 1 GB) | < $1 |
| Blob storage | < $1 |
| APIM BasicV2 | $150 |
| Log Analytics | ~$5 |
| **Total, 24×7** | **≈ $450** |

Two FHIR services at $0.40/hr is $584/month if left running all month — which is why the
recommendation below matters more than any other line in this document.

| Usage pattern | Cost |
|---|---|
| Deleted between demos, ~4 demo days/month | **≈ $60** |
| A two-hour smoke test | **≈ $0.90** |
| Left running for a month | ≈ $450 |

**There is no pause button on AHDS FHIR.** A provisioned service bills whether or not it receives
a request. Delete the resource group after demos and redeploy from
[infra/main.bicep](../infra/main.bicep) — the whole environment rebuilds in about 20 minutes, and
APIM is the only slow part.

```powershell
az group delete -n rg-ahds-fhir-poc --yes --no-wait
```

---

## Providence production estimate

Based on the stated volumes: ~1.4 TB, ~30M resources/month, 30–40 payers.

| Component | Monthly |
|---|---|
| FHIR runtime (consumption at stated volume) | ~$600 |
| API requests (~30M ingest + payer reads) | ~$200 |
| Structured storage (1.4 TB) | ~$550 |
| Blob staging (500 GB incremental, Hot) | ~$10 |
| APIM StandardV2 (production tier) | ~$700 |
| Log Analytics | ~$150 |
| **Total** | **≈ $2,200 / month** |

Order-of-magnitude. Real cost depends on the request pattern more than on data volume, and the
export burst profile is the dominant unknown — see
[05-capacity-and-scale.md](05-capacity-and-scale.md).

---

## The objection this document exists to answer

> *"Forty FHIR instances will cost forty times as much."*

**It will not.** AHDS FHIR has **no per-instance hourly floor** at production scale — billing is
consumption-based across requests, storage and optional provisioned throughput. Forty lightly-used
payer instances consume roughly the same total as one instance handling the same aggregate traffic.

What changes with instance count:

| Scales with instances | Scales with usage |
|---|---|
| Operational surface: diagnostics, alerts, RBAC, upgrade windows | Request charges |
| Quota consumption (10 → 40, by support ticket) | Storage charges |
| IaC complexity — mitigated by the `payers` array | Throughput charges |

The real cost of Option 1 is **operational**, not financial, and it is controlled by never
provisioning an instance by hand. That is why [infra/main.bicep](../infra/main.bicep) takes an array
rather than shipping one template per payer.

---

## Levers, in order of impact

1. **Delete non-production environments when idle.** Largest single saving. Dev and QA do not need
   to exist overnight.
2. **Right-size APIM.** BasicV2 proves the policy model. StandardV2 is a production decision driven
   by the load test, not a default.
3. **Lifecycle the blob staging tier.** NDJSON already imported can move to Cool after 30 days and
   Archive after 90. Import staging is write-once, read-once.
4. **Cap Log Analytics retention.** 30 days is set here. Compliance may require longer for audit
   logs specifically — apply per-table retention rather than raising the workspace default.
5. **Do not enable provisioned throughput speculatively.** Autoscale is free. Provisioned RU/s is
   a fixed charge for a guarantee you may not need; decide after measurement.
