---
status: accepted
date: 2026-10-02
decision-makers: AlexPokatilov
---

# Phoenix for agent telemetry in abox, Jaeger for the system view

## Context and Problem Statement

abox ships three trace backends, and an agent's spans can go to any of them:

| | Backend as deployed here | Ingest | Storage |
| --- | --- | --- | --- |
| **OTel + Jaeger** | Jaeger all-in-one inside the OTel Demo chart | OTLP gRPC/HTTP | in memory, `MEMORY_MAX_TRACES=25000` |
| **MLflow** | MLflow 3.14 tracking server | **OTLP/HTTP only** (`/v1/traces`) — a bridge collector converts gRPC and adds `x-mlflow-experiment-id` | SQLite on a PVC |
| **Phoenix** | Arize Phoenix 12 | OTLP gRPC/HTTP, **authenticated** (Bearer) | Postgres on a PVC |

**Which one should hold agent telemetry in abox, and what is each one actually good for?**

Context: `fwdays/lab7`, task 3. Environment: WSL2 + KinD (24 GB / 16 CPU), abox `feat/otel-demo` bundle `0.11.33` + local patches ([`patches/`](patches/)). Raw data: [`results/series-20261002T102124Z.md`](results/series-20261002T102124Z.md) (clean run), [`results/series-20261002T101017Z-lossy.md`](results/series-20261002T101017Z-lossy.md) (run with span loss). How the same spans were fed into all three is described in [Method](#method--identical-spans-into-all-three).

## Decision Drivers

* **GenAI semantics** — which span was a model call, what was asked and answered, how many tokens per call and per agent.
* **Failure visibility** — failed tools and LLM calls, incomplete traces, broken ingest.
* **Operating cost within the abox lifecycle** — what it takes to get data flowing after every `make down` / `make run`.
* **Retention** — traces must outlive the session they were recorded in.
* **Ingest auth** — traces carry prompts and responses.
* **The non-LLM view** — latency across services still has to be readable somewhere.

## Considered Options

* Phoenix for agent telemetry + Jaeger for the system view
* MLflow as the single backend
* Jaeger only
* All three, fan-out (as run in this lab)

## Decision Outcome

Chosen option: "**Phoenix for agent telemetry + Jaeger for the system view**", because it is the only combination that covers GenAI semantics, persistent storage and authenticated ingest without the operating cost that rules MLflow out as an always-on sink.

1. **Phoenix is the place for agent telemetry in abox** — the default answer to "what did the model get asked, what did it answer, what did it cost".
2. **Jaeger stays** for the system half: latency across services and everything that is not an LLM call. It is not where agent behaviour is analysed.
3. **MLflow is not the primary trace store in abox.** Its trace model is as capable as Phoenix's for agents; what rules it out as the default is the operating cost measured here. It remains the right tool when the work is experiment-shaped (comparing runs, evaluations), not as an always-on sink.

### Consequences

* Good, because Phoenix gives typed spans, token accounting per call and per agent, prompts as conversations, persistent storage, and the only authenticated ingest — the right default for agent work.
* Good, because Jaeger is kept for the non-LLM view, which neither of the others replaces: it is the only one built around cross-service latency.
* Bad, because two backends still mean two ingest paths to keep alive, and each breaks silently: an `Unauthenticated` sits in a collector log while the UI is just empty.
* Bad, because **the shared collector is a single point of loss**. At the chart's 400Mi it refused data with 503; at 1Gi it still dropped 6 span batches in a 12-request series (773Mi working set against an ~819Mi limiter threshold), losing one trace entirely and the root span of five. Only 2Gi gave a clean run. It also ships its own telemetry to itself. **Phoenix and Jaeger show the damaged data as if it were complete** — only MLflow's `IN_PROGRESS` flags it, and MLflow is not chosen.
* Bad, because Phoenix's key is a secret that must exist before the collector can deliver, and it is created in Phoenix's UI after Phoenix is up — a chicken-and-egg ordering (solved here with an `optional` Secret ref plus a collector restart).
* Bad, because Phoenix's REST span listing (`/v1/projects/{p}/spans`) returned 1 000 spans spread over hours and no working trace-id filter was found; point lookups go through its GraphQL API (`Project.trace(traceId)`).

### Confirmation

The same trace id must be readable from all three backends with matching span counts and token totals:

```bash
# UIs: see lab7/TODO.md, «Доступ до UI»
T=9a74fcbc0c571c4abe78770d248fc2e9
curl -s "localhost:16686/jaeger/ui/api/traces/$T" | jq '.data[0].spans | length'          # Jaeger (evicted within hours)
curl -s "localhost:5000/api/3.0/mlflow/traces/tr-$T" | jq '.trace.trace_info.state'       # MLflow
curl -s "localhost:5000/ajax-api/2.0/mlflow/get-trace-artifact?request_id=tr-$T" \
  | jq -r '.spans[] | .name + "  " + (.attributes["mlflow.spanType"] // "-")'            # MLflow span types
# Phoenix: GraphQL with the ingest key — see lab7/run-series.sh

# a full series with a per-trace comparison table
bash lab7/run-series.sh
```

The series report also counts span loss on the way to the backends (`Failed to export span batch` in the demo agent, `refused due to high memory usage` in the collector); a clean run shows 0 for both.

## Pros and Cons of the Options

### Phoenix for agent telemetry + Jaeger for the system view

* Good, because Phoenix types spans (`agent`, `llm`, `tool`), parses prompts into conversations and totals tokens per span and per trace.
* Good, because a failed LLM call is costed correctly: `tokens=0` on the failed span, 689 on the successful one.
* Good, because Phoenix keeps traces (Postgres) and is the only backend that authenticates ingest.
* Good, because Jaeger keeps full detail on HTTP, gRPC and SQL spans.
* Neutral, because the Phoenix ingest key has to be created after Phoenix is up and handed to the collector.
* Bad, because neither Phoenix nor Jaeger marks an incomplete trace — a tree without a root looks complete.

### MLflow as the single backend

* Good, because its trace model covers what agent work needs: `mlflow.spanType` (`AGENT`, `CHAT_MODEL`/`LLM`, `TOOL`), `mlflow.chat.tokenUsage` per span plus a per-trace total, inputs/outputs parsed.
* Good, because it is the only backend that flags an incomplete trace (`IN_PROGRESS`); in the lossy run that was the single visible symptom of dropped data in any UI.
* Good, because it fits work where traces belong to experiments (run comparison, evaluations).
* Bad, because it accepts OTLP/HTTP only and needs a bridge collector for gRPC.
* Bad, because experiments must be created by hand in an order that matches ids hardcoded in the bridge, and they are lost with the PVC on every `make down`; until then every export 404s, visible only in the bridge collector's log.
* Bad, because it needed `--allowed-hosts` for the Service DNS name and probe/worker tuning against crash-loops.
* Bad, because ingest is unauthenticated.

### Jaeger only

* Good, because it works out of the box once re-enabled and has complete data, including every non-LLM span.
* Bad, because it has no GenAI semantics: it cannot say which span was the model call and cannot total tokens — the numbers sit in raw tags.
* Bad, because in this deployment it forgets everything within hours (in-memory; all three traces recorded at the start were evicted). Persistent storage (Badger, Elasticsearch, Cassandra) would fix retention, not semantics.
* Bad, because ingest is unauthenticated.

### All three, fan-out (as run in this lab)

* Good, because it is the only way to compare the backends on identical data.
* Bad, because three ingest paths means three silent failure modes.
* Bad, because the shared collector needed 5× its default memory to stop dropping spans.

## More Information

### Method — identical spans into all three

Upstream disables Jaeger and feeds each backend a different source, so no comparison was possible as shipped. Changes (all local patches over the upstream bundle, nothing published):

* Jaeger re-enabled; a Phoenix exporter added to the demo collector **next to** its Jaeger and MLflow-bridge exporters. All three receive the same spans **after the same processing** (the demo collector's `gen_ai_normalizer` and `transform`).
* kagent tracing switched on (`otel.tracing.*` in the chart → ConfigMap `kagent-controller` → every agent Deployment), pointed at the same collector.
* Two instrumentation stacks traced:
  * **demo agent** — Python, LangGraph, Traceloop/OpenLLMetry, model `gemma-4-31b-it`;
  * **kagent** — Go ADK, model `gemini-3.6-flash` through the OpenAI adapter; one agent, and an orchestrator delegating to it over A2A.

12 requests (8 demo, 4 kagent) were sent; each trace id was resolved immediately and the same id read from all three backends.

**Result of the clean run: for all 12 traces the span count (Jaeger = Phoenix) and the token total (Jaeger = MLflow = Phoenix) match exactly.** The backends received identical data; every difference below is in what they do with it.

### What each backend makes of the same trace

Trace `9a74fcbc…` (demo agent, «What telescopes do you sell?», 22 spans, 2 LLM calls, 1 tool):

| | Jaeger | MLflow | Phoenix |
| --- | --- | --- | --- |
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
| --- | --- | --- | --- |
| **Tool failed** (`c7826d8c…`, pod does not exist) | `error=true` + message on 2 spans | trace `OK` in the list (the agent answered correctly); inside, both spans `STATUS_CODE_ERROR` with the message | `kind=tool`, `status=ERROR` on both |
| **LLM call failed** (`a9e94b31…`, Gemini 3 `thought_signature`) | error spans | trace `ERROR` | failed `llm` span with `tokens=0`, the successful one 689 — cost attributed only where incurred |
| **Incomplete trace** (root span lost, lossy run) | tree without a root, **no indication** | trace stays **`IN_PROGRESS`**, duration of the received part only | tree without a root, **no indication** |

### Agent topology

| | All three |
| --- | --- |
| **A2A delegation** (orchestrator → sub-agent, `65e49c8d…`) | one trace across controller, orchestrator and sub-agent; the hop shows as `execute_tool kagent__NS__lab7_k8s_agent` |
| **MCP tool call** (agent → `kagent-tools`) | the tool server's `mcp.tool.k8s_get_resources` lands in a **separate trace** — trace context does not cross the MCP hop |

Per-agent cost inside a delegated trace is readable in MLflow and Phoenix (tokens on each LLM span under its own `invoke_agent`: orchestrator 686 of 21 626); in Jaeger only as raw tags.

The cost of a failing path is visible in both: «logs of a pod that does not exist» took 6 LLM calls and 25 199 tokens, a plain question 2 calls and 2 012.

### Operating cost — what it took to get data in

| | Jaeger | MLflow | Phoenix |
| --- | --- | --- | --- |
| Worked out of the box | yes (once re-enabled) | no | no |
| What had to be done | — | bridge collector for gRPC→HTTP; experiments created by hand **in an order that matches ids hardcoded in the bridge** (a fresh store has only `Default`; every export 404'd); `--allowed-hosts` for the Service DNS name; probe timeouts and worker count tuned upstream after crash-loops | ingest key created in the UI (shown once) and passed as a Bearer header |
| How a broken ingest looked | — | 404 on every export, visible **only in the bridge collector's log** | `Unauthenticated` on every export, visible **only in the exporting collector's log** |
| Retention | **hours** under demo load — all three traces recorded at the start were evicted (lookup by id → 404) | kept (SQLite) | kept (Postgres) |
| Auth on ingest | none | none | **yes** |

### Noise

kagent's controller emits ~18 single-span traces per request (`POST /api/tasks`, `/api/sessions/…/events`). In MLflow they land in the same experiment as agent traces (20 traces for a handful of requests). Any backend chosen for agents needs that filtered at the collector.

### Observed once, not explained

On the failed-LLM trace `a9e94b31…` MLflow's trace tags carried `service.name=product-catalog` (a span from another service in the same trace) instead of `agent`; on successful traces they carried `agent`. Not reproduced or investigated further.

### What the backend choice does not fix

The largest effects in this lab came from **instrumentation and clients**, not from any backend:

* The demo agent cannot run on **any Gemini 3 model**: `langchain_openai` drops the `thought_signature` Gemini 3 requires on tool-call turns (HTTP 400). Gemini 2.5 is closed to new keys. It runs on Gemma 4 instead. kagent's Go OpenAI adapter on the same model and endpoint has no such problem.
* kagent's **Gemini adapter writes no prompt/response** onto spans (token counts only); the OpenAI adapter on Gemini's OpenAI-compatible endpoint does. Which adapter an agent uses decides whether any backend can show the conversation.
* **MCP breaks trace context**, A2A does not. No backend can join what the instrumentation splits.

### What this does not settle

* **Evaluations and playgrounds** — Phoenix evals and Prompt Playground, MLflow assessments and experiment comparison. These are why those two tools exist; a trace comparison does not touch them. Untested.
* **Sessions / multi-turn** — every request here was single-turn.
* **Cost in money** — token counts only; no pricing was configured for Gemma or Gemini 3.6.
* **Scale** — 12 requests, one run each, one node. No throughput, no retention under load beyond the Jaeger eviction observed.
* **Gateway-level tracing** — `agentgateway-llm` → Phoenix was left out: its tracing config sends no auth header, and the demo agent does not route through it.

Revisit this decision if evaluations become part of the workflow (that is MLflow's and Phoenix's home ground, not compared here) or if abox gets persistent storage for Jaeger.
