# lab4 — Agentic Retrieval: official vs. built-in Qdrant MCP

Lab write-up for `fwdays/lab4`, run against a bare-metal homelab k3s cluster
instead of GitHub Codespaces.

> **Scope note.** [CONTRIBUTING.md](../CONTRIBUTING.md) says agent
> implementations belong in projects that *use* abox, not in `releases/`. Nothing
> here touches the release pipeline — this directory is a self-contained lab
> record. The manifests in `manifests/` are applied by hand, after `releases/`
> has reconciled.

## What was done

| # | Task | Result |
|---|---|---|
| 0-1 | Deploy abox from the `feat/llmd-embeddings` release | ✅ |
| 2 | Add the official Qdrant MCP server | ✅ `mcp-server-qdrant` |
| 3 | Point the retrieval + k8s agents at own Google AI Studio keys | ✅ Gemini |
| 4-5 | Wire the official MCP tools and adapt the system prompt | ✅ |
| 6 | Index data with `sentence-transformers/all-MiniLM-L6-v2` | ✅ `abox-minilm`, 384d |
| 7 | Index the same data with the built-in MCP (changed toolset) | ✅ `abox-nomic`, 768d |
| 8 | Compare retrieval quality, record an ADR | ✅ [ADR](ADR-agentic-retrieval.md) |

**Decision: the built-in `qdrant-mcp` with `nomic-embed-text-v1.5` (768d).**
Not because of the vector size — because the official server stored 15 of 18
objects and got their text wrong. Full reasoning, numbers and trade-offs in the
[ADR](ADR-agentic-retrieval.md).

## Environment differences from upstream

The lab assumes Codespaces + KinD. This run used a 3-node k3s cluster on
bare metal, which changed three things.

**No `cloud-provider-kind`.** The gateway's LoadBalancer IP comes from Cilium
LB-IPAM instead. A dedicated pool ([`manifests/lb-ip-pool.yaml`](manifests/lb-ip-pool.yaml))
selects the gateway Service by namespace metadata, so no label has to be put on
the Service and no Kustomize patch is needed:

```yaml
serviceSelector:
  matchLabels:
    io.kubernetes.service.namespace: agentgateway-system
```

Cilium injects `io.kubernetes.service.namespace` / `.name` into the label set
before matching (`operator/pkg/lbipam/service_store.go`, `svcLabels()`), so a
pool can select a Service that carries no labels at all.

**amd64 only.** The `nomic-embed` image is a single amd64 manifest, so the whole
stand had to land on the x86 cluster rather than the arm64 one.

**Flux beside Argo CD.** The cluster already ran Argo CD. Flux was installed
alongside it with `.spec.sync` unset on the `FluxInstance`, so Flux only
reconciles the OCI artifact and never adopts Argo CD's releases. Verified: all
pre-existing Helm releases unchanged before and after.

**Gateway API CRDs.** k3s ships a packaged `gateway-api-crd` addon that
overwrites manually installed CRDs on every restart, and Cilium 1.18.x crash-loops
when `TLSRoute v1alpha2` is absent. Resolved by disabling the addon
(`--disable=gateway-api-crd`), installing the experimental channel CRDs, and
upgrading Cilium to 1.20.2.

## The two configurations

Both agents share the same system prompt, the same model
(`gemini-3.1-flash-lite`) and the same delegate. Only the vector backend differs,
so any difference in the result is attributable to it.

| | [`retrieval-agent-official`](manifests/agent-retrieval-official.yaml) | [`retrieval-agent-native`](manifests/agent-retrieval-native.yaml) |
|---|---|---|
| MCP server | official `mcp-server-qdrant` | built-in `qdrant-mcp` |
| Tools | `qdrant-store` / `qdrant-find` | `vector_store` / `vector_find` |
| Embeddings | fastembed, in-process | llama.cpp over HTTP |
| Model | `all-MiniLM-L6-v2` | `nomic-embed-text-v1.5` f16 |
| Dimensions | 384 | 768 |
| Collection | `abox-minilm` | `abox-nomic` |

Tool names are a contract: the prompt has to name the tools that are actually in
the toolset, which is why the official variant's prompt is a reworded copy rather
than the same text pointed at a different server.

The built-in server reads embeddings from `llama-cpp-embeddings.llama-cpp:8090` —
backend #2 of the two the release ships. llm-d (backend #1) is not in this path.

## Results

Ground truth: 18 kagent CRDs — 10 `Agent`, 3 `ModelConfig`, 3 `MCPServer`,
2 `RemoteMCPServer`; 10 `USES_MODEL` and 14 `USES_TOOL` references.

### Vector store

| | `abox-minilm` (official) | `abox-nomic` (built-in) |
|---|---|---|
| Points stored | **15 of 18** | **20** (18 CRDs + 2 HelmReleases) |
| Metadata present | ✅ | ✅ |
| Text accuracy | ❌ systematically wrong | ✅ matches the manifests |

The official server missed `my-first-k8s-agent`, `kagent-tool-server` and
`kagent-grafana-mcp`, and wrote inaccurate prose for the rest:

```
minilm: retrieval-agent "using default-model-config and kagent-tool-server"   ✗
nomic:  retrieval-agent "Tools: qdrant-mcp, neo4j-mcp. Agent: k8s-agent"      ✓
truth:  tools = qdrant-mcp, neo4j-mcp, k8s-agent
```

`kagent-tool-server` is attributed to agents that do not use it. The same
hallucination appears in the graph — but in `abox-minilm` it is also written into
the vector, poisoning the store that gets searched.

