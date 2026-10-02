#!/usr/bin/env bash
# lab7 — task 2: a series of agent requests, each traced in all three backends.
#
#   bash lab7/run-series.sh            # → lab7/results/series-<timestamp>.md (+ .tsv)
#
# Trace ids are resolved from Jaeger IMMEDIATELY after each request: Jaeger in
# the demo is in-memory (MEMORY_MAX_TRACES=25000) and evicts within hours.
# MLflow and Phoenix are then queried for the very same ids.
#
# Needs the UI port-forwards (Jaeger :16686, MLflow :5000); opens its own for
# the demo agent and the kagent controller. Phoenix is queried from inside the
# cluster with the key from Secret otel-demo/phoenix-ingest — the key never
# leaves the pod.
set -euo pipefail
cd "$(dirname "$0")/.."
ts=$(date -u +%Y%m%dT%H%M%SZ); out=lab7/results/series-$ts; tsv=$out.tsv
J=http://127.0.0.1:16686/jaeger/ui/api; M=http://127.0.0.1:5000

kubectl -n otel-demo port-forward svc/agent 18010:8010 >/dev/null 2>&1 & PA=$!
kubectl -n kagent port-forward svc/kagent-controller 18083:8083 >/dev/null 2>&1 & PK=$!
trap 'kill $PA $PK 2>/dev/null || true' EXIT
sleep 3

# id|target|prompt — target: demo, or a kagent agent name
cases=$(cat <<'CASES'
d1|demo|What kind of shop is this?
d2|demo|What telescopes do you sell?
d3|demo|Find me a telescope under $500.
d4|demo|What is the cheapest product you have?
d5|demo|Do you sell the Hubble Space Telescope?
d6|demo|Recommend accessories for the Starsense Explorer.
d7|demo|What currencies do you support?
d8|demo|Add one lens cleaning kit to my cart.
k1|lab7-k8s-agent|Which pods run in namespace phoenix, and are they ready?
k2|lab7-k8s-agent|Show recent Warning events in namespace otel-demo.
k3|lab7-k8s-agent|Show the last log lines of pod ghost-pod in namespace default.
k4|lab7-orchestrator|Is the jaeger deployment in namespace otel-demo healthy?
CASES
)

