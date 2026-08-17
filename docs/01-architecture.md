# Architecture

Option 1 from the 2026-08-12 canvas, built. Diagram:
[diagrams/providence-ahds-reference-architecture.drawio](../diagrams/providence-ahds-reference-architecture.drawio).

---

## The shape in one sentence

One FHIR service per payer (physical isolation), contracts inside a payer expressed as `meta.tag`
(logical isolation), and API Management as the only path in or out.

---

## Why the boundary is at the payer

Physical separation limits the blast radius of a **mistake**. Logical separation limits the result
set of a **query**. They are not substitutes.

A defect in an APIM policy could expose `CT-3456` data to a caller entitled only to `CT-7788` —
both Contoso's own data, a contained incident. The same defect cannot expose Contoso's data to
Fabrikam, because Fabrikam's credential has no authorisation path to `fhir-payera` at all.

So the hard boundary goes where failure is unrecoverable — the payer, which is where the
PHI-sharing agreement sits — and the soft boundary goes where failure is contained. That reasoning
is what makes ~40 instances defensible rather than ~200.

It also happens to be the best-performing option under burst load, because one payer's export
traffic is not another payer's problem.

---

## Components

### AHDS workspace and FHIR services

[infra/modules/ahds.bicep](../infra/modules/ahds.bicep)

One workspace, one FHIR service per payer, `fhir-R4`.

Three settings carry weight:

| Setting | Value | Why |
|---|---|---|
| `identity.type` | `SystemAssigned` | The identity `$import` actually uses to read blobs. Set explicitly — relying on an implicitly-created principal is how the dev environment reached a state nobody could explain. |
| `resourceVersionPolicy` | `versioned` | Gives resource history via `_history`, the closest available answer to the integration lead's Q3 transaction-log question. |
| `importConfiguration.enabled` | `true` | With `initialImportMode: false` — incremental. Initial mode is faster but makes the service read-only during the job. |

Workspace names are alphanumeric only, 3–24 characters — hence `ahdspocdecotsv3` rather than
something hyphenated and readable.

### Storage — the integration data store

[infra/modules/storage.bicep](../infra/modules/storage.bicep)

Three containers, and the split is the point:

| Container | Contents |
|---|---|
| `pdex` | Validated NDJSON ready for `$import`. Named to match Providence's real container. |
| `export` | `$export` output |
| `quarantine` | Rejected resources with their `OperationOutcome` |

`allowSharedKeyAccess: false` is deliberate. It forces managed-identity authentication and removes
the account-key workaround that would otherwise mask the exact permission problem Platform Engineering hit — right
up until production, where it would be discovered under time pressure.

### RBAC — the module that fixes the 403

[infra/modules/rbac.bicep](../infra/modules/rbac.bicep)

| Principal | Role | Scope |
|---|---|---|
| Each FHIR service's **system-assigned** identity | Storage Blob Data Contributor | storage account |
| APIM's system-assigned identity | FHIR Data Contributor | each FHIR service |
| APIM's system-assigned identity | Storage Blob Data Reader | storage account |
| Operator | FHIR Data Contributor + Storage Blob Data Contributor | both |
| **Payer applications** | **nothing** | — |

The last row is the whole security model. See [04-import-403-rootcause.md](04-import-403-rootcause.md)
for the first row and [07-apim-control-plane.md](07-apim-control-plane.md) for why the last one
matters.

### API Management

[infra/modules/apim.bicep](../infra/modules/apim.bicep) · policies in [apim/policies/](../apim/policies/)

Two APIs per payer over the same FHIR service:

| | `/{payer}/inbound` | `/{payer}/outbound` |
|---|---|---|
| Callers | Providence ingest pipeline | The payer |
| Verbs | `GET` `POST` `PUT` `DELETE` | `GET` only |
| `$export` | denied | `Group/{id}/$export` only |
| Writes | require `X-Providence-Contract`; `meta.tag` stamped server-side | denied |
| Allow-list | `ingest-principals` | `payer-entitlements` |

`subscriptionRequired: false` — authentication is the SMART Backend Services JWT, not an APIM
subscription key. Adding a second credential type would create a second thing to rotate and revoke
without adding a control.

BasicV2 for the POC: ~10 minutes to deploy versus ~40 for Developer, and it proves the same policy
behaviour. Production sizing follows the load test.

### Observability

[infra/modules/monitoring.bicep](../infra/modules/monitoring.bicep)

Everything into one Log Analytics workspace: AHDS audit logs, APIM gateway logs, `StorageBlobLogs`,
Application Insights. `StorageBlobLogs` in particular is what distinguishes a live 403 from a
replayed one, which is not obvious until you need it at 2am.

FHIR services accept only the `allLogs` category group — `audit` is rejected with `BadRequest`,
which is worth knowing before a deployment fails on it.

---

## Request flow, outbound

```
payer client
   │ ① client_credentials + secret (POC) / client assertion (production)
   ▼
Microsoft Entra ID
   │ ② access token, aud = the FHIR service URL
   ▼
APIM  /{payer}/outbound
   │ ③ validate-jwt · entitlement · route allow-list · Group check
   │    forced _tag · rate limit · Accept normalisation
   │    token swap to APIM's managed identity
   ▼
AHDS FHIR
   │ ④ NDJSON
   ▼
Storage  export/
```

Step ③ is a trusted broker: the payer's token is validated and then **discarded**. AHDS is called
with APIM's own managed identity, so the FHIR service never makes a payer-specific authorisation
decision and the payer's credential never reaches it.

---

## Request flow, inbound

```
payer source → APIM /{payer}/inbound → $validate → clean?
                                          ├── yes → pdex/  → $import → AHDS FHIR
                                          └── no  → quarantine/ + OperationOutcome
```

`$import` reads `pdex/` as the **FHIR service's own system-assigned identity**.

Two things `$import` does not do, both of which have bitten people:

- **It does not run APIM policies.** `meta.tag` must already be in the NDJSON.
- **It preserves resource ids verbatim.** Two payers sending `Patient/12345` overwrite each other
  silently. Namespace ids by payer and contract before import.

---

## What this POC does not include

| Gap | Status |
|---|---|
| Private endpoints and VNet integration | Production requirement. Configuration, not architecture. |
| SMART Backend Services client assertions | Deliberately de-scoped on 8/12. See [06](06-smart-backend-services.md). |
| Entitlement store backed by the contract master | Named value is right for a POC; production should cache a lookup. Policy shape is unchanged. |
| Multiple IG version validation | Not supported server-side; validate in the pipeline. See [Q4](03-platform-questions.md). |
| Measured export capacity | The one genuinely open item. See [05](05-capacity-and-scale.md). |
