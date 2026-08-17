# The APIM control plane — six layers, in order

Microsoft HLS, 2026-08-12:

> *"you're not going to get out of having an API management in front of it"*
> *"I wouldn't separate the data. I'd figure out how to control it."*

This document explains what each policy layer does and, more usefully, **why it is ordered where it
is**. Source: [apim/policies/payer-outbound.xml](../apim/policies/payer-outbound.xml) and
[apim/policies/payer-inbound.xml](../apim/policies/payer-inbound.xml).

---

## Layer order and why it matters

Each layer is cheap relative to the next. Reject as early as possible.

```
1. authenticate      →  is this token real?              (crypto, cached JWKS)
2. entitle           →  is this caller onboarded here?   (named-value lookup)
3. allow-list route  →  is this verb+path permitted?     (string match)
4. scope             →  narrow the request               (query rewrite)
5. rate limit        →  is this caller within budget?    (counter)
6. broker            →  swap to the managed identity     (token acquisition)
```

Layer 6 is deliberately last. It acquires a managed-identity token — a network call with a cache
miss cost. Doing it before the cheap rejections would burn a token acquisition on every request
that was going to be refused anyway.

Layer 5 sits after layer 3 for a subtler reason: rate-limiting a request that is about to be
rejected as unauthorised pollutes the caller's quota with requests that never had a chance. Count
only requests that were going to be served.

---

## 1. Authentication

```xml
<validate-jwt header-name="Authorization" failed-validation-httpcode="401"
              output-token-variable-name="jwt">
  <openid-config url="https://login.microsoftonline.com/{tenant}/v2.0/.well-known/openid-configuration" />
  <audiences><audience>{fhirUrl}</audience></audiences>
  <issuers>
    <issuer>https://sts.windows.net/{tenant}/</issuer>
    <issuer>https://login.microsoftonline.com/{tenant}/v2.0</issuer>
  </issuers>
</validate-jwt>
```

Both issuer forms are listed because Entra emits v1 (`sts.windows.net`) or v2
(`login.microsoftonline.com/…/v2.0`) depending on the app registration's `accessTokenAcceptedVersion`.
Listing one is a source of intermittent 401s that appear to depend on which payer is calling —
because they do.

`output-token-variable-name` keeps the parsed token for layer 2 so it is not decoded twice.

The **audience is the FHIR service URL, not the gateway.** This is load-bearing: a token minted for
Payer B's FHIR service fails validation on Payer A's route before any entitlement logic runs. Two
independent gates, and the cheaper one is first.

---

## 2. Entitlement

```xml
<set-variable name="callerAppId" value="@{
  var jwt = (Jwt)context.Variables["jwt"];
  return jwt.Claims.GetValueOrDefault("azp", jwt.Claims.GetValueOrDefault("appid",""));
}" />
```

`azp` is the v2 claim, `appid` the v1. Same reason as the issuer list.

The entitlement store is the APIM named value `payer-entitlements`:

```json
{ "<appId>": { "payer": "payera", "contracts": ["CT-3456","CT-7788"],
               "groups": ["group-ct3456","group-ct7788"] } }
```

Stored **single-quoted** and converted with `.Replace((char)39,(char)34)` before parsing. This is
not stylistic: the JSON lives inside a C# string literal inside XML, and double quotes require
escaping at both levels, which is where these policies typically break during editing.

Two checks:

- Is the caller present in the map at all? Absent ⇒ `403`.
- Does `entitlement.payer` match the route's payer? Mismatch ⇒ `403`.

The second is the **cross-payer guard**. It is what makes physical separation meaningful rather than
decorative: a valid Payer B credential presented on Payer A's route is refused by name, not merely
by audience.

### Production note

A named value is right for a POC — visible in the portal, auditable, no dependency. At 30–40 payers
this should become a cached lookup against the contract master, with APIM caching the result for a
few minutes. The policy shape does not change; only the source of the entitlement record does.

---

## 3. Route allow-list

Requests are classified, then anything unclassified is denied:

| Class | Outbound | Inbound |
|---|---|---|
| `export` | `Group/{id}/$export` only | **denied** |
| `poll` | `_operations/export/{id}` | **denied** |
| `metadata`, `smartconfig` | allowed | allowed |
| `search` | `GET` only | `GET` only |
| write | **denied** | allowed with contract header |

**Deny-by-default.** The final `otherwise` branch sets `denied`, so a FHIR operation nobody
anticipated is refused rather than proxied. New FHIR operations appear over time; an allow-list ages
safely and a deny-list does not.

