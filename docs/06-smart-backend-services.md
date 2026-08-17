# SMART Backend Services — what it gives you and what it does not

Relevant to the integration lead's Q6 and to the architecture lead's de-scope decision on 8/12. The de-scope was correct for the
POC; this document exists so the decision is revisited with the right information rather than the
right conclusion for the wrong reason.

---

## What AHDS supports today

| | |
|---|---|
| SMART on FHIR v1.0.0 | Yes, native |
| SMART on FHIR v2.0.0 | Yes, native |
| `/.well-known/smart-configuration` | Served by the FHIR service |
| SMART on FHIR **proxy** | **Retires September 2026** |
| External identity providers per FHIR service | **Maximum 2** |

Two operational consequences:

1. Anything built on the proxy needs a migration plan to the native implementation. Put the date in
   the programme plan now; it is not far away.
2. The two-IdP ceiling is a non-issue at one instance per payer. Under a shared-instance design it
   would be a hard blocker at the third payer that wants to federate. Another way in which Option 1
   turns out to be the load-bearing decision.

---

## The right profile for CMS-0057-F

**SMART Backend Services** — machine-to-machine, no user present:

- `client_credentials` grant
- **Signed client assertion**, not a shared secret
- Scopes of the form `system/Patient.rs`, `system/Coverage.rs`
- Paired with `Group/{id}/$export` for bulk

This is the profile payer vendors already implement. Adopting it removes bespoke onboarding work,
which is its real value: a payer's existing FHIR client works against Providence without custom
integration.

---

## The limitation that decides the architecture

SMART scopes are **resource-type-grained**. Microsoft HLS on 8/12:

> *"you can read observations … but you can't see conditions"*

There is no scope syntax that expresses:

> *only the members attributed to contract CT-3456*

That is a **row-level** rule. SMART has no vocabulary for it. Which is why:

> *"typically, it still falls short, even with 2.0 … You're still going to have to add APIM in
> there."*

### The two layers, stated precisely

Integration Engineering asked whether SMART Backend Services means access is right per resource. The answer is yes,
with an important qualification about what "per resource" means:

| Layer | Decides | Mechanism |
|---|---|---|
| **SMART scopes** | *which resource types* the payer may read | `system/Patient.rs` in the token |
| **APIM + Group + `_tag`** | *which rows of those types* | entitlement lookup, forced `_tag`, Group membership |

Both are required. Neither is sufficient.

Scopes alone let a payer read every `Patient` in the instance. Row filtering alone permits access to
resource types the contract never covered. Adopting SMART **never** removes the APIM requirement —
it makes the token exchange standards-compliant, which is a real benefit, but the authorisation
model is unchanged.

---

## Token flow

```
payer client
   │  ① client_credentials + signed client assertion
   ▼
Microsoft Entra ID
   │  ② access token, aud = the FHIR service URL
   ▼
APIM  /{payer}/outbound
   │  ③ validate-jwt          — signature, issuer, audience
   │     entitlement lookup   — appId → { payer, contracts[], groups[] }
   │     route allow-list     — GET only, Group-scoped $export only
   │     _tag injection       — forced to the caller's contracts
   │     token swap           — payer token discarded, APIM MI token attached
   ▼
AHDS FHIR
   │  ④ NDJSON
   ▼
Storage  export/
```

Step ③ is the trusted-broker pattern: the payer's token is **validated and then discarded**. The
call to AHDS is made with APIM's own managed identity. The payer's credential never reaches the
FHIR service, and consequently the FHIR service never has to make a payer-specific authorisation
decision.

---

## Why the payer cannot go around the gateway

Because **no payer application holds any Azure RBAC role on any FHIR service.**

A payer token sent directly to `https://…fhir.azurehealthcareapis.com` is:

- correctly signed ✓
- correctly audienced ✓
- **not authorised** ✗ → `403`

Note that this returns `403`, not `401`. The distinction matters when reading logs: `401` means the
credential is wrong; `403` means the credential is right and the principal has no role. Only APIM's
managed identity holds FHIR Data Contributor.

Verified by case 12 in [tests/isolation-proofs.http](../tests/isolation-proofs.http). **Keep that
test in CI.** The failure mode it guards against is someone granting a payer a reader role to
assist with debugging, which silently downgrades every APIM policy from a control to a suggestion.

---

## What adopting SMART would change

| | Today (POC) | With SMART Backend Services |
|---|---|---|
| Credential | client secret in Key Vault | signed JWT assertion, private key held by the payer |
| Discovery | manual handoff sheet | `/.well-known/smart-configuration` |
| Scopes | none | `system/Patient.rs system/Coverage.rs system/ExplanationOfBenefit.rs` |
| Row filtering | APIM | **APIM — unchanged** |
| Payer onboarding effort | bespoke | standard, works with existing payer tooling |

The migration is additive and does not disturb the isolation model. It is a good next increment
after the POC — and it is genuinely worth doing, because the reduction in per-payer onboarding
friction compounds across 30–40 payers.

---

## Recommendation

1. Keep it out of the POC. The de-scope on 8/12 was right — it would have added a week and proved
   nothing about isolation, which is the actual open question.
2. Plan the proxy retirement (September 2026) regardless.
3. Adopt SMART Backend Services for the payer-facing path once the isolation model is signed off.
   The payoff is onboarding friction, not security.
4. Never present SMART as a substitute for the gateway. It is not, and treating it as one would
   dismantle the row-level control without anyone noticing.
