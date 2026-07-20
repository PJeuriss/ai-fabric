#!/usr/bin/env bash
# Phase D.1: install the llm-d inference control plane.
#   Gateway API CRDs + Inference Extension CRDs + Envoy Gateway + EPP + Pool.
# NOTE: CRD/image versions are pinned in .env; bump them to match the llm-d /
# gateway-api-inference-extension release you target.
source "$(dirname "$0")/lib.sh"
require_linux
need kubectl; need helm

log "installing Gateway API CRDs (${GATEWAY_API_VERSION})"
kc apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

log "installing Gateway API Inference Extension CRDs (${GIE_VERSION})"
kc apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GIE_VERSION}/manifests.yaml" \
  || warn "GIE manifests URL may differ for ${GIE_VERSION}; check the release assets"

log "installing Envoy Gateway (${ENVOY_GATEWAY_VERSION})"
helm --kube-context "$(kctx)" upgrade -i envoy-gateway \
  oci://docker.io/envoyproxy/gateway-helm --version "${ENVOY_GATEWAY_VERSION}" \
  -n envoy-gateway-system --create-namespace --wait --timeout 5m \
  || warn "envoy-gateway helm install returned non-zero"

ns_ensure "${NS_INFER}"

log "applying baseline EPP config, EPP, InferencePool, Gateway"
kc apply -f "$REPO_ROOT/llm-d/epp-config-baseline.yaml"
sed "s#registry.k8s.io/gateway-api-inference-extension/epp:v0.3.0#${EPP_BASE_IMAGE}#g" \
  "$REPO_ROOT/llm-d/epp.yaml" | kc apply -f -
kc apply -f "$REPO_ROOT/llm-d/inferencepool.yaml"
kc apply -f "$REPO_ROOT/llm-d/gateway.yaml"

wait_rollout "${NS_INFER}" deploy/llm-d-epp 180s || warn "EPP not ready; check logs / image version"

ok "llm-d installed. Gateway address:"
kc -n "${NS_INFER}" get gateway llm-d-gw -o wide 2>/dev/null || true
echo "Baseline routing active (stock scorers). Run 'make mock-vllm' if you haven't, then 'make epp-scorer' for fabric-aware routing."
