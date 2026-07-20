#!/usr/bin/env bash
# Phase E.1: build the custom EPP (with the fabric scorer), load it, and switch
# the EPP to the fabric-aware EndpointPickerConfig.
source "$(dirname "$0")/lib.sh"
require_linux
need docker; need kind; need kubectl

SRC="$REPO_ROOT/epp-scorer"

log "unit-testing the fabric scorer logic"
( cd "$SRC" && command -v go >/dev/null 2>&1 && go test ./plugins/fabric/... ) \
  || warn "go not on PATH or tests skipped (they run in CI/on tcow)"

log "building custom EPP image ${EPP_IMAGE} (embeds fabric-congestion-scorer)"
docker build -t "${EPP_IMAGE}" "$SRC"
kind load docker-image "${EPP_IMAGE}" --name "${CLUSTER_NAME}"

log "switching EPP to the custom image + fabric-aware config"
kc apply -f "$REPO_ROOT/llm-d/epp-config-fabric.yaml"
kc -n "${NS_INFER}" set image deploy/llm-d-epp epp="${EPP_IMAGE}"
kc -n "${NS_INFER}" rollout restart deploy/llm-d-epp
wait_rollout "${NS_INFER}" deploy/llm-d-epp 180s || warn "EPP rollout not ready"

ok "fabric-aware routing active. Verify scorer metrics:"
echo "  kubectl -n ${NS_INFER} port-forward svc/llm-d-epp 9090:9090 &"
echo "  curl -s localhost:9090/metrics | grep fabric_scorer_"
echo "Then run 'make bench' to A/B baseline vs fabric routing."
