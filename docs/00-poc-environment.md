# The POC environment

What was actually deployed for the demo, and the two tenant governance constraints that shaped how
the scripts work.

---

## Deployed resources

Subscription `2852c4f9-8fcc-47c1-8e96-c4142a9ae463` · resource group `rg-ahds-fhir-poc` · East US 2

| Resource | Name |
|---|---|
| AHDS workspace | `ahdspocdecotsv3` |
| FHIR service — Contoso Health Plan | `fhir-payera` (contracts `CT-3456`, `CT-7788`) |
| FHIR service — Fabrikam Medicare Advantage | `fhir-payerb` (contract `CT-9001`) |
| API Management | `apim-poc-ahds-decotsv3` |
| Storage (integration data store) | `stpocahdsdecotsv3` — containers `pdex`, `export`, `quarantine` |
| Key Vault | `kv-poc-ahds-decotsv3` |
| Log Analytics | `log-ahds-decotsv3` |

Gateway: `https://apim-poc-ahds-decotsv3.azure-api.net`

This is a Microsoft demonstration subscription. It is deleted between sessions and redeployed from
[`../infra/main.bicep`](../infra/main.bicep) — treat the names above as illustrative, not as a
running endpoint.

---

## Two constraints in this demo subscription

Both are tenant governance controls on the Microsoft non-production tenant. Neither reflects the
architecture, and neither will apply in Providence's own subscription — but they shaped how the
scripts work, so they are documented rather than hidden.

### 1. Storage and Key Vault public network access is force-disabled

An ARM `PATCH` setting `publicNetworkAccess: Enabled` is silently reverted by a Modify-effect
policy. Consequences:

- NDJSON cannot be uploaded to the `pdex` container from outside Azure, so `$import` could not be
  exercised here. [`../scripts/load-fhir-direct.ps1`](../scripts/load-fhir-direct.ps1) loads the
  same data over the FHIR REST API instead, with the same `PUT` semantics — ids preserved verbatim.
- The RBAC fix that resolves the `$import` 403 **is deployed and verifiable**:

  ```powershell
  az role assignment list --scope $(az storage account show -g rg-ahds-fhir-poc -n stpocahdsdecotsv3 --query id -o tsv) `
    --query "[].{role:roleDefinitionName, principal:principalId}" -o table
  ```

  Both FHIR services' system-assigned principals hold Storage Blob Data Contributor.
  [`../scripts/run-import.ps1`](../scripts/run-import.ps1) remains the production path.

### 2. Application secrets are capped at 30 days

`policies/defaultAppManagementPolicy` sets `passwordLifetime: P30D`, and the vault cannot be written
to. So [`../scripts/run-isolation-tests.ps1`](../scripts/run-isolation-tests.ps1) mints an ephemeral
credential, proves the model, and revokes it inside one process. Nothing is ever written to disk or
displayed — which is better hygiene than the Key Vault path it replaces.

---

## Cost of leaving it running

≈ $450/month if left running; ≈ $10/demo day if deleted between sessions.
**AHDS FHIR has no pause button.**

```powershell
az group delete -n rg-ahds-fhir-poc --yes --no-wait
```

Breakdown: [08-cost-model.md](08-cost-model.md).
Authoritative rate card: [09-quota-and-cost-guidance.md](09-quota-and-cost-guidance.md).

---

## Scope

Synthetic data only; no PHI has been placed in this subscription. POC network posture is public
endpoints with no private endpoints or VNet — production needs both, and that gap is configuration
rather than architecture.