### Graph

Both agents `MERGE` into one Neo4j database, so the contributions cannot be
separated. Combined result: **18/18 nodes**, **10/10** correct `USES_MODEL`,
**14/14** correct `USES_TOOL` — no real relationship was lost.

False edges: 7 × a spurious `kagent-tool-server` (hallucinated generalisation),
and 2 × an extra `default-model-config` sourced from
`spec.declarative.memory.modelConfig` — a real field the prompt does not describe,
so that one is a prompt gap rather than a model error.

### What actually moved the needle

| | run 1 | run 2 | final |
|---|---|---|---|
| `USES_MODEL` correct | 7/9 | 7/9 | **10/10** |
| `USES_TOOL` correct | 1/5 | 1/7 | **14/14** |
| Models swapped between two agents | yes | yes | **no** |

The jump came from asking for the ingest **one kind at a time**, not from the
backend and not from the model. Which leads to the finding that outweighs the
comparison itself:

**The A2A delegate will not hand over a large manifest set.** A delegate returns
*its own answer*, not raw tool output. Asked for the YAML of all 18 objects it
returned 8, then 4, then 5 — and once switched to `k8s_get_pod_logs` to
troubleshoot a failing MCP server instead, because its prompt is a
troubleshooter's prompt. The limit is architectural, so a stronger model would not
remove it.

### Two upstream notes

**The `metadata` contract differs between the servers.** `vector_store` declares
`metadata` as `{"type":"object","additionalProperties":{"type":"string"}}` and
rejects a JSON string:

```
unmarshaling: json: cannot unmarshal string into Go struct field
StoreParams.metadata of type map[string]string
```

The official Python server accepts the string. Verified by calling the MCP
endpoint directly: object accepted, string rejected — the server behaves exactly
as its schema says.

The risk is in how the model reacts. In one run `flash-lite` sent a string, got
the error, and instead of fixing the format **dropped the field entirely**,
repeating the call with `metadata: {}`. Every record was stored without metadata,
the vector→graph join was impossible, and the agent reported success. It is not
reproducible — in the final run the same model serialised the object correctly —
so it is worth asserting on `name`/`kind` in the payload after an ingest.

**The OOMKill did not reproduce.** `CODEBASE.md` gives the official server being
OOMKilled at a 2Gi limit as a reason for the built-in one. Measured peak here:
**~310 MiB**. The difference is the model — f32 nomic vs. MiniLM — not
onnxruntime. The decision in the ADR therefore rests on ingest accuracy, not on
memory.

> There is no official **image**: the GHCR package 404s and Docker Hub only has
> personal forks. [`manifests/mcp-server-qdrant.yaml`](manifests/mcp-server-qdrant.yaml)
> runs `python:3.11-slim` + `uvx mcp-server-qdrant`, which costs ~30-60 s of pip
> install per pod start and needs PyPI reachable.

## Applying the manifests

After `releases/` has reconciled:

```bash
kubectl apply -f lab4/manifests/lb-ip-pool.yaml          # Cilium clusters only
kubectl apply -f lab4/manifests/mcp-server-qdrant.yaml
kubectl apply -f lab4/manifests/agent-retrieval-official.yaml
kubectl apply -f lab4/manifests/agent-retrieval-native.yaml
```

Both agents expect a `ModelConfig` named `gemini-gemini-3-1-flash-lite` and a
delegate named `my-first-k8s-agent`. The delegate matters: the stock `k8s-agent`
runs on `default-model-config`, which is OpenAI with a **placeholder** API key
(`apiKey: OPENAI_API_KEY` in the chart values), so delegating to it fails
silently.

## Reproducing the comparison

Clean both stores first, or the graph will mix runs:

```bash
PW=$(kubectl -n kagent get mcpserver neo4j-mcp \
  -o jsonpath='{.spec.deployment.env.NEO4J_MCP_PASSWORD}')
kubectl -n neo4j exec neo4j-0 -- cypher-shell -u neo4j -p "$PW" \
  "MATCH (n) DETACH DELETE n;"

kubectl -n qdrant port-forward svc/qdrant 6333:6333 &
curl -X DELETE localhost:6333/collections/abox-minilm
curl -X DELETE localhost:6333/collections/abox-nomic
```

Delete the collections rather than their points — the two have different vector
schemas (`abox-minilm` uses a named vector, `abox-nomic` an unnamed one) and each
server recreates its own on first write.

Then start a fresh session with each agent and send:

```
Ingest the kagent custom resources from namespace kagent into both stores.

Scope — all objects in namespace.

Ask the my-first-k8s-agent delegate for their YAML, one kind at a time
(k8s_get_resource_yaml). Do not ingest any other objects, only CRD.

Follow your system instructions for the graph model and for what goes into the
vector store. When you are done, report: how many nodes and how many
relationships you created, by label and by type; how many entries you wrote to
the vector store; any object you could not model, and why.
```

"One kind at a time" is the part that matters — see the delegate limit above.

### Inspecting the stores

Neither has an Ingress; use port-forward.

```bash
kubectl -n neo4j  port-forward svc/neo4j 7474:7474 7687:7687   # http://localhost:7474
kubectl -n qdrant port-forward svc/qdrant 6333:6333            # :6333/dashboard
```

> `write-cypher` idempotency relies entirely on the model emitting `MERGE`
> correctly. The prompt refers to "uniqueness constraints on `key`", but
> `SHOW CONSTRAINTS` is empty — there is no database-level duplicate protection.
