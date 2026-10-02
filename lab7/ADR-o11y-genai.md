# ADR: Where agent telemetry goes in abox — OTel/Jaeger, MLflow or Phoenix

**Status:** Accepted · **Date:** 2026-10-02 · **Context:** `fwdays/lab7`, task 3
**Environment:** WSL2 + KinD (24 GB / 16 CPU), abox `feat/otel-demo` bundle `0.11.33` + local patches ([`patches/`](patches/))
**Raw data:** [`results/series-20261002T102124Z.md`](results/series-20261002T102124Z.md) (clean run), [`results/series-20261002T101017Z-lossy.md`](results/series-20261002T101017Z-lossy.md) (run with span loss)

## Context

abox ships three trace backends, and an agent's spans can go to any of them:

| | Backend as deployed here | Ingest | Storage |
|---|---|---|---|
| **OTel + Jaeger** | Jaeger all-in-one inside the OTel Demo chart | OTLP gRPC/HTTP | in memory, `MEMORY_MAX_TRACES=25000` |
| **MLflow** | MLflow 3.14 tracking server | **OTLP/HTTP only** (`/v1/traces`) — a bridge collector converts gRPC and adds `x-mlflow-experiment-id` | SQLite on a PVC |
| **Phoenix** | Arize Phoenix 12 | OTLP gRPC/HTTP, **authenticated** (Bearer) | Postgres on a PVC |

The question: **which one should hold agent telemetry in abox, and what is each one actually good for?**

### Method — identical spans into all three

Upstream disables Jaeger and feeds each backend a different source, so no comparison was possible as shipped. Changes (all local patches over the upstream bundle, nothing published):

