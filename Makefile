SHELL := /bin/bash
.DEFAULT_GOAL := help

# All real work lives in scripts/. The Makefile is a thin, discoverable front-end.
# Invoke via bash so exec bits aren't required after a fresh git clone.
S := bash ./scripts

.PHONY: help host-prep cluster fleet fabric observability fabric-state llmd \
        mock-vllm epp-scorer bench training hybrid up down status

help: ## Show this help
	@echo "ai-fabric — GPU fabric simulation (run these ON tcow)"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Tunables: copy .env.example to .env and edit."

## ---- Phase 0 ----
host-prep: ## Install Docker, Go, kubectl, helm, kind, kwok, containerlab, gnmic
	$(S)/00-host-prep.sh

## ---- Phase A ----
cluster: ## Create kind cluster + install KWOK + fake-gpu-operator
	$(S)/10-cluster-up.sh
	$(S)/11-kwok-install.sh
	$(S)/12-fake-gpu-install.sh

fleet: ## Generate labeled KWOK GPU nodes (override: make fleet GPU_NODES=500)
	$(S)/13-gen-kwok-nodes.sh

## ---- Phase B ----
fabric: ## Deploy containerlab leaf/spine fabric + gnmic collector
	$(S)/20-clab-deploy.sh

observability: ## Deploy Prometheus + Grafana + dashboards
	$(S)/30-observability.sh

## ---- Phase C ----
fabric-state: ## Build + deploy the Fabric State Service (networking controller)
	$(S)/40-fabric-state-service.sh

## ---- Phase D ----
llmd: ## Install Envoy Gateway + Inference Extension (InferencePool) + EPP
	$(S)/50-llmd-install.sh

mock-vllm: ## Build + deploy fabric-aware mock-vLLM serving endpoints
	$(S)/51-mock-vllm.sh

## ---- Phase E ----
epp-scorer: ## Build EPP image with the fabric scorer + apply EndpointPickerConfig
	$(S)/60-epp-scorer.sh

bench: ## Run A/B latency benchmark (baseline vs fabric-aware routing)
	$(S)/61-bench.sh

## ---- Phase F ----
training: ## Install Kueue/Volcano + launch gang training jobs across the fleet
	$(S)/70-training.sh

## ---- Phase G (optional) ----
hybrid: ## Stitch one real pod-to-pod path through the NOS fabric (clabernetes)
	$(S)/80-hybrid-traffic.sh

## ---- convenience ----
up: cluster fleet fabric observability fabric-state llmd mock-vllm epp-scorer ## Bring up the whole stack
status: ## Show cluster + fabric status
	$(S)/90-status.sh
down: ## Tear everything down
	$(S)/99-teardown.sh
