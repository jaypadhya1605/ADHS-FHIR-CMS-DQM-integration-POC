# Runbook — onboarding a payer

Answers the architecture lead's question from 2026-08-12 directly:

> *"All we need is that … we have a payer. We want to give that payer access to the AHDS server.
> What is the process for us to set that thing up for them?"*

Scripted: [scripts/onboard-payer.ps1](../scripts/onboard-payer.ps1). Visual: page 3 of
[the diagram](../diagrams/providence-ahds-reference-architecture.drawio).

**Time:** ~10 minutes for an existing payer instance. ~25 minutes if a new FHIR service is needed
(provisioning is the wait).

---

## Before you start

| | |
|---|---|
| Payer legal name and short key | key is lowercase alphanumeric, e.g. `payera` |
| Contract identifiers | e.g. `CT-3456`, `CT-7788` |
| Direction | read-only (the CMS-0057-F default) or read + ingest |
| Whether a FHIR service exists for this payer | if not, add to `payers` in [infra/main.bicepparam](../infra/main.bicepparam) and redeploy first |

Check the quota before adding the 11th payer. The default is 10 FHIR services per subscription and
the raise is a support ticket, not a portal setting.

---

## Step 1 — Register the Entra application

**One application per payer.** Not one per contract, not one shared across payers.

The application is the revocation unit. When a contract ends, or a payer has a security incident,
the response is "delete this app registration" — a single, complete, immediately effective action.
Sharing an app across payers makes that impossible without collateral damage.

```powershell
az ad app create --display-name "providence-cmsdqm-payera" --sign-in-audience AzureADMyOrg
az ad sp create --id <appId>
```

---

## Step 2 — Issue a credential

**Preferred: certificate / client assertion.** Microsoft HLS on 8/12: *"a secret, which I don't
recommend."*

A client secret is a bearer credential — anyone holding the string is the payer. A certificate
requires possession of a private key that never transits. SMART Backend Services assumes asymmetric
client authentication for exactly this reason.

If a secret is unavoidable during a POC:

```powershell
$secret = az ad app credential reset --id <appId> --years 1 --append --query password -o tsv
az keyvault secret set --vault-name <kv> --name "payer-payera-client-secret" --value $secret --output none
Clear-Variable secret
```

Never write the value to a file, a ticket, or a chat message. The onboarding script keeps it in
memory for two lines and clears it.

---

## Step 3 — Create the Group for each contract

`Group/{id}` is the member cohort and the **export unit**. `Group/{id}/$export` is the only export
verb a payer is permitted to call.

```json
{
  "resourceType": "Group",
  "id": "group-ct3456",
  "meta": { "tag": [ { "system": "https://providence.org/fhir/contract", "code": "CT-3456" } ] },
  "identifier": [ { "system": "https://providence.org/fhir/contract", "value": "CT-3456" } ],
  "active": true, "type": "person", "actual": true,
  "name": "Contoso Health Plan - CT-3456 member cohort",
  "member": [ { "entity": { "reference": "Patient/payera-ct3456-pat-00001" } } ]
}
```

Group membership is how attribution is expressed. Keeping it current is an operational
responsibility, not a one-time setup step — a stale Group exports the wrong cohort, silently.

---

## Step 4 — Ensure the data is tagged

Every resource for this contract carries:

```json
"meta": { "tag": [ { "system": "https://providence.org/fhir/contract", "code": "CT-3456" } ] }
```

Stamped automatically on the inbound route by
[apim/policies/payer-inbound.xml](../apim/policies/payer-inbound.xml). For bulk `$import`, the tag
must be present in the NDJSON — `$import` does not run policies. See
[scripts/generate-samples.ps1](../scripts/generate-samples.ps1).

**An untagged resource is invisible to every payer.** That is the safe failure mode, but it is still
a failure: the data is loaded and nobody can see it. Audit for untagged resources after every bulk
load:

```http
GET {fhir}/Patient?_tag:missing=true&_summary=count
```

---

## Step 5 — Add the entitlement record

```json
"<appId>": {
  "payer": "payera",
  "name": "Contoso Health Plan",
  "contracts": [ "CT-3456", "CT-7788" ],
  "groups": [ "group-ct3456", "group-ct7788" ]
}
```

Merged into the APIM named value `payer-entitlements` by the onboarding script.

### The step that is deliberately absent

**No Azure RBAC role is granted to the payer's application.** Not FHIR Data Reader, not anything.

This is not an oversight — it is the control that makes the gateway unbypassable. A payer token sent
directly to the FHIR service endpoint authenticates successfully (Entra issued it) and then fails
authorisation, because the app holds no role. Only APIM's managed identity carries FHIR Data
Contributor.

If someone later "fixes" this by granting the payer a reader role to help with debugging, the entire
isolation model collapses silently — every APIM policy becomes advisory. Proven by case 12 in
[tests/isolation-proofs.http](../tests/isolation-proofs.http); keep that test in CI.

---

## Step 6 — Hand over connection details

```
Token endpoint   https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
Grant type       client_credentials
Client ID        {appId}
Scope            {fhirUrl}/.default

FHIR base URL    {gateway}/payera/outbound
SMART config     {gateway}/payera/outbound/.well-known/smart-configuration
Bulk export      GET {base}/Group/{groupId}/$export?_type=Patient,Coverage,ExplanationOfBenefit
                 Prefer: respond-async

Constraints      read-only · Group-scoped export only · results filtered to your contracts
                 1 concurrent export per 5 min · 600 req/min · 50,000/day
                 honour Retry-After on 429
```

The payer never receives the AHDS endpoint. `Content-Location` on export responses is rewritten to
the gateway host so polling stays on the gateway.

Generated to `out/payer-{key}-handoff.txt`, credential-free by construction.

---

## Step 7 — Verify with the negative tests

Do not declare onboarding complete on a successful export alone. Run all four:

| Test | Expect |
|---|---|
| `GET {base}/Group/{their group}/$export` | **202** |
| `GET {base}/Group/{another payer's group}/$export` | **403** |
| `GET {base}/Patient` | **200**, filtered to their contracts |
| `POST {base}/Patient` | **403** |

Cases 2, 6, 1 and 7 in [tests/isolation-proofs.http](../tests/isolation-proofs.http).

A payer who can export is not proof of correct configuration. A payer who **cannot** reach what they
should not reach is.

---

## Offboarding

```powershell
az ad app delete --id <appId>
```

One command. Every downstream check fails closed: the token endpoint stops issuing, `validate-jwt`
rejects anything cached, and the entitlement lookup no longer resolves.

Then tidy up:

1. Remove the entitlement record from `payer-entitlements`.
2. Delete the Key Vault secret (soft-delete retains it for 7 days).
3. Decide on the data. Contract termination usually carries a retention obligation — do **not**
   delete the FHIR service reflexively. Suspend access first, resolve retention second.

---

## Common failures

| Symptom | Cause |
|---|---|
| `401` at the gateway | Wrong `scope`. Must be `{fhirUrl}/.default`, not the gateway URL. |
| `403` "not onboarded" | `payer-entitlements` not updated, or APIM cached the old named value. Named-value changes take up to ~60s to propagate. |
| `403` on the payer's own Group | Group id mismatch. The entitlement lists `group-ct3456`; the payer is calling `Group/CT-3456`. |
| Export returns an empty Bundle | Data loaded without `meta.tag`, or Group membership empty. Check `_tag:missing=true`. |
| `429` immediately | Expected. One export per payer per 5 minutes. Honour `Retry-After`. |
