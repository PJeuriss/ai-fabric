#!/usr/bin/env bash
# Phase E.2: A/B latency benchmark — baseline routing vs fabric-aware routing.
# Sends inference requests through the Envoy Gateway (so the EPP actually picks
# endpoints) and reports avg / p50 / p95 request latency for each mode.
source "$(dirname "$0")/lib.sh"
require_linux
need kubectl

REQS="${BENCH_REQS:-200}"
LOCAL_PORT="${BENCH_PORT:-18080}"
PAYLOAD="$REPO_ROOT/bench/payload.json"

resolve_gateway_svc() {
  kc -n envoy-gateway-system get svc \
    -l gateway.envoyproxy.io/owning-gateway-name=llm-d-gw \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

start_pf() {
  local svc; svc="$(resolve_gateway_svc)"
  [[ -z "$svc" ]] && die "could not find Envoy Gateway service (is 'make llmd' done?)"
  log "port-forwarding gateway svc/${svc} -> localhost:${LOCAL_PORT}"
  kc -n envoy-gateway-system port-forward "svc/${svc}" "${LOCAL_PORT}:80" >/dev/null 2>&1 &
  PF_PID=$!
  sleep 3
}
stop_pf() { [[ -n "${PF_PID:-}" ]] && kill "${PF_PID}" 2>/dev/null || true; }
trap stop_pf EXIT

# measure <label> -> prints "label avg p50 p95"
measure() {
  local label="$1" tmp; tmp="$(mktemp)"
  # warmup
  for _ in $(seq 1 10); do
    curl -s -o /dev/null -H 'Content-Type: application/json' \
      --data @"$PAYLOAD" "http://localhost:${LOCAL_PORT}/v1/completions" || true
  done
  for _ in $(seq 1 "$REQS"); do
    curl -s -o /dev/null -w '%{time_total}\n' -H 'Content-Type: application/json' \
      --data @"$PAYLOAD" "http://localhost:${LOCAL_PORT}/v1/completions" >> "$tmp" || true
  done
  sort -n "$tmp" -o "$tmp"
  awk -v L="$label" '
    { a[NR]=$1; sum+=$1 }
    END {
      n=NR; if(n==0){print L, "no-data"; exit}
      p50=a[int(n*0.50)+0]; if(p50=="")p50=a[n];
      p95=a[int(n*0.95)+0]; if(p95=="")p95=a[n];
      printf "%-10s avg=%.3fs  p50=%.3fs  p95=%.3fs  (n=%d)\n", L, sum/n, p50, p95, n
    }' "$tmp"
  rm -f "$tmp"
}

switch_mode() { # baseline | fabric
  local mode="$1"
  if [[ "$mode" == "baseline" ]]; then
    kc apply -f "$REPO_ROOT/llm-d/epp-config-baseline.yaml"
    kc -n "${NS_INFER}" set image deploy/llm-d-epp epp="${EPP_BASE_IMAGE}" 2>/dev/null || true
  else
    kc apply -f "$REPO_ROOT/llm-d/epp-config-fabric.yaml"
    kc -n "${NS_INFER}" set image deploy/llm-d-epp epp="${EPP_IMAGE}" 2>/dev/null || true
  fi
  kc -n "${NS_INFER}" rollout restart deploy/llm-d-epp >/dev/null
  wait_rollout "${NS_INFER}" deploy/llm-d-epp 180s >/dev/null 2>&1 || warn "EPP not ready for $mode"
  sleep 5
}

start_pf
echo "=== A/B inference latency (${REQS} requests each) ==="

log "measuring BASELINE routing"
switch_mode baseline
BASE="$(measure baseline)"

log "measuring FABRIC-AWARE routing"
switch_mode fabric
FAB="$(measure fabric)"

echo
echo "-------------------------------------------------------------"
echo "$BASE"
echo "$FAB"
echo "-------------------------------------------------------------"
ok "done. Expect fabric-aware routing to lower p95 by steering away from congested/distant endpoints."