System-level `$export` and patient-level `Patient/$export` are explicitly rejected even though they
are legitimate FHIR. They are unbounded — the working set is the whole instance. Group-scoped export
bounds it to a cohort, which is both a security property and the capacity mitigation described in
[05-capacity-and-scale.md](05-capacity-and-scale.md).

---

## 4. Scoping

### Group entitlement

```
Group/group-ct3456/$export
      └──────────────┘
        must appear in entitlement.groups[]
```

Inside the correct payer, with a valid token, a payer still cannot export a cohort it does not hold.
That is the contract-level (logical) boundary.

### Forced `_tag`

```xml
<set-query-parameter name="_tag" exists-action="override">
  <value>@(string.Join(",", contracts.Select(c => "https://providence.org/fhir/contract|" + c)))</value>
</set-query-parameter>
```

`exists-action="override"` is the important attribute. A caller-supplied `_tag` is **replaced**, not
merged. A payer cannot widen its own result set by supplying a tag for a contract it does not hold —
case 13 in [tests/isolation-proofs.http](../tests/isolation-proofs.http).

An earlier draft used `rewrite-uri` to build the query string. It broke on path-prefix duplication
and was fragile under edits. `set-query-parameter` is declarative and does not care what the rest of
the URL looks like.

---

## 5. Rate limiting

| Limit | Value | Purpose |
|---|---|---|
| Requests | 600 / 60s per payer | Normal protection |
| Quota | 50,000 / day per payer | Abuse ceiling |
| **Export** | **1 per 300s per payer** | **The burst mitigation** |

The export limit is conditional:

```xml
<rate-limit-by-key calls="1" renewal-period="300"
   counter-key="@("export-" + payerKey)"
   increment-condition="@(routeClass == "export")" />
```

Only `$export` submissions increment it, so polling an in-flight job is unaffected — a payer is
never locked out of the job it already started.

This is the single highest-value line in the policy for Providence. It converts *"usually happens at
the same time … will pop the server itself"* from an uncontrolled burst into a queue, at the
gateway, before any FHIR capacity is consumed.

---

## 6. Trusted broker

```xml
<authentication-managed-identity resource="{fhirUrl}"
                                 output-token-variable-name="msi" ignore-error="false" />
<set-header name="Authorization" exists-action="override">
  <value>@("Bearer " + (string)context.Variables["msi"])</value>
</set-header>
```

The payer's token is discarded. AHDS is called with APIM's system-assigned managed identity.

Consequences, all of them good:

- The payer's credential never reaches the FHIR service.
- AHDS makes no payer-specific authorisation decision — it sees one trusted caller.
- **Only APIM holds FHIR Data Contributor**, so a payer token sent directly to AHDS returns `403`.
  This is the keystone: it is what turns "we filter at the gateway" into "the gateway cannot be
  bypassed."
- `ignore-error="false"` — if the MI token cannot be acquired, fail rather than forward an
  unauthenticated request.

Two headers are added for audit: `X-Providence-Caller` (the app id) and `X-Providence-Payer`, so the
AHDS audit log can attribute a request to the originating payer despite the identity swap.

---

## Outbound section

- Strips `X-Powered-By` and `X-AspNet-Version`.
- **Rewrites `Content-Location`** on `202` responses from the AHDS host to the gateway host. Without
  this the payer receives a poll URL pointing at AHDS, learns the real endpoint, and polls somewhere
  the policies do not apply.
- Adds `X-Providence-Contract-Scope` so the payer can confirm what filter was applied — useful
  during onboarding, and it costs nothing.

---

## Error handling

`on-error` returns a FHIR `OperationOutcome` rather than an APIM error envelope:

```json
{ "resourceType": "OperationOutcome",
  "issue": [ { "severity": "error", "code": "processing",
               "diagnostics": "...", "details": { "text": "correlationId: ..." } } ] }
```

Payer clients are FHIR clients. Returning a non-FHIR error body from a FHIR endpoint causes parse
failures in the payer's stack that are then reported to Providence as outages. The `correlationId`
is `context.RequestId`, which ties the payer's screenshot directly to a row in
`ApiManagementGatewayLogs`.

---

## What to watch

```kusto
// denials by API - the isolation model, observed rather than asserted
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h) and ResponseCode in (401, 403)
| summarize count() by ApiId, ResponseCode, Url
| order by count_ desc

// export throttling - is the 5-minute window too tight?
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d) and ResponseCode == 429 and Url contains "$export"
| summarize count() by bin(TimeGenerated, 1h), ApiId
```

The second query is the feedback loop on the export limit. A steady background of 429s means payers
are being made to wait unnecessarily; zero 429s during a known burst window means the limit is not
doing anything. Tune it with the data, not with an opinion.
