#!/usr/bin/env bash
# Quick health snapshot of the whole stack.
source "$(dirname "$0")/lib.sh"
require_linux
need kubectl

echo "=== kind cluster ==="
kind get clusters 2>/dev/null | sed 's/^/  /' || true

echo "=== nodes (real + simulated) ==="
kc get nodes -L type,ai-fabric.io/leaf,ai-fabric.io/spine-group --no-headers 2>/dev/null | \
  awk '{t[$0 ~ /kwok/ ? "kwok" : "real"]++} END{print "  real:", t["real"]+0, " kwok:", t["kwok"]+0}'
echo "  GPUs advertised:"
kc get nodes -l type=kwok -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
  | awk '{s+=$1} END{print "    total nvidia.com/gpu =", s+0}'

echo "=== containerlab fabric ==="
sudo containerlab inspect -t "$REPO_ROOT/clab/fabric.clab.yaml" 2>/dev/null | sed 's/^/  /' || echo "  (not deployed)"

echo "=== key deployments ==="
for nsobj in "${NS_SYSTEM}:fabric-state-service" "${NS_INFER}:llm-d-epp" "${NS_MONITORING}:kps-grafana"; do
  ns="${nsobj%%:*}"; d="${nsobj##*:}"
  st=$(kc -n "$ns" get deploy "$d" -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo "n/a")
  printf "  %-40s %s\n" "$ns/$d" "$st"
done

echo "=== inference endpoints ==="
kc -n "${NS_INFER}" get pods -l app=mock-vllm --no-headers 2>/dev/null | wc -l | awk '{print "  mock-vllm pods:", $1}'

echo "=== networkfabric CR ==="
kc get networkfabric default -o jsonpath='  nodes={.status.nodes} leaves={.status.leaves} maxLinkUtil={.status.maxLinkUtil}{"\n"}' 2>/dev/null || echo "  (no NetworkFabric yet)"
