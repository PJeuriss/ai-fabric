#!/usr/bin/env bash
# Phase A.3: install run.ai fake-gpu-operator so simulated nodes advertise GPUs.
source "$(dirname "$0")/lib.sh"
require_linux
need helm; need kubectl

log "adding fake-gpu-operator helm repo"
helm repo add fake-gpu-operator \
  https://runai.jfrog.io/artifactory/api/helm/fake-gpu-operator-charts-prod --force-update
helm repo update fake-gpu-operator >/dev/null

log "installing fake-gpu-operator into ns/gpu-operator"
KUBECONFIG_CTX="$(kctx)"
helm --kube-context "$KUBECONFIG_CTX" upgrade -i gpu-operator \
  fake-gpu-operator/fake-gpu-operator \
  -n gpu-operator --create-namespace \
  -f "$REPO_ROOT/fake-gpu/values.yaml" \
  --set "topology.nodePools.default.gpuCount=${GPUS_PER_NODE}" \
  --set "topology.nodePools.default.gpuProduct=${GPU_PRODUCT}" \
  --wait --timeout 5m || warn "helm install returned non-zero; check pods in ns/gpu-operator"

ok "fake-gpu-operator installed — simulated nodes labeled run.ai/simulated-gpu-node-pool=default will advertise ${GPUS_PER_NODE}x ${GPU_PRODUCT}"
