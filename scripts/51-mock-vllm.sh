#!/usr/bin/env bash
# Phase D.2: build + deploy fabric-aware mock-vLLM serving endpoints.
# Each endpoint is pinned to a distinct simulated GPU node so routing choices
# have measurable latency consequences.
source "$(dirname "$0")/lib.sh"
require_linux
need docker; need kind; need kubectl

SRC="$REPO_ROOT/mock-vllm"

log "building ${MOCK_VLLM_IMAGE}"
docker build -t "${MOCK_VLLM_IMAGE}" "$SRC"
log "loading image into kind"
kind load docker-image "${MOCK_VLLM_IMAGE}" --name "${CLUSTER_NAME}"

ns_ensure "${NS_INFER}"
kc apply -f "$SRC/deploy/service.yaml"

log "generating ${MOCK_REPLICAS} mock-vLLM endpoints (spanning fabric leaves)"
gen="$(mktemp)"; : > "$gen"
for i in $(seq 1 "${MOCK_REPLICAS}"); do
  fabric_node=$(printf "gpu-%04d" "$i")   # gpu-0001..: leaf assignment matches node gen
  sed -e "s/__IDX__/${i}/g" \
      -e "s/__FABRIC_NODE__/${fabric_node}/g" \
      -e "s#__IMAGE__#${MOCK_VLLM_IMAGE}#g" \
      -e "s/__INGRESS__/${INGRESS_NODE}/g" \
      "$SRC/deploy/deployment-template.yaml" >> "$gen"
  echo "---" >> "$gen"
done
kc apply -f "$gen"; rm -f "$gen"

log "waiting for endpoints to become ready"
kc -n "${NS_INFER}" wait --for=condition=available deploy -l app=mock-vllm --timeout=120s || warn "some endpoints not ready"

ok "mock-vLLM endpoints up (${MOCK_REPLICAS}). Each maps to a fabric node gpu-000N."
kc -n "${NS_INFER}" get pods -l app=mock-vllm -L ai-fabric.io/fabric-node
