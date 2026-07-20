#!/usr/bin/env bash
# Phase A.2: install the in-cluster KWOK controller + fast lifecycle stages.
# KWOK simulates node/pod lifecycle without a kubelet, so the fleet costs almost
# no memory. Pods land as "Running" but no container actually executes.
source "$(dirname "$0")/lib.sh"
require_linux
need kubectl

REPO="kubernetes-sigs/kwok"
base="https://github.com/${REPO}/releases/download/${KWOK_VERSION}"

log "installing KWOK ${KWOK_VERSION} controller"
kc apply -f "${base}/kwok.yaml"

log "installing KWOK lifecycle stages (fast pod/node transitions)"
kc apply -f "${base}/stage-fast.yaml"
# resource-usage stages let KWOK report fake CPU/mem so schedulers see capacity
kc apply -f "${base}/metrics-usage.yaml" 2>/dev/null || warn "metrics-usage stage not applied (optional)"

wait_rollout kube-system deploy/kwok-controller 180s || warn "kwok-controller not ready yet"
ok "KWOK installed"
