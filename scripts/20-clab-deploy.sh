#!/usr/bin/env bash
# Phase B.1: render + deploy the containerlab leaf/spine fabric, then start gnmic.
source "$(dirname "$0")/lib.sh"
require_linux
need containerlab; need gnmic

if [[ "${FABRIC_NOS}" != "srl" ]]; then
  warn "FABRIC_NOS=${FABRIC_NOS}: this script targets SR Linux; FRR path is a TODO stub"
fi

log "generating fabric topology (${FABRIC_SPINES} spines x ${FABRIC_LEAVES} leaves)"
python3 "$REPO_ROOT/clab/gen_fabric.py" \
  --spines "${FABRIC_SPINES}" --leaves "${FABRIC_LEAVES}" --image "${SRL_IMAGE}"

log "deploying containerlab topology (this pulls ${SRL_IMAGE} on first run)"
pushd "$REPO_ROOT/clab" >/dev/null
sudo containerlab deploy -t fabric.clab.yaml --reconfigure
popd >/dev/null

log "waiting for SR Linux gNMI servers to come up"
sleep 20

# Start gnmic as a detached collector exposing Prometheus metrics on :9273.
if pgrep -f "gnmic.*fabric.*subscribe" >/dev/null 2>&1; then
  warn "gnmic collector already running"
else
  log "starting gnmic subscription collector (-> :9273/metrics)"
  nohup gnmic --config "$REPO_ROOT/clab/gnmic.yaml" subscribe \
    > "$REPO_ROOT/clab/gnmic.log" 2>&1 &
  disown || true
  sleep 5
fi

log "fabric nodes:"
sudo containerlab inspect -t "$REPO_ROOT/clab/fabric.clab.yaml" 2>/dev/null || true
ok "fabric up. gNMI telemetry -> http://localhost:9273/metrics (gnmic). Log: clab/gnmic.log"
echo "Verify telemetry:  curl -s localhost:9273/metrics | grep fabric_ | head"