find_trace() {  # find_trace <t0> <service> <operation-substring>
  local t0=$1 svc=$2 op=$3 tid=""
  for _ in $(seq 1 12); do
    tid=$(curl -s "$J/traces?service=$svc&limit=50&lookback=15m" | jq -r --argjson t0 "$t0" --arg op "$op" '
      [.data[] | select(([.spans[].startTime]|min) >= ($t0*1000000))
               | select([.spans[].operationName] | any(contains($op)))]
      | min_by([.spans[].startTime]|min) | .traceID // empty')
    [ -n "$tid" ] && break; sleep 5
  done
  echo "$tid"
}

printf 'case\ttarget\thttp\tseconds\ttrace\tprompt\tanswer\n' > "$tsv"
run_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
while IFS='|' read -r id target prompt; do
  t0=$(date +%s)
  if [ "$target" = demo ]; then
    body=$(jq -nc --arg m "$prompt" '{message:$m}')
    res=$(curl -s -m 180 -o /tmp/lab7-ans.json -w '%{http_code} %{time_total}' -X POST http://127.0.0.1:18010/prompt -H 'Content-Type: application/json' -d "$body" || echo "000 0")
    ans=$(jq -r '.response.messages[-1].content // .detail // empty' /tmp/lab7-ans.json 2>/dev/null | sed 's/<thought>.*<\/thought>//; s/<thought>.*//' | tr '\n\t' '  ' | cut -c1-160)
    sleep 15; tid=$(find_trace "$t0" agent "POST /prompt")
  else
    body=$(jq -nc --arg m "$prompt" --arg id "lab7-$id-$t0" '{jsonrpc:"2.0",id:"1",method:"message/send",params:{message:{role:"user",messageId:$id,parts:[{kind:"text",text:$m}]}}}')
    res=$(curl -s -m 180 -o /tmp/lab7-ans.json -w '%{http_code} %{time_total}' "http://127.0.0.1:18083/api/a2a/kagent/$target/" -H 'Content-Type: application/json' -d "$body" || echo "000 0")
    ans=$(jq -r '.error.message // ([.result.artifacts[]?.parts[]?.text] | join(" ")) // empty' /tmp/lab7-ans.json 2>/dev/null | tr '\n\t' '  ' | cut -c1-160)
    sleep 15; tid=$(find_trace "$t0" "${target//-/_}" "invoke_agent")
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$target" "${res% *}" "${res#* }" "${tid:--}" "$prompt" "$ans" >> "$tsv"
  echo "$id  ${res% *}  ${res#* }s  trace=${tid:--}"
done <<< "$cases"

ids=$(awk -F'\t' 'NR>1 && $5!="-" {print $5}' "$tsv" | tr '\n' ' ')
sleep 20   # let the MLflow bridge and Phoenix finish ingesting

# ── Jaeger ──
jaeger() { curl -s "$J/traces/$1" | jq -r '.data[0] // empty | [
  (.spans|length),
  ([.spans[].tags[] | select(.key=="error" and .value==true)] | length),
  ([.spans[] | select(.operationName | test("ChatLLM.chat|generate_content"))] | length),
  (if [.spans[] | select(.references == [])] | length > 0 then "root" else "NO-ROOT" end),
  ([.spans[].tags[] | select(.key=="gen_ai.usage.input_tokens" or .key=="gen_ai.usage.output_tokens") | .value | tonumber] | add // 0)
] | @tsv'; }
# ── MLflow ──
mlflow() { curl -s "$M/api/3.0/mlflow/traces/tr-$1" | jq -r '.trace.trace_info // empty | [
  .state, (.execution_duration // "-"),
  ((.trace_metadata["mlflow.trace.tokenUsage"] // "{}") | fromjson | .total_tokens // 0),
  (.trace_location.mlflow_experiment.experiment_id // "-")
] | @tsv'; }
# ── Phoenix (in-cluster, key stays in the pod) ──
cat <<POD | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: lab7-series-phoenix, namespace: otel-demo}
spec:
  restartPolicy: Never
  containers:
  - name: c
    image: alpine:3.20
    env:
    - {name: K, valueFrom: {secretKeyRef: {name: phoenix-ingest, key: api-key}}}
    - {name: IDS, value: "$ids"}
    command:
    - sh
    - -c
    - |
      apk add -q curl jq >/dev/null
      for t in \$IDS; do
        q=\$(jq -nc --arg t "\$t" '{query: ("{ node(id: \"UHJvamVjdDox\") { ... on Project { trace(traceId: \"" + \$t + "\") { numSpans spans(first: 200) { edges { node { spanKind statusCode tokenCountTotal attributes } } } } } } }")}')
        curl -s -H "Authorization: Bearer \$K" -H 'Content-Type: application/json' -d "\$q" http://phoenix-svc.phoenix.svc.cluster.local:6006/graphql \
          | jq -r --arg t "\$t" '.data.node.trace // empty | [\$t, .numSpans,
              ([.spans.edges[].node | select(.spanKind=="llm")] | length),
              ([.spans.edges[].node | .tokenCountTotal // 0] | add),
              ([.spans.edges[].node | select(.spanKind=="llm") | .attributes | test("input.value|input_messages|gen_ai.input|llm_request")] | any),
              ([.spans.edges[].node | .spanKind] | unique | join(","))] | @tsv'
      done
POD
kubectl -n otel-demo wait --for=jsonpath='{.status.phase}'=Succeeded pod/lab7-series-phoenix --timeout=300s >/dev/null
kubectl -n otel-demo logs lab7-series-phoenix > /tmp/lab7-phoenix.tsv
kubectl -n otel-demo delete pod lab7-series-phoenix --wait=false >/dev/null

# ── report ──
{
  echo "# lab7 — серія запитів $ts"
  echo
  echo "| case | агент | HTTP | с | trace | Jaeger: спанів / err / LLM / корінь / токени | MLflow: стан / тривалість / токени / exp | Phoenix: спанів / LLM / токени / промпт / типи |"
  echo "|---|---|---|---|---|---|---|---|"
  awk -F'\t' 'NR>1' "$tsv" | while IFS=$'\t' read -r id target http sec tid prompt ans; do
    if [ "$tid" = "-" ]; then j="—"; m="—"; p="—"; else
      j=$(jaeger "$tid" | tr '\t' '/'); m=$(mlflow "$tid" | tr '\t' '/')
      p=$(awk -F'\t' -v t="$tid" '$1==t {print $2"/"$3"/"$4"/"$5"/"$6}' /tmp/lab7-phoenix.tsv)
    fi
    printf '| %s | %s | %s | %.1f | `%s` | %s | %s | %s |\n' "$id" "$target" "$http" "$sec" "${tid:0:8}" "${j:-not found}" "${m:-not found}" "${p:-not found}"
  done
  echo
  echo "## Запити й відповіді"
  echo
  awk -F'\t' 'NR>1 {printf "- **%s** `%s` — %s\n  → %s\n", $1, $5, $6, $7}' "$tsv"
  echo
  echo "## Втрати на шляху до бекендів"
  echo
  lost=$(kubectl -n otel-demo logs deploy/agent --since-time="$run_start" 2>&1 | grep -c 'Failed to export span batch' || true)
  refused=$(for p in $(kubectl -n otel-demo get pods -o name | grep otel-collector-agent); do kubectl -n otel-demo logs "$p" --since-time="$run_start" 2>&1; done | grep -c 'refused due to high memory usage' || true)
  echo "- агент демо, \`Failed to export span batch\` за час серії: **$lost**"
  echo "- collector, \`refused due to high memory usage\` за час серії: **$refused**"
} > "$out.md"
echo; cat "$out.md"
