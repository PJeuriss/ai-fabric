#!/usr/bin/env bash
# Phase F: install Kueue (gang admission + topology-aware scheduling), launch
# training jobs across the simulated GPU fleet, and start the placement->telemetry
# feedback loop.
source "$(dirname "$0")/lib.sh"
require_linux
need kubectl

ns_ensure "${NS_TRAIN}"

log "installing Kueue ${KUEUE_VERSION}"
kc apply --server-side -f "https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml"
wait_rollout kueue-system deploy/kueue-controller-manager 180s || warn "kueue not ready yet"

log "enabling Topology-Aware Scheduling feature (if gated)"
kc -n kueue-system patch deploy kueue-controller-manager --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--feature-gates=TopologyAwareScheduling=true"}]' \
  2>/dev/null || warn "could not patch feature gate (may already be enabled)"

log "applying Kueue quota + fabric Topology"
kc apply -f "$REPO_ROOT/training/kueue-resources.yaml"

log "deploying Pushgateway + fabric-load-driver (feedback loop)"
kc apply -f "$REPO_ROOT/training/pushgateway.yaml"
kc apply -f "$REPO_ROOT/training/fabric-load-driver.yaml"

log "launching ${TRAIN_JOBS} gang training jobs (${TRAIN_WORKERS} workers each)"
gen="$(mktemp)"; : > "$gen"
for i in $(seq 1 "${TRAIN_JOBS}"); do
  name=$(printf "train-%03d" "$i")
  sed -e "s/__NAME__/${name}/g" -e "s/__WORKERS__/${TRAIN_WORKERS}/g" \
    "$REPO_ROOT/training/training-job-template.yaml" >> "$gen"
  echo "---" >> "$gen"
done
kc apply -f "$gen"; rm -f "$gen"

sleep 8
ok "training launched. Admitted/placed gang pods:"
kc -n "${NS_TRAIN}" get pods -l app=training -o wide 2>/dev/null | head -20
echo
echo "Placement per leaf:"
kc -n "${NS_TRAIN}" get pods -l app=training -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
  | sort | uniq -c | sort -rn | head
echo
echo "The fabric-load-driver CronJob will push per-leaf load each minute; watch it feed back into the EPP scorer via Prometheus."
