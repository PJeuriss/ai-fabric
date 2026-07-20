#!/usr/bin/env bash
# Phase G (optional, "later"): stitch ONE real pod-to-pod path through the NOS
# fabric so you can validate the model-based signals against real traffic.
#
# Strategy: use clabernetes to bring a small containerlab topology into the
# cluster, and meshnet/multus to attach two probe pods to a real link that
# traverses SR Linux. Then run iperf3 across it and confirm the gnmic telemetry
# (and thus the Fabric State Service cost) reacts to real congestion.
source "$(dirname "$0")/lib.sh"
require_linux
need helm; need kubectl

log "installing clabernetes (containerlab-in-kubernetes)"
helm --kube-context "$(kctx)" upgrade -i clabernetes \
  oci://ghcr.io/srl-labs/clabernetes/clabernetes \
  -n clabernetes --create-namespace --wait --timeout 5m \
  || warn "clabernetes install returned non-zero; see https://containerlab.dev/manual/clabernetes/"

cat <<'EONOTE'

[next steps — intentionally manual for the validation demo]
  1. Convert a 2-node clab topology with clabverter and apply it:
       clabverter --topology clab/fabric.clab.yaml --naming non-prefixed | kubectl apply -f -
  2. Install multus + meshnet-cni if not present (KNE-style L2 wiring).
  3. Deploy two iperf3 probe pods, each attached (via NetworkAttachmentDefinition)
     to a subinterface on leaf1 / leaf2 so their traffic crosses spine1.
  4. Run: kubectl exec <client> -- iperf3 -c <server-ip> -t 60
  5. Watch fabric_if_counters_out_octets rise on the traversed links and confirm
     the Fabric State Service cost for that path increases:
       curl -s 'localhost:8080/api/v1/cost?from=gpu-0001&to=gpu-0002' | jq

This phase validates that the model-based congestion signal matches real traffic.
EONOTE
ok "clabernetes installed. Follow the manual validation steps above."
