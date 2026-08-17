# Capacity and scale — the question that was not answered

This is the only item from 2026-08-12 where the honest position is *we do not have a number*. This
document says what is known, what is not, what has already been done to reduce the risk, and what
measurement would close it.

---

## The question

> *"usually happens at the same time … will pop the server itself"* — 2026-08-12

Payers do not stagger their pulls. CMS-0057-F deadlines, month-end reconciliation and quarterly
attribution refreshes all cluster. The concern is a **synchronised export burst**: many payers
launching `Group/{id}/$export` inside the same few minutes.

Providence scale:

| | |
|---|---|
| Patients | ~800,000 |
| Payers | 30–40 |
| Contracts | 150–200 |
| Full population | ~1.4 TB |
| Incremental | ~500 GB |
| Resources ingested | ~30M/month |
| Largest single file | up to 80 GB per contract |
| Roster/claims SLA | 7 days |

---

## What is actually known

| | |
|---|---|
| Autoscale | AHDS scales automatically. Free. Evaluated roughly every minute. |
| Published concurrency ceiling | **None.** |
| Customer-facing concurrency setting | **None.** |
| Throttling signal | HTTP 429 with `Retry-After` |
| Export job model | Asynchronous; `202` + `Content-Location`, poll to `200` |

The gap is not "does it scale" — it does. The gap is **how fast**, and **what happens in the window
between the burst arriving and capacity arriving**.

Autoscale reacting in about a minute is fine for a ramp and useless for a step change. Forty
simultaneous export submissions land inside seconds. Every one of them gets throttled while
capacity spins up, every client retries, and naive retry logic turns one spike into a sustained
overload. The failure is rarely the first burst; it is the retry storm the first burst causes.

---

## Mitigations already deployed

### 1. Export serialisation per payer

[apim/policies/payer-outbound.xml](../apim/policies/payer-outbound.xml):

```xml
<rate-limit-by-key calls="1" renewal-period="300"
                   counter-key="@("export-" + context.Variables.GetValueOrDefault<string>("payerKey"))"
                   increment-condition="@(context.Variables.GetValueOrDefault<string>("routeClass") == "export")" />
```

One export job per payer per five minutes. A second submission gets `429` with `Retry-After` **at
the gateway** — it never reaches AHDS and never consumes FHIR capacity. Thirty simultaneous
submissions become thirty jobs spread over time instead of thirty jobs competing.

This converts an uncontrolled burst into a queue. It is the single highest-value line in the policy.

### 2. Group-scoped exports only

System-level and patient-level `$export` return `403`. The working set is bounded by cohort size
rather than by the 800,000-patient population. A payer with 5,000 attributed members exports 5,000
patients' worth of data, not a slice of everything.

### 3. Physical separation as a bulkhead

One FHIR service per payer means one payer's export load is not another payer's problem. This is a
side benefit of the isolation decision that was made for PHI reasons, and it is worth naming
explicitly: **Option 1 is also the best-performing option under burst**, because it removes the
shared-fate coupling that Options 2 and 4 introduce.

### 4. Backoff guidance in the onboarding pack

Every payer handoff sheet states the rate limits and requires `Retry-After` to be honoured.
Payer-side retry behaviour is the difference between a queue and an outage, and it is the part
Providence does not control — so it belongs in the onboarding contract, not in a wiki.

---

## What is still missing

**A number.** Specifically:

1. How many concurrent `Group/$export` jobs does a single FHIR service sustain before 429s begin?
2. How long does autoscale take to absorb a step change of *N* simultaneous jobs?
3. Does export throughput degrade linearly or fall off a cliff?
4. What is the practical ceiling on export **size** — does a 50,000-member cohort behave like ten
   5,000-member cohorts?
5. Does `$import` of an 80 GB file contend with concurrent exports on the same instance?

Question 5 matters most operationally: Providence's 7-day ingest SLA and the payers' export windows
will overlap.

---

## The measurement

[loadtest/](../loadtest/) drives concurrent Group exports at increasing parallelism and records:

- p95 and p99 `TotalLatency`
- 429 count as a percentage of requests
- Time from submit to `200` per job
- Autoscale reaction time inferred from the latency curve

Recommended sequence:

| Phase | Concurrent exports | Purpose |
|---|---|---|
| 1 | 1 | Baseline single-job duration |
| 2 | 5 | First sign of contention |
| 3 | 15 | Half of Providence's payer count |
| 4 | 40 | Full payer count, the realistic worst case |
| 5 | 40 + concurrent `$import` | The overlap scenario |

Run against the POC first for shape, then against a production-sized dataset before committing to a
go-live date. Shape from a small dataset is directionally useful; absolute numbers are not.

---

## How to frame this with the product group

Ask for **guidance**, not a guarantee. The useful questions:

1. Is there an internal concurrency ceiling per FHIR service, even if unpublished?
2. What is the expected autoscale reaction time for a step change in load?
3. Is there a supported pattern for pre-warming ahead of a known burst window?
4. Do `$export` and `$import` contend for the same capacity pool?
5. At 40 instances in one subscription, is there a **subscription-level** aggregate limit that a
   per-instance view would miss?

Question 5 is the one most likely to be overlooked and most likely to hurt. Per-instance headroom
means nothing if the constraint is regional or subscription-scoped.

---

## Recommendation

**Run the load test before committing to a production date.**

The architecture is right and the isolation model is proven. Capacity is the one variable that
cannot be reasoned about from first principles, and it is precisely the variable that determines
whether a CMS-0057-F deadline is met. Measuring it costs a day. Discovering it in production costs
considerably more.
