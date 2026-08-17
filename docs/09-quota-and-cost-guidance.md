# Quota, capacity and cost for a 40-instance footprint

Answers to the questions raised by Providence Population Health on **2026-08-17**, subject
*"Requirements to request an AHDS FHIR service instance increase"*:

1. How do we request more FHIR service instances, and what details are needed?
2. How long does the request take?
3. How is cost calculated — does it scale with instance count?

Every figure below is from published Microsoft documentation, linked at the bottom. Nothing here is
an estimate.

---

## 1. You may not need a quota request at all

This is the part most often missed:

| Quota | Default | Maximum | **Scope** |
|---|---|---|---|
| Workspaces | 10 | contact support | **per subscription** |
| FHIR services | 10 | contact support | **per workspace** |
| DICOM services | 10 | contact support | per workspace |
| MedTech services | 10 | contact support | per workspace |

The FHIR limit is **per workspace**, not per subscription.

> **4 workspaces × 10 FHIR services = 40 services, in one subscription, with no quota request.**

Only a design that puts all 40 services in a *single* workspace requires a ticket. Splitting across
workspaces is also better practice — a workspace is a natural blast-radius and lifecycle boundary
(dev / QA / prod, or region, or payer cohort).

There is a second limit worth planning for now rather than discovering later:

| Limit | Default | Maximum |
|---|---|---|
| Storage per FHIR service | **4 TB** | **100 TB** (same ticket type) |

At ~1.4 TB for the full population, a single consolidated service would approach the 4 TB default.
Per-payer separation keeps every instance far below it.

---

## 2. Raising the request

Azure portal → **Help + Support** → **Create a support request**

| Field | Value |
|---|---|
| Issue type | **Service and subscription limits (quotas)** |
| Quota type | **Azure Health Data Services** |

Include:

- Subscription ID
- Region
- Workspace name(s) the increase applies to
- Current limit and requested limit
- Business justification — for Providence: CMS-0057-F Patient Access / Payer-to-Payer API, one FHIR
  service per payer for PHI isolation, 30–40 payers
- Expected data volume per service, if you are also raising the 4 TB storage limit

Notes:

- **One request per subscription.** Dev, QA and Production each need their own.
- **Free and trial subscriptions are not eligible** for quota increases.
- **Quota support requests are free of charge** — no support plan required.

---

## 3. Processing time

**Microsoft does not publish an SLA for quota increases**, so treat any specific number as a guess.

What is reliable:

- Straightforward increases within existing regional capacity are typically handled in a few
  business days.
- Requests that require regional capacity validation take longer.
- Submit **before** the capacity is needed, not when it becomes blocking.

---

## 4. Cost

### Published rate card

| Meter | Free allotment | Rate above the allotment |
|---|---|---|
| Structured storage (FHIR) | 1 GB / month | **$0.39 per GB / month** |
| BLOB storage (DICOM) | 1 GB / month | $0.023 per GB / month |
| API requests | 50,000 / month | **$0.54 per 100,000 requests** |
| Export batch | first 1 GB | $0.19 first GB, then $0.14 per GB |
| FHIR transformations | 0.5 GB | $1.14 per GB |
| Structured de-identification | 0.5 GB | $1.14 per GB |
| Events | 100,000 | $0.59 per 1,000,000 |

East US, USD. Verify current rates on the pricing page before quoting externally.

### Does cost scale with instance count?

**No — not for the FHIR service itself.**

Azure Health Data Services FHIR is **consumption-billed**. There is:

- no per-instance charge
- no hourly runtime fee
- no provisioned capacity you must buy up front

The bill is a function of **stored data + API requests**, not of how many services those are spread
across. The same 1.4 TB and the same 30 M requests/month cost approximately the same whether they
sit in 1 service or 40.

Two details that matter for the CMS-0057-F backfill:

- **Initial-mode `$import` does not incur a charge.** The bulk load of historical claims is not
  billed as API requests.
- **Requests that return `429` or `5xx` are not billed.** Throttled retries do not accumulate cost.

### What *does* scale with instance count

The FHIR service is free of per-instance cost. The footprint around it is not:

| Per-instance cost driver | Why |
|---|---|
| Private endpoints | one per service, per VNet |
| Storage accounts | if you isolate the integration data store per payer |
| Log Analytics ingestion | more diagnostic streams, more GB ingested |
| APIM capacity | more routes, more policy evaluation, higher tier |
| Operational surface | RBAC, alerts, upgrade windows, IaC complexity |

At 40 instances this is where the real delta appears — and it is **operational**, not FHIR
licensing. It is controlled by never provisioning an instance by hand, which is why
[`infra/main.bicep`](../infra/main.bicep) takes a `payers` array rather than shipping one template
per payer.

---

## 5. What this does not answer

Quota is not capacity. Having 40 instances provisioned says nothing about how many concurrent
`Group/$export` jobs a single service sustains before throttling, or how quickly autoscale absorbs
a synchronised burst. That is an open question with a measurement plan in
[05-capacity-and-scale.md](05-capacity-and-scale.md) and a harness in
[`loadtest/`](../loadtest/).

Worth raising with the AHDS product group alongside the quota request:

> At 40 FHIR services in one subscription, is there a **subscription-level or regional** aggregate
> limit that a per-instance view would miss?

---

## References

| Topic | Link |
|---|---|
| AHDS quotas and service limits | https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits#azure-health-data-services |
| Health Data Services pricing | https://azure.microsoft.com/pricing/details/health-data-services/ |
| Pricing calculator | https://azure.microsoft.com/pricing/calculator/?service=health-data-services |
| Requesting a quota increase in the portal | https://learn.microsoft.com/azure/quotas/quickstart-increase-quota-portal |
| FHIR service supported features | https://learn.microsoft.com/azure/healthcare-apis/fhir/fhir-features-supported |
