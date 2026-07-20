#!/usr/bin/env bash
# Phase A.4: generate GPU_NODES simulated nodes and map them onto the fabric.
#
# Fabric mapping (rail-optimized-ish leaf/spine):
#   - each node attaches to one ToR leaf  -> ai-fabric.io/leaf   (== rack)
#   - leaves are split across spine groups -> ai-fabric.io/spine-group
#   - each node's NICs span GPUS_PER_NODE rails -> ai-fabric.io/rail (primary)
# The Fabric State Service uses these labels to compute network distance/cost.
source "$(dirname "$0")/lib.sh"
require_linux
need kubectl

OUT="$REPO_ROOT/kwok/generated"; mkdir -p "$OUT"
tmpl="$REPO_ROOT/kwok/node-template.yaml"
manifest="$OUT/nodes.yaml"; : > "$manifest"

log "generating ${GPU_NODES} simulated GPU nodes across ${FABRIC_LEAVES} leaves / ${FABRIC_SPINES} spine groups"
for i in $(seq 1 "${GPU_NODES}"); do
  leaf_idx=$(( (i - 1) % FABRIC_LEAVES + 1 ))
  spine_idx=$(( (leaf_idx - 1) % FABRIC_SPINES + 1 ))
  rail_idx=$(( (i - 1) % GPUS_PER_NODE + 1 ))
  name=$(printf "gpu-%04d" "$i")
  sed -e "s/__NAME__/${name}/g" \
      -e "s/__LEAF__/leaf-${leaf_idx}/g" \
      -e "s/__RACK__/rack-${leaf_idx}/g" \
      -e "s/__RAIL__/rail-${rail_idx}/g" \
      -e "s/__SPINE__/spine-${spine_idx}/g" "$tmpl" >> "$manifest"
  echo "---" >> "$manifest"
done

log "applying nodes (server-side apply, may take a moment for large fleets)"
kc apply --server-side -f "$manifest"

log "waiting for fake-gpu-operator to advertise GPUs..."
sleep 10
ready=$(kc get nodes -l run.ai/simulated-gpu-node-pool=default \
  -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
  2>/dev/null | grep -c '^[1-9]' || true)
total=$(kc get nodes -l type=kwok --no-headers 2>/dev/null | wc -l | tr -d ' ')
ok "simulated fleet: ${total} KWOK nodes, ${ready} advertising nvidia.com/gpu"
echo
kc get nodes -l type=kwok -L ai-fabric.io/leaf,ai-fabric.io/spine-group \
  -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu,LEAF:.metadata.labels.ai-fabric\.io/leaf,SPINE:.metadata.labels.ai-fabric\.io/spine-group' \
  2>/dev/null | head -12
[[ "$total" -gt 12 ]] && echo "... (${total} total)"
