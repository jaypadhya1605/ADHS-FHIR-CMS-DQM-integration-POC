# Graphify knowledge graph

The engagement corpus for this POC — architecture decisions, meeting notes, Bicep, APIM policies,
scripts and diagrams — was indexed into a deterministic knowledge graph using
[graphify](https://github.com/Graphify-Labs/graphify) 0.9.38. This folder holds the **method**, so
the graph can be rebuilt over this repository or over your own corpus.

## Why

At 40 payers, ~200 contracts and eight separate design documents, "where was that decided and what
does it depend on?" stops being answerable by search. The graph makes the dependency structure
explicit: which policy layer enforces which decision, which script proves which control, which
rationale sits behind which module.

## What a run produces

| Artifact | What it is |
|---|---|
| `GRAPH_REPORT.md` | Read first — communities, god nodes, surprising connections, suggested questions |
| `graph.html` | Interactive graph. Open directly in a browser, no server needed |
| `graph.json` | The graph itself — nodes, edges, hyperedges, communities |
| `manifest.json` | Per-file hashes, so a later run only re-extracts what changed |
| `cost.json` | Run ledger |
| `cache/` | AST and semantic extraction cache, keyed by file hash |
| `converted/` | Office documents converted to markdown for extraction |

**Only the method is committed here.** The generated artifacts from the original run are not, because
they embed extracted text from internal working notes, meeting transcripts and email threads that
are not in this repository. Rebuild locally to get a graph scoped to what you actually have.

## The original run, for reference

132 files, ~283,000 words → **930 nodes, 1,441 edges, 43 communities**. AST extraction covered 45
code files (`.cs .csproj .sln .json .ps1 .py .cjs`); everything else went through semantic
extraction. 84% of edges were `EXTRACTED`, 16% `INFERRED` at average confidence 0.85.

Highest-degree nodes — the concepts everything else hangs off:

| Node | Degree |
|---|---|
| `Extensions` (HL7 ingest helper) | 20 |
| `ServiceBusQueueListener` | 16 |
| `HL7ToXmlConverter` | 13 |
| Azure Health Data Services FHIR Service | 13 |
| Validate → Segregate → Import pipeline | 11 |
| Per-payer FHIR service (`fhir-R4`) | 11 |
| APIM as mandatory control plane (D6) | 10 |

## Deviations from a stock run

Recorded because they change how the output should be read:

- **`.bicep`, `.bicepparam`, `.xml`, `.http`, `.mmd`, `.drawio`, `.hl7` were added to the document
  set.** graphify has no AST parser for them, so stock behaviour is to drop them — but they are the
  substance of this solution. They were routed through semantic extraction instead, which means
  their entities are named concepts rather than parsed symbols.
- **A vendored third-party bundle was excluded.** One `docx.cjs` produced 1,079 AST nodes — 78% of
  the entire AST extraction — and swamped the graph with library internals. Excluding it dropped the
  community count from 338 to 43.
- **Meeting recordings were not transcribed.** Whisper/torch does not install cleanly on ARM64, and
  the written notes for the same sessions were already in the corpus.
- **Semantic extraction ran on the host coding agent**, not a metered API key, so `cost.json`
  records zero spend.

## Rebuilding

```powershell
pip install graphify-cli

# GRAPHIFY_OUT is the ONLY way to redirect output. There is no --out-dir flag.
$env:GRAPHIFY_OUT = 'graphify/out'

graphify detect .
graphify extract .
graphify build
graphify cluster
graphify analyze
graphify report
graphify html
```

[`.graphify_rules.md`](.graphify_rules.md) is the extraction contract used for the original run —
node ID scheme, confidence bands, per-chunk output budget, and the schema every fragment must match.
Point a fresh run at it to reproduce the same shape of graph.
