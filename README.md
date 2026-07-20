# ai-fabric: GPU Fabric Simulation with k8s, llm-d, and containerlab

A low-resource, **GPU-less** simulation of a GPU network fabric for research into
network-aware scheduling. It combines:

- **kind** — the real Kubernetes control plane + a couple of real worker nodes
- **KWOK** — 100s–1000s of *simulated* GPU nodes (near-zero footprint)
- **fake-gpu-operator** — advertises `nvidia.com/gpu` on the simulated nodes
- **containerlab + SR Linux** — a real leaf/spine network fabric with gNMI telemetry
- **gnmic → Prometheus → Grafana** — fabric telemetry pipeline
- **llm-d** (Gateway API Inference Extension + EPP) — the inference "router"
- **mock-vLLM** — GPU-less serving endpoints whose latency reacts to fabric congestion
- **Fabric State Service** — the custom "networking controller" that turns fabric
  telemetry/topology into scheduling signals
- **fabric EPP scorer** — a custom llm-d Endpoint Picker plugin that routes using fabric state
- **Kueue/Volcano + JobSet** — simulated distributed training placement

> [!IMPORTANT]
> **Everything runs on the `tcow` Ubuntu bare-metal node.** Connect Cursor to `tcow`
> via Remote-SSH, open this folder there, and run the commands below **on `tcow`**.
> containerlab / SR Linux require Linux (amd64) and will not run on macOS.

## Quick start (on tcow)

```bash
# 0. one-time host prep (Docker, Go, kubectl, helm, kind, kwok, containerlab, gnmic)
make host-prep            # may require sudo; log out/in once for the docker group

# A. cluster + simulated GPU fleet
make cluster              # kind cluster + KWOK + fake-gpu-operator
make fleet GPU_NODES=200  # generate labeled KWOK GPU nodes (fabric-located)

# B. network fabric + telemetry
make fabric               # containerlab leaf/spine (SR Linux) + gnmic
make observability        # Prometheus + Grafana

# C. the networking controller
make fabric-state         # build + deploy the Fabric State Service (CRDs + API)

# D. inference layer
make llmd                 # Envoy Gateway + InferencePool + EPP
make mock-vllm            # fabric-aware mock serving endpoints

# E. network-aware routing + measurement
make epp-scorer           # load the custom fabric scorer into EPP
make bench                # A/B latency: baseline vs fabric-aware routing

# F. training placement
make training             # Kueue/Volcano gang jobs across the fleet

# tear everything down
make down
```

Run `make help` to list every target. Tunables live in [`.env`](.env.example)
(copy `.env.example` to `.env`).

## Repository layout

| Path | What it is |
|------|-----------|
| [`scripts/`](scripts) | Idempotent phase scripts (called by the `Makefile`) |
| [`cluster/`](cluster) | kind cluster config |
| [`kwok/`](kwok) | KWOK install + simulated GPU node generator/templates |
| [`fake-gpu/`](fake-gpu) | fake-gpu-operator Helm values |
| [`clab/`](clab) | containerlab topology, SR Linux configs, gnmic config |
| [`observability/`](observability) | Prometheus + Grafana manifests and dashboards |
| [`fabric-state-service/`](fabric-state-service) | Go controller: CRDs, telemetry ingest, cost API |
| [`mock-vllm/`](mock-vllm) | Go OpenAI/vLLM-compatible mock server (fabric-aware latency) |
| [`epp-scorer/`](epp-scorer) | Custom llm-d EPP scorer plugin + EndpointPickerConfig |
| [`llm-d/`](llm-d) | Gateway, InferencePool, EPP deployment manifests |
| [`training/`](training) | Kueue/Volcano + JobSet training-job generator |
| [`bench/`](bench) | Inference load generation + A/B measurement |
| [`docs/`](docs) | Runbook and architecture notes |

## Architecture

See [`docs/runbook.md`](docs/runbook.md) for the phase-by-phase runbook and the
data-flow diagram. The one-paragraph version: the **Fabric State Service** ingests
containerlab gNMI telemetry (via gnmic/Prometheus) plus the static topology,
maps each simulated GPU node to a fabric location (rack/rail/leaf), computes
pairwise network cost/congestion, and exposes it over an HTTP/gRPC API. The
**fabric EPP scorer** and the **training scheduler** both consume that API to make
network-aware placement decisions; the **mock-vLLM** endpoints add latency
proportional to path congestion so improvements are measurable.
