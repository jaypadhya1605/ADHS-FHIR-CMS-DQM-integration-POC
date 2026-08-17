# Validation — does the demo prove what was asked?

Short answer: **yes for eight of nine asks, with one honest gap.** The gap is concurrent-export
capacity, and it is a measurement problem, not a design problem.

Every row below points at something that runs. Nothing here is a claim on a slide.

Last full verification run: **2026-08-16 — 16 of 16 assertions passed.**

---

## The asks, and where each is answered

| # | What was asked | Status | Evidence you can run |
|---|---|---|---|
| 1 | Reference architecture diagram | **Delivered** | [diagrams/providence-ahds-reference-architecture.drawio](diagrams/providence-ahds-reference-architecture.drawio) — 4 pages, editable, page 2 reproduces the four-quadrant canvas with the decision recorded |
| 2 | Physical isolation at the payer, logical at the contract | **Deployed** | `az resource list` shows two FHIR services; assertion **4** proves the payer boundary, **13b** proves the contract filter |
| 3 | "PHI separation has to be at the payer level" | **Deployed** | Assertion **4** — a valid, correctly-audienced token from the wrong payer is refused |
| 4 | Inbound and outbound isolated so payers cannot query ingest data | **Deployed** | Assertions **7, 8, 9** — writes refused on the read route, payer credentials refused on the ingest route, export refused on ingest |
| 5 | "You're not going to get out of having API management in front of it" | **Deployed** | Six-layer policy in [apim/policies/payer-outbound.xml](apim/policies/payer-outbound.xml); assertion **12** proves it cannot be bypassed |
| 6 | Payer onboarding process | **Scripted** | `./scripts/onboard-payer.ps1` — 7 steps, ~4 minutes, run it live |
| 7 | The `$import` 403 blocking dev | **Root-caused and fixed** | [docs/04-import-403-rootcause.md](docs/04-import-403-rootcause.md); the corrected grant is in [infra/modules/rbac.bicep](infra/modules/rbac.bicep) and verifiable with `az role assignment list` |
| 8 | Quota raise 10 → 40 | **Answered, action assigned** | Support ticket, evaluated against regional capacity, lead-time item — [docs/02-architecture-decisions.md](docs/02-architecture-decisions.md) §8 |
| 9 | Concurrent export capacity | **OPEN — mitigated, not measured** | Two live mitigations; [loadtest/](loadtest/) will produce the number — [docs/05-capacity-and-scale.md](docs/05-capacity-and-scale.md) |

---

## The seven follow-up questions

| Q | Topic | Status |
|---|---|---|
| 1 | Data partitioning strategy | Answered — physical at payer, logical at contract, with the reasoning for the split |
| 2 | Concurrency and throughput | Partial — mitigations deployed, measurement pending. **Same gap as #9 above.** |
| 3 | Transaction log / change tracking | Answered — `resourceVersionPolicy: versioned` gives `_history`; the honest limits are stated |
| 4 | Multi-IG version validation | Answered — not supported server-side; validate in the pipeline, with the pattern given |
| 5 | Bulk export patterns | Answered — Group-scoped only, and why system-level export is denied outright |
| 6 | SMART Backend Services | Answered — native SMART v1/v2, proxy retires Sept 2026, max 2 IdPs, scopes are resource-type-grained not row-level |
| 7 | Custom search parameters | **Answered for the first time** — `SearchParameter` → `$reindex` → use, with the reindex cost and the recommendation to prefer `identifier`/`_tag` |

Detail: [docs/03-platform-questions.md](docs/03-platform-questions.md).

---

## What the proof suite actually establishes

Sixteen assertions, grouped by the claim each one defends.

| Claim | Assertions | What would break if the claim were false |
|---|---|---|
| A payer can read its own data | 1, 2, 3 | The design would be useless |
| A payer cannot reach another payer's data | 4, 5 | PHI exposure across a contract boundary |
| A payer cannot reach a contract it is not entitled to | 6, 13, 13b | Over-disclosure inside one payer |
| Read and write directions are separate | 7, 8, 9 | A payer could see or alter the ingest pipeline |
| Export is bounded to a cohort | 10, 11 | Whole-population extraction on one request |
| **The gateway cannot be bypassed** | **12** | **Every other control becomes advisory** |
| Untagged data cannot enter | 14 | Silent unfilterable rows |
| One export per payer per window | 15 | The concurrent-export failure mode |

Assertion **12** is the keystone. A payer's token sent straight to the FHIR service returns **403,
not 401** — Entra issued the token, the application simply holds no role. That distinction is what
makes "enforced at the gateway" a boundary rather than a speed bump.

### What it does not establish

Stated plainly so nobody is surprised later.

- **Not a penetration test.** It proves the controls that were designed are the controls that are
  running. It does not search for controls nobody thought of.
- **Not a capacity test.** Sixteen sequential calls. See the gap.
- **Not a production security review.** Private endpoints, customer-managed keys, and certificate-
  based client assertions are all documented as production requirements and are not deployed here.

---

## The gap, stated without hedging

**Concurrent bulk export capacity is unmeasured.**

The concern from the working session was that roughly forty payers pull on the same schedule and
"pop the server itself." Nothing published states how many simultaneous `Group/$export` jobs an
AHDS FHIR service sustains before throttling, or how fast it scales into a burst.

Deployed mitigations that reduce the risk:

- One concurrent export per payer per 5-minute window, enforced at the gateway
- `Group/$export` only — the working set is bounded by cohort, not by population
- 600 requests/minute and 50,000/day per payer

Neither of those is a measurement. [loadtest/run-loadtest.ps1](loadtest/run-loadtest.ps1) drives
concurrency 1 → 5 → 15 → 40 with an import running in parallel, and reports p95, median and 429
rate per phase.

**Recommendation: run it before committing to a production go-live date, not after.**

---

## Production requirements not in this POC

Named here so they land in the plan rather than in a surprise.

| Item | Why it is not here | Effort |
|---|---|---|
| Private endpoints on FHIR, Storage, Key Vault | Demo needs public reachability | Low — Bicep module |
| Certificate / client-assertion credentials | Secrets are simpler to demonstrate | Low — the script supports it |
| Entitlements from the contract master | Named value resets on redeploy; fine for a POC, wrong for production | Medium |
| Customer-managed keys | Not required for a POC | Low |
| Quarantine workflow for rejected inbound | Container exists, no processor | Medium |
| Multi-region DR | Out of scope | Medium |
| Measured capacity envelope | **The gap** | Low effort, high value — the harness exists |

---

## Verdict

The demo is ready to run in front of the customer.

It closes every architectural question raised, replaces the assertion "the data is isolated" with a
test that fails loudly when it is not, and unblocks the dev-environment `$import` failure with a
root cause and a deployed fix.

One question remains open, it is named, it is mitigated, and the instrument to close it is written.
