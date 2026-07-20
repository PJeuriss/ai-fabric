#!/usr/bin/env bash
# Shared helpers + config loading for all phase scripts.
# Source this at the top of every script:  source "$(dirname "$0")/lib.sh"
set -Eeuo pipefail

# repo root (scripts/ is one level down)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# ---- load config: .env overrides .env.example defaults ----
set -a
# shellcheck disable=SC1091
[[ -f "$REPO_ROOT/.env.example" ]] && source "$REPO_ROOT/.env.example"
# shellcheck disable=SC1091
[[ -f "$REPO_ROOT/.env" ]] && source "$REPO_ROOT/.env"
set +a

# ---- pretty logging ----
_c() { printf "\033[%sm" "$1"; }
log()  { echo -e "$(_c '1;34')[ai-fabric]$(_c 0) $*"; }
ok()   { echo -e "$(_c '1;32')[  ok   ]$(_c 0) $*"; }
warn() { echo -e "$(_c '1;33')[ warn  ]$(_c 0) $*" >&2; }
die()  { echo -e "$(_c '1;31')[ fail  ]$(_c 0) $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1 (run 'make host-prep')"; }

# Guard: refuse to run the infra phases on macOS (must be tcow / Linux).
require_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    die "This must run on the tcow Ubuntu node (found $(uname -s)). Connect via Remote-SSH first."
  fi
}

# kind cluster kubeconfig context helper
kctx() { echo "kind-${CLUSTER_NAME}"; }
kc()   { kubectl --context "$(kctx)" "$@"; }

# Wait for a rollout with a friendly message.
wait_rollout() { # ns kind/name [timeout]
  local ns="$1" obj="$2" to="${3:-180s}"
  log "waiting for $obj in ns/$ns (timeout $to)..."
  kc -n "$ns" rollout status "$obj" --timeout="$to"
}

ns_ensure() { kc get ns "$1" >/dev/null 2>&1 || kc create ns "$1"; }