- Jaeger re-enabled; a Phoenix exporter added to the demo collector **next to** its Jaeger and MLflow-bridge exporters. All three receive the same spans **after the same processing** (the demo collector's `gen_ai_normalizer` and `transform`).
- kagent tracing switched on (`otel.tracing.*` in the chart → ConfigMap `kagent-controller` → every agent Deployment), pointed at the same collector.
- Two instrumentation stacks traced:
  - **demo agent** — Python, LangGraph, Traceloop/OpenLLMetry, model `gemma-4-31b-it`;
  - **kagent** — Go ADK, model `gemini-3.6-flash` through the OpenAI adapter; one agent, and an orchestrator delegating to it over A2A.

12 requests (8 demo, 4 kagent) were sent; each trace id was resolved immediately and the same id read from all three backends.

**Result of the clean run: for all 12 traces the span count (Jaeger = Phoenix) and the token total (Jaeger = MLflow = Phoenix) match exactly.** The backends received identical data; every difference below is in what they do with it.

## Decision

1. **Phoenix is the place for agent telemetry in abox** — the default answer to "what did the model get asked, what did it answer, what did it cost".
2. **Jaeger stays** for the system half: latency across services and everything that is not an LLM call. It is not where agent behaviour is analysed.
3. **MLflow is not the primary trace store in abox.** Its trace model is as capable as Phoenix's for agents; what rules it out as the default is the operating cost measured here. It remains the right tool when the work is experiment-shaped (comparing runs, evaluations), not as an always-on sink.

## Evidence

### What each backend makes of the same trace

Trace `9a74fcbc…` (demo agent, «What telescopes do you sell?», 22 spans, 2 LLM calls, 1 tool):

| | Jaeger | MLflow | Phoenix |
|---|---|---|---|
| Unit in the list view | span | trace, with a state (`OK`/`ERROR`/`IN_PROGRESS`) | trace / span |
| Span typing | none | `AGENT`, `CHAT_MODEL`/`LLM`, `TOOL` (`mlflow.spanType`) | `agent`, `llm`, `tool` |
| Prompt / response | raw tags: `gen_ai.input.messages`, `gen_ai.output.messages` | parsed into span inputs/outputs | parsed, shown as a conversation |
| Tool definitions | raw tag `gen_ai.tool.definitions` | `mlflow.chat.tools` | on the LLM span |
| Tokens per LLM call | raw tags, **no aggregation** | `mlflow.chat.tokenUsage` per span + total per trace | per span + total per trace |
| Non-LLM spans (HTTP, gRPC, SQL) | full detail | present, untyped | present, `unknown` |

Jaeger has every number and no way to add them up: it does not know which span was a model call. MLflow and Phoenix both do.

> An earlier reading of this data credited span typing and per-span tokens to Phoenix only. Reading MLflow's spans directly (`ajax-api/2.0/mlflow/get-trace-artifact`) showed it does both. The decision does not rest on that difference.

### Failure handling

| Situation | Jaeger | MLflow | Phoenix |
|---|---|---|---|
| **Tool failed** (`c7826d8c…`, pod does not exist) | `error=true` + message on 2 spans | trace `OK` in the list (the agent answered correctly); inside, both spans `STATUS_CODE_ERROR` with the message | `kind=tool`, `status=ERROR` on both |
| **LLM call failed** (`a9e94b31…`, Gemini 3 `thought_signature`) | error spans | trace `ERROR` | failed `llm` span with `tokens=0`, the successful one 689 — cost attributed only where incurred |
| **Incomplete trace** (root span lost, lossy run) | tree without a root, **no indication** | trace stays **`IN_PROGRESS`**, duration of the received part only | tree without a root, **no indication** |

MLflow is the only one that tells you a trace is incomplete. In the lossy run that was the single visible symptom inside any UI that data had been dropped.

### Agent topology

| | All three |
|---|---|
| **A2A delegation** (orchestrator → sub-agent, `65e49c8d…`) | one trace across controller, orchestrator and sub-agent; the hop shows as `execute_tool kagent__NS__lab7_k8s_agent` |
| **MCP tool call** (agent → `kagent-tools`) | the tool server's `mcp.tool.k8s_get_resources` lands in a **separate trace** — trace context does not cross the MCP hop |

Per-agent cost inside a delegated trace is readable in MLflow and Phoenix (tokens on each LLM span under its own `invoke_agent`: orchestrator 686 of 21 626); in Jaeger only as raw tags.

The cost of a failing path is visible in both: «logs of a pod that does not exist» took 6 LLM calls and 25 199 tokens, a plain question 2 calls and 2 012.

### Operating cost — what it took to get data in

| | Jaeger | MLflow | Phoenix |
|---|---|---|---|
| Worked out of the box | yes (once re-enabled) | no | no |
| What had to be done | — | bridge collector for gRPC→HTTP; experiments created by hand **in an order that matches ids hardcoded in the bridge** (a fresh store has only `Default`; every export 404'd); `--allowed-hosts` for the Service DNS name; probe timeouts and worker count tuned upstream after crash-loops | ingest key created in the UI (shown once) and passed as a Bearer header |
| How a broken ingest looked | — | 404 on every export, visible **only in the bridge collector's log** | `Unauthenticated` on every export, visible **only in the exporting collector's log** |
| Retention | **hours** under demo load — all three traces recorded at the start were evicted (lookup by id → 404) | kept (SQLite) | kept (Postgres) |
| Auth on ingest | none | none | **yes** |

Traces carry prompts and responses. Of the three, only Phoenix refuses them from an unauthenticated sender.

MLflow's ids are the weakest point for abox specifically: `make down` wipes the PVC, the next `make run` recreates only `Default`, and the bridge silently 404s until someone recreates experiments in the right order.

### Noise

kagent's controller emits ~18 single-span traces per request (`POST /api/tasks`, `/api/sessions/…/events`). In MLflow they land in the same experiment as agent traces (20 traces for a handful of requests). Any backend chosen for agents needs that filtered at the collector.

### Observed once, not explained

On the failed-LLM trace `a9e94b31…` MLflow's trace tags carried `service.name=product-catalog` (a span from another service in the same trace) instead of `agent`; on successful traces they carried `agent`. Not reproduced or investigated further.

## Consequences

### Positive

- Phoenix: typed spans, token accounting per call and per agent, prompts as conversations, persistent storage, and the only authenticated ingest — the right default for agent work.
- Jaeger kept for the non-LLM view, which neither of the others replaces: it is the only one built around cross-service latency.

### Negative

- **Three backends means three ingest paths to keep alive**, and each breaks silently: a 404 or an `Unauthenticated` sits in a collector log while the UI is just empty.
- **The shared collector is a single point of loss.** At the chart's 400Mi it refused data with 503; at 1Gi it still dropped 6 span batches in a 12-request series (773Mi working set against an ~819Mi limiter threshold), losing one trace entirely and the root span of five. Only 2Gi gave a clean run. It also ships its own telemetry to itself. **Every backend showed the damaged data as if it were complete, except MLflow's `IN_PROGRESS`.**
- Phoenix's key is a secret that must exist before the collector can deliver; it is created in Phoenix's UI after Phoenix is up — a chicken-and-egg ordering (solved here with an `optional` Secret ref plus a collector restart).
- Phoenix's REST span listing (`/v1/projects/{p}/spans`) returned 1 000 spans spread over hours and no working trace-id filter was found; point lookups here went through its GraphQL API (`Project.trace(traceId)`).

### What the backend choice does not fix

The largest effects in this lab came from **instrumentation and clients**, not from any backend:

- The demo agent cannot run on **any Gemini 3 model**: `langchain_openai` drops the `thought_signature` Gemini 3 requires on tool-call turns (HTTP 400). Gemini 2.5 is closed to new keys. It runs on Gemma 4 instead. kagent's Go OpenAI adapter on the same model and endpoint has no such problem.
- kagent's **Gemini adapter writes no prompt/response** onto spans (token counts only); the OpenAI adapter on Gemini's OpenAI-compatible endpoint does. Which adapter an agent uses decides whether any backend can show the conversation.
- **MCP breaks trace context**, A2A does not. No backend can join what the instrumentation splits.

## Alternatives considered

**MLflow as the single backend.** Its trace model covers what agent work needs, and it is the only one that flags incomplete traces. Rejected as the default for abox because of what it took to keep data flowing: a protocol bridge, hand-created experiments whose ids must match a hardcoded config and are lost with the PVC, a Host-header guard, and probe/worker tuning against crash-loops. A good fit where traces belong to experiments; a fragile always-on sink.

**Jaeger only.** Complete data, no GenAI semantics: cannot say which span was the model call, cannot total tokens, and in this deployment forgets everything within hours. Persistent storage (Badger, Elasticsearch, Cassandra) would fix retention, not semantics.

**Keep all three, fan-out (as run here).** Worth it for a comparison; not as a standing setup — three silent failure modes and a collector that needed 5× its default memory.

## What this does not settle

- **Evaluations and playgrounds** — Phoenix evals and Prompt Playground, MLflow assessments and experiment comparison. These are why those two tools exist; a trace comparison does not touch them. Untested.
- **Sessions / multi-turn** — every request here was single-turn.
- **Cost in money** — token counts only; no pricing was configured for Gemma or Gemini 3.6.
- **Scale** — 12 requests, one run each, one node. No throughput, no retention under load beyond the Jaeger eviction observed.
- **Gateway-level tracing** — `agentgateway-llm` → Phoenix was left out: its tracing config sends no auth header, and the demo agent does not route through it.

## Verification

```bash
# the same trace id in all three (UIs: see lab7/TODO.md, «Доступ до UI»)
T=9a74fcbc0c571c4abe78770d248fc2e9
curl -s "localhost:16686/jaeger/ui/api/traces/$T" | jq '.data[0].spans | length'          # Jaeger (evicted within hours)
curl -s "localhost:5000/api/3.0/mlflow/traces/tr-$T" | jq '.trace.trace_info.state'       # MLflow
curl -s "localhost:5000/ajax-api/2.0/mlflow/get-trace-artifact?request_id=tr-$T" \
  | jq -r '.spans[] | .name + "  " + (.attributes["mlflow.spanType"] // "-")'            # MLflow span types
# Phoenix: GraphQL with the ingest key — see lab7/run-series.sh

# a full series with a per-trace comparison table
bash lab7/run-series.sh
```
