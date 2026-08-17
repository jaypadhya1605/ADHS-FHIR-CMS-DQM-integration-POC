# Architecture decisions — every open item from the working session

Ordered as they came up on the call. Each item states what was asked, what the answer is, and where
in this folder the answer is demonstrated rather than asserted.

---

## 1. "Can you share a reference architecture diagram?"

Asked at roughly 12 minutes and again near the close. Not delivered until now.

[diagrams/providence-ahds-reference-architecture.drawio](../diagrams/providence-ahds-reference-architecture.drawio) — draw.io, four pages, editable.
Page 2 reproduces the four-quadrant canvas that was on screen, with the pros/cons annotations
transcribed from the recording and the decision recorded verbatim, so the artifact is recognisably
*yours* rather than a generic Microsoft reference.

A Mermaid rendering is at [diagrams/architecture.mmd](../diagrams/architecture.mmd) for pasting into
markdown-based docs.

---

## 2. Physical separation at the payer, logical at the contract

> *"separate instances for payer, will change the default from 10 to 40 … And then within a payer, if
> we want to separate by different contracts, that's going to be a logical separation instead of a
> physical one."* (40:48) — Steve: *"Yes."*

**Deployed exactly as decided.** Two payers, three contracts:

| Payer | FHIR service | Contracts (logical) |
|---|---|---|
| Contoso Health Plan | `fhir-payera` | `CT-3456`, `CT-7788` |
| Fabrikam Medicare Advantage | `fhir-payerb` | `CT-9001` |

Contract separation is `meta.tag` with system `https://providence.org/fhir/contract`, stamped on
write by the inbound APIM policy and enforced on read by a forced `_tag` query parameter on the
outbound policy. See [infra/modules/ahds.bicep](../infra/modules/ahds.bicep) and
[apim/policies/payer-outbound.xml](../apim/policies/payer-outbound.xml).

### Why this split is the right one, stated plainly

Physical separation limits the blast radius of a **mistake**. Logical separation limits the result
set of a **query**. They are not interchangeable.

A defect in an APIM policy could expose `CT-3456` data to a caller entitled only to `CT-7788` —
both inside Contoso, both already Contoso's own data, a contained incident. The same defect cannot
expose Contoso data to Fabrikam, because Fabrikam's credential has no authorisation path to
`fhir-payera` at all. Put the hard boundary where a failure is unrecoverable — the payer, which is
where the PHI-sharing agreement sits — and accept a soft boundary where a failure is embarrassing
but contained.

That reasoning is what makes ~40 instances defensible instead of 200.

---

## 3. "We have PHI over there … the physical separation has to be at the payer level"

Honoured. There is no shared FHIR service in this design; Options 2 and 4 from the canvas both
co-mingle payer PHI in a single instance and were rejected for that reason. Recorded on page 2 of
the diagram with the reason attached, so the decision survives staff turnover.

---

## 4. "Geography doesn't matter as much as what the payer is"

Agreed, with one caveat worth stating.

Geography is not the isolation axis — the payer is. But region still governs **data residency** and
**latency**, and a FHIR service cannot be moved between regions after creation. If any payer
contract carries a state-level residency obligation, that payer's instance must be provisioned in
the right region on day one. The template takes `location` per deployment so a per-payer regional
split is a parameter change, not a redesign.

---

## 5. Inbound and outbound isolation inside one instance (the platform lead's question)

> *"for inbound and outbound data, can it be isolated from each other [with]in one service? … we
> don't want payer to query our inbound data."*

**Yes — at the gateway, not in the data store.** Each payer gets two APIM APIs over the same FHIR
service:

| | `/{payer}/inbound` | `/{payer}/outbound` |
|---|---|---|
| Callers | Providence ingest pipeline | The payer |
| Verbs | `GET` `POST` `PUT` `DELETE` | `GET` only |
| `$export` | **denied** | `Group/{id}/$export` only |
| Writes | required to carry `X-Providence-Contract`; `meta.tag` stamped server-side | **denied** |
| Credential allow-list | `ingest-principals` | `payer-entitlements` |

