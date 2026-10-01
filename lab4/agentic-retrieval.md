# ADR: Qdrant MCP server and embedding model for Agentic Retrieval

**Status:** Accepted · **Date:** 2026-09-19 · **Context:** `fwdays/lab4`, tasks 6-8
**Environment:** bare-metal k3s (3 nodes), abox release `feat/llmd-embeddings`

## Context

abox provides Agentic Retrieval over **two** stores, and the agent picks between
them by the shape of the question:

| Store | Holds | Tool |
|---|---|---|
| **Qdrant** | object prose + embedding | `vector_store` / `qdrant-store` |
| **Neo4j** | nodes + relationships between objects | `write-cypher` |

The decision: **which Qdrant MCP server, and which embedding model**, to index
kagent manifests with.

| | Official | Built-in (abox) |
|---|---|---|
| Server | [`qdrant/mcp-server-qdrant`](https://github.com/qdrant/mcp-server-qdrant) (Python) | `qdrant-mcp` 0.4.0 (`rmcp` 0.6.4 gateway + Go core) |
| Tools | `qdrant-store` / `qdrant-find` | `vector_store` / `vector_find` |
| Embeddings | `all-MiniLM-L6-v2`, fastembed in-process | `nomic-embed-text-v1.5` f16, llama.cpp over HTTP |
| Dimensions | **384** | **768** |
| Collection | `abox-minilm` (named vector) | `abox-nomic` (unnamed vector) |

Both were deployed simultaneously, with the **same** system prompt (only the tool
names differ), the same agent model (`gemini-3.1-flash-lite`) and the same
delegate — so a difference in outcome is attributable to the vector backend.

## Decision

**Use the built-in `qdrant-mcp` with `nomic-embed-text-v1.5` (768d).**

The reason is not the vector dimension and not semantic search quality. It is
**how completely and accurately the data lands in the store.** On identical input
the official server produced an incomplete and partly wrong set.

## Evidence

Both stores were wiped (`MATCH (n) DETACH DELETE n`, collections deleted), then
each agent was given the same ingest request, one kind at a time.

Ground truth: 18 CRDs — 10 `Agent`, 3 `ModelConfig`, 3 `MCPServer`,
2 `RemoteMCPServer`; 10 `USES_MODEL`, 14 `USES_TOOL`.

### Vector store — where the difference showed

| | `abox-minilm` (official) | `abox-nomic` (built-in) |
|---|---|---|
| Points stored | **15 of 18** | **20** (18 CRDs + 2 HelmReleases) |
| `name`/`kind`/`namespace` metadata | ✅ under `metadata` | ✅ at payload root |
| Text accuracy | ❌ systematically wrong | ✅ matches the manifests |

Missed by the official server: `my-first-k8s-agent`, `kagent-tool-server`,
`kagent-grafana-mcp`.

Wrong text, e.g. for `retrieval-agent`:

```
minilm: "data agent for graph and vector store using default-model-config and kagent-tool-server"
nomic:  "Graph/Vector ingest. Tools: qdrant-mcp, neo4j-mcp. Agent: k8s-agent. Model: default-model-config."
truth:  tools = qdrant-mcp, neo4j-mcp, k8s-agent
```

`kagent-tool-server` is attributed to agents that do not reference it. The same
hallucination exists in the graph — but in `abox-minilm` it is **written into the
vector**, i.e. into the store that later gets searched. In `abox-nomic` the prose
is correct.

### Graph — shared between both runs

`MERGE` is idempotent, so both agents wrote into one database and the
contributions cannot be separated.

| Metric | Created | Correct | False |
|---|---|---|---|
| Nodes | 20 | **18/18 CRDs** | +2 `HelmRelease` (out of scope) |
| `USES_MODEL` | 12 | **10/10** | 2 |
| `USES_TOOL` | 21 | **14/14** | 7 |

**Relationship recall is 100%** — no real edge was lost.

The 2 false `USES_MODEL` edges point at `default-model-config` from
`spec.declarative.memory.modelConfig` — a real field the prompt does not
describe. That is a prompt gap, not a hallucination. The 7 false `USES_TOOL`
edges are a spurious `kagent-tool-server` on every agent: most agents genuinely
have it and the model generalised.

### What actually improved accuracy

| | run 1 | run 2 | final |
|---|---|---|---|
| `USES_MODEL` correct | 7/9 | 7/9 | **10/10** |
| `USES_TOOL` correct | 1/5 | 1/7 | **14/14** |
| Models swapped between two agents | yes | yes | **no** |

The change was asking for the ingest **one kind at a time** — not the backend,
not the model.

## Consequences

### Positive

- Complete, accurate graph: 18 nodes, all 24 real relationships.
- Correct prose in the vector plus usable metadata for a vector→graph join.
- 768d leaves headroom for retrieval quality.

### Negative

- **External dependency.** `qdrant-mcp` needs a live llama.cpp at
  `llama-cpp-embeddings.llama-cpp:8090`. The official server embeds in-process
  and has no such dependency; if llama.cpp is down, ingest stops.
- **Strict contract.** `vector_store` declares `metadata` as
  `{"type":"object","additionalProperties":{"type":"string"}}` and rejects a JSON
  string:
  ```
  unmarshaling: json: cannot unmarshal string into Go struct field
  StoreParams.metadata of type map[string]string
  ```
  The official Python server accepts the string. Verified by calling the MCP
  endpoint directly — object accepted, string rejected. The server is behaving
  per its own schema; the risk is in the model's reaction (below).
- 768d costs twice the memory and disk per point versus 384d.

### Open risks

**Silent metadata loss.** In one run `gemini-3.1-flash-lite` sent `metadata` as a
string, received the error above, and instead of correcting the format **dropped
the field**, repeating the call with `metadata: {}`. All records were stored
without metadata, the vector→graph join was impossible, and the agent reported
success — nothing surfaced the failure.

In the final run the same model serialised the object correctly, so the defect is
**non-deterministic** — a `flash-lite` property, not a server bug. Mitigation:
assert `name`/`kind` are present in the payload after an ingest.

**A2A delegation limit.** A delegate returns *its own answer*, not raw tool
output. Asked for the YAML of all 18 objects it never returned the full set — 8,
then 4, then 5 — and once switched to `k8s_get_pod_logs` and
`k8s_check_service_connectivity` to troubleshoot a failing MCP server, because
its prompt is a troubleshooter's prompt. Workaround: request **one kind per
message**; this is what produced the accuracy jump above. The limit is
architectural, so a stronger delegate model would not remove it.

## Alternatives considered

**Official `mcp-server-qdrant` (384d).** Rejected: 15 of 18 objects and
systematically wrong prose in the vector. Its upsides are real — no external
dependency, tolerant of a `metadata` string, half the vector size.

> No official **image** exists: the GHCR package returns 404 and Docker Hub only
> carries personal forks. Deployed as `python:3.11-slim` + `uvx
> mcp-server-qdrant` (~30-60 s per pod start, needs PyPI).

**The documented OOMKill did not reproduce.** `CODEBASE.md` cites the official
server being OOMKilled at a 2Gi limit as the reason for the built-in one.
Measured peak here: **~310 MiB** at a 3Gi limit. The difference is the model —
f32 nomic vs. MiniLM — not onnxruntime. So this ADR does **not** rest on memory
behaviour; it rests on ingest accuracy.

**A stronger agent model.** Not tested. It would likely remove the
`kagent-tool-server` generalisation and serialise `metadata` more reliably, but
not the A2A limit. Changing the model in only one of the two agents would have
made the runs incomparable, so it would require re-running both from scratch.

**llm-d instead of llama.cpp for embeddings.** The release ships two
OpenAI-compatible endpoints serving the same model precisely so they can be
compared: llm-d (`llm-d-embedding.llm-d:8000`) and plain llama.cpp
(`llama-cpp-embeddings.llama-cpp:8090`). `qdrant-mcp` is configured against the
latter, so llm-d is not exercised by this lab. Comparing the two backends under
the same MCP server is the obvious follow-up and was left out of scope.

## Conclusion (task 8)

The difference in Agentic Retrieval quality between the two MCP servers is driven
**not by vector dimension** (384 vs 768) but by how completely and correctly the
data was stored. On an identical prompt the official server produced 15 of 18
objects with wrong prose; the built-in one produced 20 with correct prose.

The pipeline's limiting factor sits **before** vectorisation: the A2A delegation
limit and `flash-lite` hallucinations. The largest single accuracy gain
(`USES_TOOL` from 20% to 100%) came from the wording of the ingest request — one
kind at a time — not from the store and not from the model.

## Verification

```bash
PW=$(kubectl -n kagent get mcpserver neo4j-mcp \
  -o jsonpath='{.spec.deployment.env.NEO4J_MCP_PASSWORD}')

kubectl -n neo4j exec neo4j-0 -- cypher-shell -u neo4j -p "$PW" --format plain \
  "MATCH (n) RETURN labels(n)[0] AS label, count(*) ORDER BY label;"
kubectl -n neo4j exec neo4j-0 -- cypher-shell -u neo4j -p "$PW" --format plain \
  "MATCH ()-[r]->() RETURN type(r), count(*) ORDER BY type(r);"

kubectl -n qdrant port-forward svc/qdrant 6333:6333 &
curl -s localhost:6333/collections/abox-minilm | grep -o '"points_count":[0-9]*'
curl -s localhost:6333/collections/abox-nomic  | grep -o '"points_count":[0-9]*'

# metadata present? — the check that would have caught the silent loss
curl -s -X POST localhost:6333/collections/abox-nomic/points/scroll \
  -H 'Content-Type: application/json' -d '{"limit":3,"with_payload":true}'
```
