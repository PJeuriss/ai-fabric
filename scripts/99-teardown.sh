#!/usr/bin/env bash
# Tear down everything created by this project.
source "$(dirname "$0")/lib.sh"
require_linux

log "destroying containerlab fabric"
if [[ -f "$REPO_ROOT/clab/fabric.clab.yaml" ]]; then
  pushd "$REPO_ROOT/clab" >/dev/null
  sudo containerlab destroy -t fabric.clab.yaml --cleanup 2>/dev/null || warn "clab destroy skipped"
  popd >/dev/null
fi

log "stopping host-side gnmic collector"
pkill -f "gnmic.*subscribe" 2>/dev/null || true

log "deleting kind cluster ${CLUSTER_NAME}"
kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || warn "kind cluster not found"

log "cleaning generated artifacts"
rm -rf "$REPO_ROOT/kwok/generated" "$REPO_ROOT/clab/gnmic.log" 2>/dev/null || true

ok "teardown complete"
