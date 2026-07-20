#!/usr/bin/env bash
# Phase C: build + deploy the Fabric State Service (the networking controller).
source "$(dirname "$0")/lib.sh"
require_linux
need docker; need kind; need kubectl

SRC="$REPO_ROOT/fabric-state-service"

log "resolving Go modules (go mod tidy)"
( cd "$SRC" && command -v go >/dev/null 2>&1 && go mod tidy ) || warn "go not on PATH; relying on in-image 'go mod tidy'"

log "building image ${FSS_IMAGE}"
docker build -t "${FSS_IMAGE}" "$SRC"

log "loading image into kind"
kind load docker-image "${FSS_IMAGE}" --name "${CLUSTER_NAME}"

log "applying CRDs"
kc apply -f "$SRC/config/crd/crds.yaml"

log "deploying controller into ns/${NS_SYSTEM}"
ns_ensure "${NS_SYSTEM}"
kc apply -f "$SRC/deploy/rbac.yaml"
sed "s#ai-fabric/fabric-state-service:dev#${FSS_IMAGE}#g" "$SRC/deploy/deployment.yaml" | kc apply -f -

wait_rollout "${NS_SYSTEM}" deploy/fabric-state-service 180s || warn "not ready; check logs"

ok "fabric-state-service deployed. Try:"
echo "  kubectl -n ${NS_SYSTEM} port-forward svc/fabric-state-service 8080:8080 &"
echo "  curl -s 'localhost:8080/api/v1/cost?from=gpu-0001&to=gpu-0002' | jq"
echo "  kubectl get networkfabric default -o yaml"
