# Providence CMS-0057-F on Azure Health Data Services — Working POC

**Prepared for** Enterprise Architecture, Integration Engineering, Platform Engineering, Program Management — Providence St. Joseph Health
**From** Microsoft Health & Life Sciences, Microsoft Health & Life Sciences
**Subscription** `2852c4f9-8fcc-47c1-8e96-c4142a9ae463` · **Resource group** `rg-ahds-fhir-poc` · **Region** East US 2

---

## What this is

A deployed, runnable environment that answers the four questions left open at the end of the
2026-08-12 working session, plus the seven questions Integration Engineering sent separately. Not slides — Bicep you
can read, APIM policies you can attach to a debug trace, and a test suite whose assertions are the
security guarantees themselves.

Everything is in this folder. Nothing depends on a Microsoft-hosted demo tenant.

---

## The four things that were open on 8/12

### 1. The reference architecture diagram

Asked for twice on the call and not delivered until now.

[diagrams/providence-ahds-reference-architecture.drawio](diagrams/providence-ahds-reference-architecture.drawio) — four pages, editable in the same
draw.io canvas that was on screen:

| Page | Contents |
|---|---|
| 1 | Option 1 as a complete reference architecture, every component named |
| 2 | All four options as drawn on 8/12, with the pros/cons annotations transcribed and the decision recorded verbatim |
| 3 | Payer onboarding, the seven steps, with the SMART caveat |
| 4 | The `$import` 403 — the failing path and the working path side by side |

### 2. The isolation model, built rather than described

> *"separate instances for payer, will change the default from 10 to 40 … And then within a payer, if
> we want to separate by different contracts, that's going to be a logical separation instead of a
> physical one."* — Enterprise Architecture, 40:48

That is exactly what is deployed. Two payers, three contracts, one FHIR service per payer,
contracts as `meta.tag`, APIM enforcing the boundary.

The distinction that matters: **physical separation is what stops a mistake; logical separation is
what stops a query.** A bug in an APIM policy can leak one contract to another inside a payer.
It cannot leak Contoso's data to Fabrikam, because Fabrikam's credential has no path to Contoso's
FHIR service at all. Put the boundary where the consequence of failure is highest — the payer —
and the architecture lead's PHI argument is satisfied without provisioning 200 instances.

### 3. the platform lead's `$import` 403

Root cause identified, fixed in code, and the fix is annotated in the template so it does not get
undone in a later refactor: [infra/modules/rbac.bicep](infra/modules/rbac.bicep).

`$import` reads the integration data store as the **FHIR service's own system-assigned identity**,
not as a user-assigned managed identity attached to the service. The dev environment had the
storage role on the UAMI (`324cb15a-…`) while the read was being attempted by
`devfhirahdsworkspace/fhirservices/dev-fhir-ahds-inbound` (`7d1e195d-…`), which held nothing.

Full write-up including how to tell a live 403 from a replayed one:
[docs/04-import-403-rootcause.md](docs/04-import-403-rootcause.md).

### 4. Inbound / outbound isolation inside one service

> *"for inbound and outbound data, can it be isolated from each other [with]in one service? … we
> don't want payer to query our inbound data."* — Platform Engineering

Two APIM APIs per payer with mirrored allow-lists. The outbound route rejects every write verb and
every non-Group-scoped `$export`. The inbound route rejects `$export` outright. Both are proven by
tests that assert on `403`, not by a paragraph.

---

## The one thing still unquantified — and it is the biggest risk

On the call, exports were described as arriving together:

> *"usually happens at the same time … will pop the server itself"*

Nobody answered it. With ~800,000 patients across 30–40 payers, if a meaningful fraction of payers
launch `Group/{id}/$export` in the same window, the question is not whether AHDS autoscales — it
does — but whether it autoscales fast enough to avoid a wave of 429s that each payer's client
retries into a worse wave.

Two mitigations are already in the deployed policy:

- **One concurrent `$export` per payer per 5 minutes**, enforced at the gateway. A payer that
  submits a second job gets `429` with `Retry-After`, not a queued job that competes for capacity.
- Exports are **Group-scoped only**, so the working set is bounded by cohort size rather than by
  the whole population.

What is still needed is a number. [loadtest/](loadtest/) drives concurrent Group exports and records
p95 `TotalLatency` and 429 rate so the conversation with the AHDS product group is about measured
behaviour rather than an estimate. Recommendation: run it before committing to a production date.

---

## Cost

| | |
|---|---|
| This POC, running 24×7 | ≈ **$316/month** |
| This POC, per demo day | ≈ **$10.40** |
| A two-hour smoke test | ≈ **$0.90** |
| Providence production estimate, 1.4 TB + 30M resources/month | ≈ **$800/month** for FHIR consumption |

There is **no per-instance hourly charge** on AHDS FHIR — billing is consumption-based. Forty
lightly-used payer instances do not cost forty times one busy instance. This is the single most
common objection to Option 1 and it does not hold.

There is also **no pause button**. Delete the resource group between demos.
Breakdown: [docs/08-cost-model.md](docs/08-cost-model.md).

---

## What to look at, in order

| # | Artifact | Why |
|---|---|---|
| 1 | [diagrams/providence-ahds-reference-architecture.drawio](diagrams/providence-ahds-reference-architecture.drawio) | The ask from 8/12 |
| 2 | [docs/02-architecture-decisions.md](docs/02-architecture-decisions.md) | Every open item from the call, closed |
| 3 | [docs/03-platform-questions.md](docs/03-platform-questions.md) | All seven questions, including Q7 which had no prior answer |
| 4 | [docs/04-import-403-rootcause.md](docs/04-import-403-rootcause.md) | The blocker in dev |
| 5 | [tests/isolation-proofs.http](tests/isolation-proofs.http) | The security model, executable |
| 6 | [runbooks/payer-onboarding.md](runbooks/payer-onboarding.md) | *"What is the process for us to set that thing up for them?"* |
| 7 | [docs/05-capacity-and-scale.md](docs/05-capacity-and-scale.md) | The unanswered question, framed for a product-group conversation |

---

## Recommended agenda for the follow-up session

**45 minutes.** Live environment throughout; no slides.

| Time | Item | Owner |
|---|---|---|
| 0–5 | Reference architecture, page 1 and page 2 | Microsoft HLS |
| 5–15 | Live: Payer A exports its cohort. Payer A requests Payer B's cohort → 403. Payer A attempts a write → 403. | Microsoft HLS |
| 15–25 | The 403 RCA and the one-line Bicep fix; how to distinguish live from replayed | Microsoft HLS + Platform Engineering |
| 25–35 | the integration lead's seven, with Q1 partitioning and Q2 concurrency on screen | Microsoft HLS |
| 35–45 | The capacity gap, and what a load test would need to cover before a production date | Microsoft HLS + Enterprise Architecture |

---

## Standing caveats

- POC posture: public endpoints, no private endpoints, no VNet. Production needs both. The gap is
  configuration, not architecture.
- Synthetic data only. No PHI has been placed in this subscription.
- APIM `BasicV2` — sufficient to prove policy behaviour; production sizing follows the load test.
- The quota raise from 10 to 40 FHIR services is a **support ticket**, subject to a regional
  capacity evaluation. File it early; it is a lead-time item, not a same-day change.
