#!/usr/bin/env bash
# lab7 — create the Secrets nothing in git may hold. Run it YOURSELF in an
# interactive Ubuntu terminal: keys are read with `read -s`, never echoed, never
# passed on a command line, and unset on exit.
#
#   bash lab7/secrets.sh gemini     # after `make run`: one Gemini key, three Secrets
#   bash lab7/secrets.sh phoenix    # after Phoenix is up: its ingest key
#
# Re-running is safe: every Secret is applied, not created.
set -euo pipefail

ask() {  # ask <prompt> <var> — hidden input, refuse empty
  local v; read -r -s -p "$1: " v; echo
  [ -n "$v" ] || { echo "empty — aborted (nothing created)"; exit 1; }
  printf -v "$2" '%s' "$v"
  echo "  read ${#v} chars"
}

wait_ns() {  # namespaces are created by Flux, not by us
  for ns in "$@"; do
    until kubectl get ns "$ns" >/dev/null 2>&1; do echo "  waiting for namespace $ns…"; sleep 10; done
  done
}

secret() {  # secret <ns> <name> <key=value>...  (values via stdin-free literals, no shell history)
  local ns=$1 name=$2; shift 2
  local args=(); for kv in "$@"; do args+=(--from-literal="$kv"); done
  kubectl -n "$ns" create secret generic "$name" "${args[@]}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "  ✓ $ns/$name"
}

case "${1:-}" in
gemini)
  ask "Gemini API key (Google AI Studio)" KEY
  trap 'unset KEY' EXIT

  echo "Models this key can call (flash):"
  curl -fsS "https://generativelanguage.googleapis.com/v1beta/models?key=${KEY}&pageSize=200" \
    | jq -r '.models[].name' | sed 's|^models/||' | grep -i flash | sed 's/^/  /' \
    || echo "  ✗ the key was rejected — check it before going on"

  wait_ns agentgateway-system otel-demo kagent
  # agentgateway-llm: without it `releases` never goes Ready, even when the lab
  # does not route through the gateway. TRIAGE_LLM_KEY is the key clients show
  # the gateway, not an external credential — generated, never needed by hand.
  secret agentgateway-system agentgateway-llm-secrets \
    "GEMINI_API_KEY=${KEY}" "TRIAGE_LLM_KEY=$(openssl rand -hex 24)"
  # Astronomy Shop agent (patches/releases.yaml: API_KEY <- gemini-api/GEMINI_API_KEY)
  secret otel-demo gemini-api "GEMINI_API_KEY=${KEY}"
  # kagent ModelConfig gemini-openai-compat (manifests/modelconfig-gemini-openai.yaml)
  secret kagent gemini-api "GEMINI_API_KEY=${KEY}"

  # The agent read an empty optional key at start; it needs a new pod to see it.
  kubectl -n otel-demo rollout restart deploy/agent >/dev/null 2>&1 && echo "  ↻ otel-demo/agent restarted" || true
  ;;
phoenix)
  echo "Phoenix UI → Settings → API Keys → System key. It is shown ONCE."
  ask "Phoenix system API key" KEY
  trap 'unset KEY' EXIT
  wait_ns otel-demo
  secret otel-demo phoenix-ingest "api-key=${KEY}"
  # The collector read an empty optional key at start.
  kubectl -n otel-demo rollout restart daemonset/otel-collector-agent >/dev/null && echo "  ↻ otel-demo/otel-collector-agent restarted"  # DaemonSet name: chart fullnameOverride + "-agent" (mode: daemonset)
  ;;
*)
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
