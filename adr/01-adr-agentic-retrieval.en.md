---
status: "accepted"
date: 2026-09-19
decision-makers: Alex Pokatilov
consulted: abox author (den-vasyliev) — via the stand's code and documentation
informed: fwdays/lab4
---

# Custom `qdrant-mcp` with nomic-768d over the official MCP server for Agentic Retrieval

## Context and Problem Statement

The [abox](https://github.com/den-vasyliev/abox) stand implements Agentic Retrieval over two stores: **Qdrant** (object text + embedding, via the `vector_store`/`qdrant-store` tool) and **Neo4j** (object nodes and relationships, via `write-cypher`).

The `fwdays/lab4` assignment (items 6–8) requires indexing the same data — the cluster's kagent manifests — with two different MCP servers using different embedding models, and then **comparing and assessing Agentic Retrieval quality**.

The question: which MCP server and embedding model should be chosen for indexing, and what actually drives the difference in quality — vector dimensionality, or something else?

Both configurations were deployed **simultaneously**, with an identical system prompt (differing only in tool names), the same agent model (`gemini-3.1-flash-lite`, Google AI Studio) and the same delegate (`my-first-k8s-agent`). This attributes any difference in results to the vector backend rather than to the rest of the pipeline.

## Decision Drivers

* **Ingest completeness** — whether every cluster object reaches the store.
* **Text accuracy in the vector** — this is what gets searched, so wrong text poisons the store itself.
* **Metadata usability** for vector → graph linkage (`name`/`kind`/`namespace` in the payload).
* No external dependencies in the ingest path.
* Storage cost (vector dimensionality).

## Considered Options

* **Custom `qdrant-mcp` 0.4.0** (Rust `rmcp` 0.6.4 + Go core), `nomic-embed-text-v1.5` f16, 768d
* **Official [`qdrant/mcp-server-qdrant`](https://github.com/qdrant/mcp-server-qdrant)** (Python), `all-MiniLM-L6-v2` fastembed in-process, 384d
* A stronger agent model instead of `flash-lite`
* llm-d instead of llama.cpp as the embedding backend

Configuration of the two main candidates:

| | Official | Custom (abox) |
| --- | -------- | ------------- |
| Tools | `qdrant-store` / `qdrant-find` | `vector_store` / `vector_find` |
| Embedding | `all-MiniLM-L6-v2`, fastembed **in-process** | `nomic-embed-text-v1.5` f16, llama.cpp over HTTP |
| Dimensions | **384** | **768** |
| Collection | `abox-minilm` (named vector `fast-all-minilm-l6-v2`) | `abox-nomic` (unnamed vector) |

## Decision Outcome

Chosen option: **custom `qdrant-mcp` with `nomic-embed-text-v1.5` (768d)**, because on identical data and prompt it produced a complete and accurate set in the vector store (20 records, correct text), whereas the official server produced **15 of 18 objects with systematically wrong text**.

The reason is **not vector dimensionality and not semantic search quality**, but how completely and accurately the data lands in the store in the first place.

### Consequences

* Good, because the graph is complete and accurate: 18 nodes, all 24 real relationships.
* Good, because the vector holds correct text plus metadata usable for vector → graph linkage.
* Good, because 768d leaves headroom for semantic search quality.
* Bad, because of an **external dependency**: `qdrant-mcp` requires a live llama.cpp (`llama-cpp-embeddings.llama-cpp:8090`); if llama.cpp goes down, ingest stops working. The official server embeds in-process and has no such dependency.
* Bad, because of **contract strictness**: `vector_store` declares `metadata` as `{"type":"object","additionalProperties":{"type":"string"}}` and rejects a JSON string:

    ```text
    unmarshaling: json: cannot unmarshal string into Go struct field
    StoreParams.metadata of type map[string]string
    ```

    The official Python server accepts a string. Verified by calling MCP directly: an object is accepted, a string is not. The server behaves per its own schema; the risk lies in how the model reacts (see Confirmation).
* Bad, because 768d versus 384d doubles memory and disk per point.

### Confirmation

Verification was done as a comparative measurement on wiped stores (`MATCH (n) DETACH DELETE n` plus collection deletion), using an identical ingest request issued one kind at a time.

**Ground truth in the cluster:** 18 CRDs — 10 `Agent`, 3 `ModelConfig`, 3 `MCPServer`, 2 `RemoteMCPServer`; 10 `USES_MODEL` and 14 `USES_TOOL` relationships.

Two open risks require a check **after every ingest**:

1. **Metadata loss (non-deterministic).** In one run `flash-lite` passed `metadata` as a string, got the error — and instead of fixing the format it **dropped the field entirely**, retrying with `metadata: {}`. Every record was written without metadata while the agent reported success; no error signalled this. In the final run the model serialized the object correctly, so the defect is non-deterministic — a property of `flash-lite`, not of the server.
   **Mitigation:** check that `name`/`kind` are present in the payload after ingest.
2. **A2A delegation boundary.** The delegate returns its own answer rather than raw tool output. Asked to "return the YAML of all 16 objects" it never once returned the full set — 8, then 4, then 5 objects, and on one occasion it switched to pod diagnostics (`k8s_get_pod_logs`), because its prompt is a troubleshooter prompt.
   **Mitigation:** request one kind at a time.

## Pros and Cons of the Options

### Custom `qdrant-mcp` 0.4.0 (nomic 768d)

Collection `abox-nomic`, unnamed vector.

* Good, because it wrote **20 points** (18 CRDs + 2 HelmReleases) — full coverage.
* Good, because the vector text **matches the manifests**.
* Good, because `name`/`kind`/`namespace` metadata sits at the payload root — convenient for linking to the graph.
* Neutral, because 768d is twice the vector size: better search quality at twice the storage cost.
* Bad, because it depends on an external llama.cpp over HTTP.
* Bad, because it validates `metadata` strictly and rejects a JSON string, which `flash-lite` handles unpredictably.

### Official `mcp-server-qdrant` (MiniLM 384d)

Collection `abox-minilm`, named vector `fast-all-minilm-l6-v2`.

* Good, because it embeds in-process — no external dependencies.
* Good, because it tolerates `metadata` passed as a string.
* Good, because vectors are half the size.
* Bad, because it wrote **15 of 18** objects — it missed `my-first-k8s-agent`, `kagent-tool-server` and `kagent-grafana-mcp`.
* Bad, because it **wrote wrong text into the vector**. Example — `retrieval-agent`:

    ```text
    minilm: "data agent for graph and vector store using default-model-config and kagent-tool-server"
    nomic:  "Graph/Vector ingest. Tools: qdrant-mcp, neo4j-mcp. Agent: k8s-agent. Model: default-model-config."
    truth:  tools = qdrant-mcp, neo4j-mcp, k8s-agent
    ```

    `kagent-tool-server` was attributed to agents that do not have it. This is the same hallucination seen in the graph, but here it is **written into the vector** — poisoning the very store that is later searched.
* Bad, because no official **image exists**: the GHCR package returns 404 and Docker Hub only carries private forks. Deployed as `python:3.11-slim` + `uvx mcp-server-qdrant` (~30–60 s to start, requires PyPI access).

### A stronger agent model instead of `flash-lite`

Not tested.

* Good, because it would likely remove the `kagent-tool-server` hallucination and serialize `metadata` more reliably.
* Bad, because it would not resolve the A2A delegation boundary — that limit is architectural, not model-related.
* Bad, because swapping the model in only one twin would make the two runs incomparable.

### llm-d instead of llama.cpp

The `feat/llmd-embeddings` release did deploy llm-d, but `qdrant-mcp` is configured against `llama-cpp-embeddings.llama-cpp:8090`.

* Neutral, because llm-d is **not part of this path** — redundant for the lab.
* Good, because it remains an option for a future comparison of embedding backends.

## More Information

### Neo4j graph — shared across both runs

`MERGE` is idempotent, so both agents wrote into the same graph; separating their contributions is not possible.

| Metric | Created | Correct | Wrong |
| ------ | ------- | ------- | ----- |
| Nodes | 20 | **18/18 CRDs** | +2 `HelmRelease` (out of scope) |
| `USES_MODEL` | 12 | **10/10** | 2 |
| `USES_TOOL` | 21 | **14/14** | 7 |

**Relationship completeness is 100%** — not a single real relationship was lost.

The 2 wrong `USES_MODEL` edges: `retrieval-agent-native` and `-official` additionally picked up `default-model-config`. This is **not a hallucination** — the source is real, the field `spec.declarative.memory.modelConfig`, which the prompt does not describe. A prompt defect, not a model defect.

The 7 wrong `USES_TOOL` edges: every agent was given `kagent-tool-server` — a generalization hallucination, since most agents genuinely do have it and the model extended the pattern to the rest.

### Comparison with earlier runs

| | Run 1 (minilm) | Run 2 (nomic) | Final (clean stores) |
| --- | -------------- | ------------- | -------------------- |
| Nodes | 16/16 | +0 | **18/18** |
| `USES_MODEL` correct | 7 of 9 | 7 of 9 | **10 of 10** |
| `USES_TOOL` correct | 1 of 5 | 1 of 7 | **14 of 14** |
| Models swapped around | ❌ yes | ❌ yes | ✅ no |

The decisive change was **requesting the ingest "one kind at a time"**. That, rather than the model or the backend, lifted graph accuracy from roughly 20% to 100%.

### The OOMKill did not reproduce

The abox author replaced the official server with a custom one because it died at a 2Gi limit. In our measurements the peak was **~310 MiB** against a 3Gi limit. The difference is the model: the author loaded f32 nomic, we loaded MiniLM.

In other words, the original rationale for the replacement **is not confirmed** by our measurements — this decision rests on ingest accuracy, not on memory.

### Conclusion for lab item 8

The difference in Agentic Retrieval quality between the two MCP servers is driven **not by vector dimensionality** (384 vs 768) but by how completely and accurately the data got there: on an identical prompt the official server yielded 15 of 18 objects with wrong text, the custom one yielded 20 with correct text.

The pipeline's limiting factor sits **upstream of** vectorization — the A2A delegation boundary and `flash-lite` hallucinations. The largest accuracy gain (`USES_TOOL` from 20% to 100%) came neither from the store nor from the model, but from **how the ingest request was phrased**.

### References

* [abox](https://github.com/den-vasyliev/abox) — the lab stand
* [`qdrant/mcp-server-qdrant`](https://github.com/qdrant/mcp-server-qdrant) — the official MCP server
* [MADR 4.0.0](https://github.com/adr/madr/blob/4.0.0/template/adr-template.md) — the template this ADR follows
* `TASK.md` — the lab assignment, items 6–8
* Twin agents: `agent-retrieval-official.yaml`, `agent-retrieval-native.yaml`
* Intermediate indexing run history — `lab4-retrieval-results.md` (HomeLab-K3s repository)
* Ukrainian original: `01-adr-agentic-retrieval.md`
