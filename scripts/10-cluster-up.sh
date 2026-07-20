#!/usr/bin/env bash
# Phase A.1: create the kind cluster.
source "$(dirname "$0")/lib.sh"
require_linux
need docker; need kind; need kubectl

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  ok "kind cluster '${CLUSTER_NAME}' already exists"
else
  log "creating kind cluster '${CLUSTER_NAME}' (image kindest/node:${KUBECTL_VERSION})"
  # Render worker count from KIND_WORKERS by appending to the base config.
  cfg="$(mktemp)"; cp "$REPO_ROOT/cluster/kind-config.yaml" "$cfg"
  extra=$(( KIND_WORKERS - 2 ))
  for _ in $(seq 1 "$extra" 2>/dev/null); do
    printf '  - role: worker\n    labels:\n      ai-fabric.io/real: "true"\n' >> "$cfg"
  done
  kind create cluster --name "${CLUSTER_NAME}" \
    --image "kindest/node:${KUBECTL_VERSION}" --config "$cfg" --wait 120s
  rm -f "$cfg"
fi

kc cluster-info
ns_ensure "${NS_SYSTEM}"
ns_ensure "${NS_INFER}"
ns_ensure "${NS_MONITORING}"
ok "cluster ready — context $(kctx)"
