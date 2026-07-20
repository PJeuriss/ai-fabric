#!/usr/bin/env bash
# Phase B.2: install Prometheus + Grafana and wire it to the gnmic collector.
source "$(dirname "$0")/lib.sh"
require_linux
need helm; need kubectl; need docker

log "resolving kind network gateway (so pods can reach host-side gnmic:9273)"
GW="$(docker network inspect kind -f '{{ (index .IPAM.Config 0).Gateway }}' 2>/dev/null || true)"
[[ -z "$GW" ]] && GW="172.18.0.1" && warn "falling back to gateway $GW"
log "gnmic scrape target: ${GW}:9273"

vals="$(mktemp)"
sed "s/__GNMIC_TARGET__/${GW}/g" "$REPO_ROOT/observability/values.yaml" > "$vals"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update prometheus-community >/dev/null

log "installing kube-prometheus-stack into ns/${NS_MONITORING}"
helm --kube-context "$(kctx)" upgrade -i kps \
  prometheus-community/kube-prometheus-stack \
  -n "${NS_MONITORING}" --create-namespace \
  -f "$vals" --wait --timeout 8m || warn "helm returned non-zero; check ns/${NS_MONITORING}"
rm -f "$vals"

log "applying ServiceMonitors for custom components"
kc apply -f "$REPO_ROOT/observability/servicemonitors.yaml"

log "loading Grafana fabric dashboard"
kc -n "${NS_MONITORING}" create configmap fabric-dashboard \
  --from-file=fabric.json="$REPO_ROOT/observability/dashboard-fabric.json" \
  --dry-run=client -o yaml | kc apply -f -
kc -n "${NS_MONITORING}" label configmap fabric-dashboard grafana_dashboard=1 --overwrite

ok "observability up. Grafana: http://<tcow>:30300 (admin/admin). Prometheus via 'kubectl -n ${NS_MONITORING} port-forward svc/kps-kube-prometheus-stack-prometheus 9090'"