A payer credential is not in `ingest-principals`, so even if a payer discovered the inbound URL the
policy rejects it at the entitlement check before routing. Proven in
[tests/isolation-proofs.http](../tests/isolation-proofs.http), cases 6 and 7.

### The part worth being precise about

This is **not** isolation inside the FHIR service. The rows are in the same database. What is
isolated is the *reachable surface*. If someone with FHIR Data Contributor on the service queries it
directly with an Azure CLI token, they see everything — that is by design, it is Providence's own
data plane.

The control that makes this safe is that **no payer holds any Azure RBAC role on any FHIR service**.
Only APIM's managed identity does. A payer token presented straight to
`https://…fhir.azurehealthcareapis.com` is authenticated and then refused, because authentication
and authorisation are separate gates and the payer passes only the first. That is why the gateway
cannot be bypassed, and it is a stronger statement than "we filter at APIM".

---

## 6. "What is the process for us to set that thing up for them?"

Seven steps, scripted end to end:

```powershell
./scripts/onboard-payer.ps1 -PayerKey payera `
    -DisplayName 'Contoso Health Plan' `
    -Contracts CT-3456,CT-7788
```

Produces the Entra app, the credential (straight into Key Vault, never printed, never on disk), the
entitlement record, and a handoff sheet containing no credential material.
Runbook: [runbooks/payer-onboarding.md](../runbooks/payer-onboarding.md).
Visual: page 3 of the diagram.

Offboarding is the inverse and takes one command — delete the Entra app. Every downstream check
fails closed.

---

## 7. The SMART on FHIR de-scope

> *"we don't have to worry too much about it because that's not part of my POC"* (48:46)

Right call for the POC, and the reason is worth keeping on record because it will come back.

SMART scopes are **resource-type-grained**. `system/Observation.rs` says "you may read
Observations". There is no scope syntax that says "only the members of contract CT-3456". Steve's
formulation on the call was exact:

> *"typically, it still falls short, even with 2.0 … You're still going to have to add APIM in there."*

So SMART Backend Services gives you a standards-compliant token exchange that payer vendors already
implement — worth having, because it removes bespoke onboarding work — while the row-level rule
stays at the gateway regardless. Adopting SMART never removes the APIM requirement.

One date to put in the plan: **the AHDS SMART on FHIR proxy retires in September 2026.** Anything
built on the proxy needs to move to the native SMART implementation.
Detail: [docs/06-smart-backend-services.md](06-smart-backend-services.md).

---

## 8. The quota raise from 10 to 40

Correct as stated on the call, with two operational notes:

- It is a **support ticket**, not a portal setting, and it is evaluated against regional capacity.
  It can be declined or partially granted. **File it early** — this is a lead-time item.
- The default is 10 FHIR services *and* 10 workspaces per subscription. Forty services still fit
  inside one workspace, so only the service quota needs raising. Structured storage defaults to
  4 TB and goes to 100 TB by the same route; at 1.4 TB you are inside the default but the headroom
  disappears with a couple of years of history.

Ask for the target number plus growth in one ticket rather than raising it twice.

---

## Still open, and it is the item that should worry us most

**Concurrent export capacity.** From the call:

> *"usually happens at the same time … will pop the server itself"*

This never got an answer. It is the only item on this list where the honest response is "we do not
have a number." AHDS autoscales and the scaling is free, but nothing published states how many
simultaneous `Group/$export` jobs a service sustains before throttling, nor how quickly it scales
into a burst.

Two mitigations are already live in the gateway policy — one concurrent export per payer per
5 minutes, and Group-scoped exports only, so the working set is bounded by cohort rather than
population. Those reduce the risk; they do not measure it.

[loadtest/](../loadtest/) will produce the measurement. Framing for the product-group conversation
is in [docs/05-capacity-and-scale.md](05-capacity-and-scale.md).

Recommendation: run it before committing to a production go-live date, not after.
